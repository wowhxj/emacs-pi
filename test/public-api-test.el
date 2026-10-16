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
