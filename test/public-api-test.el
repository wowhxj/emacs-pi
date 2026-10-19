;;; public-api-test.el --- Public API checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-pi)

(ert-deftest emacs-pi-api-parser-keeps-image-first-and-message-time ()
  (let ((record (emacs-pi-history--empty-record "/fake")))
    (dolist (line '("{\"type\":\"session\",\"id\":\"a\",\"cwd\":\"/tmp\"}"
                    "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\"}],\"timestamp\":1000}}"
                    "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"later\",\"timestamp\":2000}}"
                    "{\"type\":\"message\",\"message\":{\"role\":\"toolResult\",\"timestamp\":9000}}"
                    "broken"))
      (emacs-pi-history--consume record line))
    (setq record (emacs-pi-history--finish-record record))
    (should (equal (plist-get record :preview) "[Non-text user message]"))
    (should (= (float-time (plist-get record :modified)) 2))
    (should (= (plist-get record :invalid-lines) 1))
    (should-not (plist-get record :empty))))

(defun emacs-pi-api-test--scan (directory)
  "Await one metadata-only scan of DIRECTORY."
  (let (result failure)
    (emacs-pi-list-sessions (lambda (value) (setq result value))
                            :directories (list directory)
                            :on-error (lambda (error) (setq failure error)))
    (let ((deadline (+ (float-time) 5)))
      (while (and (not result) (not failure) (< (float-time) deadline))
        (accept-process-output nil 0.01)))
    (should-not failure) (should result)
    result))

(ert-deftest emacs-pi-api-cache-reuses-records-and-replays-diagnostics ()
  (let* ((directory (make-temp-file "pi-cache-api-" t))
         (path (expand-file-name "session.jsonl" directory))
         (emacs-pi-history--cache (make-hash-table :test #'equal))
         (consume (symbol-function 'emacs-pi-history--consume)) (calls 0))
    (unwind-protect
        (progn
          (with-temp-file path
            (insert "{\"type\":\"session\",\"id\":\"a\",\"cwd\":\"/tmp\"}\n"
                    "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"first\",\"timestamp\":1000}}\n"
                    "broken\n"))
          (cl-letf (((symbol-function 'emacs-pi-history--consume)
                     (lambda (&rest args) (cl-incf calls) (apply consume args))))
            (let ((first (emacs-pi-api-test--scan directory)))
              (should (> calls 0))
              (should (plist-get first :diagnostics))
              (setq calls 0)
              (let ((second (emacs-pi-api-test--scan directory)))
                (should (zerop calls))
                (should (equal (plist-get first :items) (plist-get second :items)))
                (should (equal (plist-get first :diagnostics) (plist-get second :diagnostics)))))
            (write-region "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":\"reply\",\"timestamp\":2000}}\n"
                          nil path t 'silent)
            (setq calls 0)
            (let ((changed (emacs-pi-api-test--scan directory)))
              (should (> calls 0))
              (should (= (float-time (plist-get (car (plist-get changed :items)) :modified)) 2)))))
      (delete-directory directory t))))

(ert-deftest emacs-pi-api-cache-detects-same-size-file-replacement ()
  (let* ((directory (make-temp-file "pi-replace-api-" t))
         (path (expand-file-name "session.jsonl" directory))
         (replacement (expand-file-name "replacement.tmp" directory))
         (emacs-pi-history--cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-temp-file path (insert "{\"type\":\"session\",\"id\":\"a\",\"cwd\":\"/tmp\"}\n"))
          (emacs-pi-api-test--scan directory)
          (let ((mtime (file-attribute-modification-time (file-attributes path))))
            (with-temp-file replacement (insert "{\"type\":\"session\",\"id\":\"b\",\"cwd\":\"/tmp\"}\n"))
            (set-file-times replacement mtime)
            (rename-file replacement path t))
          (should (equal (plist-get (car (plist-get (emacs-pi-api-test--scan directory) :items)) :id) "b")))
      (delete-directory directory t))))

(ert-deftest emacs-pi-api-skips-observation-ledgers-but-reports-broken-sessions ()
  (let* ((directory (make-temp-file "pi-ledger-api-" t))
         (ledger (expand-file-name "sol-pi/example/observation-pack/ledger.jsonl" directory))
         (broken (expand-file-name "broken.jsonl" directory))
         (emacs-pi-history--cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory ledger) t)
          (with-temp-file ledger
            (insert "{\"event\":\"full\",\"id\":\"obs\",\"request\":1,\"tool\":\"read\",\"originalTokens\":10}\n"))
          (with-temp-file broken (insert "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"lost header\",\"timestamp\":1000}}\n"))
          (let* ((result (emacs-pi-api-test--scan directory)) (notes (plist-get result :diagnostics)))
            (should-not (plist-get result :items))
            (should (= (length notes) 1))
            (should (equal (plist-get (car notes) :path) (file-truename broken)))))
      (delete-directory directory t))))

(ert-deftest emacs-pi-api-does-not-ignore-real-session-in-ledger-location ()
  (let* ((directory (make-temp-file "pi-real-ledger-api-" t))
         (path (expand-file-name "observation-pack/ledger.jsonl" directory))
         (emacs-pi-history--cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory path) t)
          (with-temp-file path (insert "{\"type\":\"session\",\"id\":\"real\",\"cwd\":\"/tmp\"}\n"))
          (let ((result (emacs-pi-api-test--scan directory)))
            (should (= (length (plist-get result :items)) 1))
            (should-not (plist-get result :diagnostics))))
      (delete-directory directory t))))

(ert-deftest emacs-pi-api-create-is-fresh-hidden-and-sends-no-prompt ()
  (let* ((directory (make-temp-file "pi-create-api-" t))
         (emacs-pi-executable (executable-find "python3"))
         (emacs-pi-extra-arguments nil)
         (emacs-pi--chats (make-hash-table :test #'equal))
         (original-window (window-buffer)) buffers (ready 0) failure)
    (unwind-protect
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (ert-fail "Unexpected picker")))
                  ((symbol-function 'emacs-pi-rpc-start)
                   (let ((original (symbol-function 'emacs-pi-rpc-start)))
                     (lambda (id generation root args event exit &optional env)
                       (should-not (member "--session" args))
                       (should-not (member "--resume" args))
                       (should (equal (file-truename root) (file-name-as-directory (file-truename directory))))
                       (funcall original id generation root
                                (cons (expand-file-name "test/fake-pi.py" (file-name-directory (locate-library "emacs-pi"))) args)
                                event exit env)))))
          (dotimes (_ 2)
            (push (emacs-pi-create-session directory :display 'none
                                           :on-ready (lambda (_buffer) (cl-incf ready))
                                           :on-error (lambda (error) (setq failure error))) buffers))
          (let ((deadline (+ (float-time) 5)))
            (while (and (< ready 2) (not failure) (< (float-time) deadline))
              (accept-process-output nil 0.01)))
          (should-not failure) (should (= ready 2))
          (should-not (eq (car buffers) (cadr buffers)))
          (should (eq original-window (window-buffer)))
          (dolist (buffer buffers)
            (with-current-buffer buffer
              (should (zerop (length (emacs-pi-session-messages emacs-pi--session)))))))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (emacs-pi-session-shutdown emacs-pi--session))
          (kill-buffer buffer)))
      (delete-directory directory t))))

(ert-deftest emacs-pi-api-create-rejects-missing-or-remote-project ()
  (cl-letf (((symbol-function 'emacs-pi--open) (lambda (&rest _) (ert-fail "Started invalid project"))))
    (should-error (emacs-pi-create-session "/ssh:invalid:/project") :type 'user-error)
    (should-error (emacs-pi-create-session (make-temp-name "/tmp/missing-pi-project-")) :type 'user-error)))

(ert-deftest emacs-pi-api-display-none-keeps-window ()
  (let ((original (window-buffer)) (buffer (generate-new-buffer " *pi-api-test*")))
    (unwind-protect
        (progn (emacs-pi--show-chat buffer 'none)
               (should (eq original (window-buffer))))
      (kill-buffer buffer))))

(ert-deftest emacs-pi-api-scan-partial-errors-and-cancel ()
  (let* ((dir (make-temp-file "pi-api-" t))
         (path (expand-file-name "sample.jsonl" dir))
         result failure)
    (unwind-protect
        (progn
          (with-temp-file path
            (insert "{\"type\":\"session\",\"id\":\"a\",\"cwd\":\"/tmp\"}\n")
            (insert "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"你好\",\"timestamp\":1000}}\n")
            (insert "broken\n"))
          (cl-letf (((symbol-function 'emacs-pi-rpc-start)
                     (lambda (&rest _) (ert-fail "Scanner started Pi"))))
            (emacs-pi-list-sessions
             (lambda (value) (setq result value))
             :directories (list dir) :on-error (lambda (err) (setq failure err)))
            (let ((deadline (+ (float-time) 3)))
              (while (and (not result) (not failure) (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should-not failure)
            (should (= (length (plist-get result :items)) 1))
            (should (equal (plist-get (car (plist-get result :items)) :preview) "你好"))
            (should (plist-get result :diagnostics))
            (setq result nil)
            (funcall (emacs-pi-list-sessions (lambda (v) (setq result v)) :directories (list dir)))
            (accept-process-output nil 0.02)
            (should-not result)))
      (delete-file path)
      (delete-directory dir))))

(ert-deftest emacs-pi-api-open-exact-session-with-fake-peer ()
  (let* ((dir (make-temp-file "pi-open-api-" t))
         (path (expand-file-name "session.jsonl" dir))
         (emacs-pi-executable (executable-find "python3"))
         (emacs-pi-extra-arguments nil)
         (emacs-pi--chats (make-hash-table :test #'equal))
         buffer ready failure)
    (unwind-protect
        (progn
          (with-temp-file path
            (insert (format "{\"type\":\"session\",\"id\":\"api-test\",\"cwd\":%s}\n"
                            (json-serialize dir))))
          (cl-letf (((symbol-function 'emacs-pi-rpc-start)
                     (let ((original (symbol-function 'emacs-pi-rpc-start)))
                       (lambda (id generation root args event exit &optional env)
                         (funcall original id generation root
                                  (append (list (executable-find "python3")
                                                (expand-file-name "test/fake-pi.py"
                                                                  (file-name-directory
                                                                   (locate-library "emacs-pi"))))
                                          (cdr args)) event exit env)))))
            (setq buffer (emacs-pi-open-session
                          path :directory dir :display 'none
                          :on-ready (lambda (b) (setq ready b))
                          :on-error (lambda (err) (setq failure err))))
            (let ((deadline (+ (float-time) 3)))
              (while (and (not ready) (not failure) (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should-not failure)
            (should (eq ready buffer))
            (setq ready nil)
            (should (eq buffer (emacs-pi-open-session
                                path :directory dir :display 'none
                                :on-ready (lambda (b) (setq ready b))
                                :on-error (lambda (e) (setq failure e)))))
            (let ((deadline (+ (float-time) 3)))
              (while (and (not ready) (not failure) (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should-not failure)
            (with-current-buffer buffer
              (emacs-pi-session-shutdown emacs-pi--session)
              (let ((process (emacs-pi-rpc-process
                              (emacs-pi-session-connection emacs-pi--session))))
                (while (process-live-p process)
                  (accept-process-output process 0.02))))
            (setq ready nil)
            (should (eq buffer (emacs-pi-open-session
                                path :directory dir :display 'none
                                :on-ready (lambda (b) (setq ready b))
                                :on-error (lambda (e) (setq failure e)))))
            (let ((deadline (+ (float-time) 3)))
              (while (and (not ready) (not failure) (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should-not failure)
            (should (eq ready buffer))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (emacs-pi-session-shutdown emacs-pi--session))
        (kill-buffer buffer))
      (delete-file path)
      (delete-directory dir))))

(provide 'public-api-test)
;;; public-api-test.el ends here
