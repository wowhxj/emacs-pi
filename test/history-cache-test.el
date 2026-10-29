;;; history-cache-test.el --- Persistent summary index tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-pi-history)

(defmacro emacs-pi-cache-test--with-store (&rest body)
  "Run BODY with isolated session and cache directories."
  (declare (indent 0))
  `(let* ((base (file-truename (make-temp-file "pi-index-test-" t)))
          (root (expand-file-name "sessions" base))
          (emacs-pi-history-cache-directory (expand-file-name "cache" base))
          (emacs-pi-history--cache (make-hash-table :test #'equal))
          (emacs-pi-history--loaded-indexes (make-hash-table :test #'equal)))
     (unwind-protect
         (progn (make-directory root) ,@body)
       (delete-directory base t))))

(defun emacs-pi-cache-test--restart ()
  "Discard process-local state to exercise disk loading."
  (setq emacs-pi-history--cache (make-hash-table :test #'equal)
        emacs-pi-history--loaded-indexes (make-hash-table :test #'equal)))

(defun emacs-pi-cache-test--session (path id &optional stamp)
  "Write a small session to PATH with ID and optional STAMP."
  (with-temp-file path
    (insert (json-encode (list :type "session" :id id :cwd "/tmp")) "\n"
            (json-encode (list :type "message"
                               :message (list :role "user" :content "你好 first"
                                              :timestamp (or stamp 1000)))) "\n")))

(defun emacs-pi-cache-test--scan (root)
  "Wait for a scan of ROOT, releasing its resources on failure."
  (let (result failure cancel)
    (unwind-protect
        (progn
          (setq cancel (emacs-pi-list-sessions
                        (lambda (value) (setq result value)) :directories (list root)
                        :on-error (lambda (err) (setq failure err))))
          (let ((deadline (+ (float-time) 5)))
            (while (and (not result) (not failure) (< (float-time) deadline))
              (sleep-for 0.01)))
          (should-not failure)
          (should result)
          result)
      (when cancel (funcall cancel)))))

(ert-deftest emacs-pi-index-roundtrip-reuses-records-and-diagnostics ()
  (emacs-pi-cache-test--with-store
    (let ((path (expand-file-name "a.jsonl" root)))
      (emacs-pi-cache-test--session path "a")
      (write-region "broken\n" nil path t 'silent)
      (let* ((first (emacs-pi-cache-test--scan root))
             (file (emacs-pi-history--index-file (file-truename root))))
        (should (file-exists-p file))
        (should (= (logand (file-modes file) #o777) #o600))
        (emacs-pi-cache-test--restart)
        (cl-letf (((symbol-function 'emacs-pi-history--consume)
                   (lambda (&rest _) (ert-fail "Unchanged session was reparsed"))))
          (let ((cached (emacs-pi-cached-sessions (list root))))
            (should (plist-get cached :cached))
            (should (equal (plist-get cached :items) (plist-get first :items)))
            (should (equal (plist-get cached :diagnostics) (plist-get first :diagnostics))))
          (let ((second (emacs-pi-cache-test--scan root)))
            (should (equal first second))))))))

(ert-deftest emacs-pi-index-incremental-update-addition-and-deletion ()
  (emacs-pi-cache-test--with-store
    (let ((a (expand-file-name "a.jsonl" root))
          (b (expand-file-name "b.jsonl" root))
          (c (expand-file-name "c.jsonl" root))
          (d (expand-file-name "d.jsonl" root))
          (consume (symbol-function 'emacs-pi-history--consume)) parsed)
      (emacs-pi-cache-test--session a "a")
      (emacs-pi-cache-test--session b "b")
      (emacs-pi-cache-test--session c "c")
      (emacs-pi-cache-test--scan root)
      (emacs-pi-cache-test--restart)
      (delete-file a)
      (write-region "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"timestamp\":2000}}\n"
                    nil b t 'silent)
      (emacs-pi-cache-test--session d "d" 3000)
      ;; Display is deliberately stale until the verifying scan completes.
      (should (= (length (plist-get (emacs-pi-cached-sessions (list root)) :items)) 3))
      (cl-letf (((symbol-function 'emacs-pi-history--consume)
                 (lambda (record line)
                   (cl-pushnew (plist-get record :path) parsed :test #'equal)
                   (funcall consume record line))))
        (let ((items (plist-get (emacs-pi-cache-test--scan root) :items)))
          (should (equal (sort (mapcar (lambda (item) (plist-get item :id)) items) #'string-lessp)
                         '("b" "c" "d")))
          (should (= (float-time (plist-get (seq-find (lambda (item) (equal (plist-get item :id) "b")) items)
                                           :modified)) 2))))
      (should (equal (sort parsed #'string-lessp) (sort (list b d) #'string-lessp)))
      (emacs-pi-cache-test--restart)
      (should-not (seq-find (lambda (item) (equal (plist-get item :id) "a"))
                           (plist-get (emacs-pi-cached-sessions (list root)) :items))))))

(ert-deftest emacs-pi-index-replacement-with-same-size-and-mtime-is-reparsed ()
  (emacs-pi-cache-test--with-store
    (let ((path (expand-file-name "a.jsonl" root))
          (replacement (expand-file-name "replacement" base)))
      (emacs-pi-cache-test--session path "a")
      (emacs-pi-cache-test--scan root)
      (emacs-pi-cache-test--restart)
      (let ((mtime (file-attribute-modification-time (file-attributes path))))
        (emacs-pi-cache-test--session replacement "b")
        (set-file-times replacement mtime)
        (rename-file replacement path t))
      (should (equal (plist-get (car (plist-get (emacs-pi-cache-test--scan root) :items)) :id) "b")))))

(ert-deftest emacs-pi-index-isolates-roots-and-rejects-unusable-data ()
  (emacs-pi-cache-test--with-store
    (let ((path (expand-file-name "a.jsonl" root))
          (other (expand-file-name "other" base)))
      (emacs-pi-cache-test--session path "a")
      (emacs-pi-cache-test--scan root)
      (make-directory other)
      (should-not (plist-get (emacs-pi-cached-sessions (list other)) :items))
      (let ((file (emacs-pi-history--index-file (file-truename root))))
        (dolist (data (list "{broken" "(error \"must not execute\")"
                           (json-encode (list :version 999 :root root))
                           (json-encode (list :version 1 :root other))
                           (json-encode (list :version 1 :root root :entries
                                              (vector (list :path "/outside.jsonl"))))))
          (with-temp-file file (insert data))
          (emacs-pi-cache-test--restart)
          (should-not (plist-get (emacs-pi-cached-sessions (list root)) :items))
          (should (= (length (plist-get (emacs-pi-cache-test--scan root) :items)) 1)))))))

(ert-deftest emacs-pi-index-cancellation-preserves-completed-snapshot ()
  (emacs-pi-cache-test--with-store
    (emacs-pi-cache-test--session (expand-file-name "a.jsonl" root) "a")
    (emacs-pi-cache-test--scan root)
    (let* ((file (emacs-pi-history--index-file (file-truename root)))
           (before (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (emacs-pi-cache-test--session (expand-file-name "b.jsonl" root) "b")
      (funcall (emacs-pi-list-sessions (lambda (_) (ert-fail "Cancelled callback"))
                                      :directories (list root)))
      (sleep-for 0.03)
      (should (equal before (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (emacs-pi-cache-test--restart)
      (should (= (length (plist-get (emacs-pi-cached-sessions (list root)) :items)) 1)))))

(ert-deftest emacs-pi-index-missing-root-preserves-completed-snapshot ()
  (emacs-pi-cache-test--with-store
    (emacs-pi-cache-test--session (expand-file-name "a.jsonl" root) "a")
    (emacs-pi-cache-test--scan root)
    (let* ((file (emacs-pi-history--index-file root))
           (before (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (rename-file root (expand-file-name "temporarily-unavailable" base))
      (should (plist-get (emacs-pi-cache-test--scan root) :diagnostics))
      (should (equal before (with-temp-buffer (insert-file-contents file) (buffer-string)))))))

(ert-deftest emacs-pi-index-rejects-malformed-summary-fields ()
  (emacs-pi-cache-test--with-store
    (let ((path (expand-file-name "a.jsonl" root)))
      (emacs-pi-cache-test--session path "a")
      (emacs-pi-cache-test--scan root)
      (let* ((cached (gethash path emacs-pi-history--cache))
             (record (copy-sequence (cdr cached))))
        (setf (plist-get record :preview) 42)
        (with-temp-file (emacs-pi-history--index-file root)
          (insert (json-encode (list :version 1 :root root :entries
                                    (vector (list :path path :signature (car cached)
                                                  :record record)))))))
      (emacs-pi-cache-test--restart)
      (should-not (plist-get (emacs-pi-cached-sessions (list root)) :items))
      (should (= (length (plist-get (emacs-pi-cache-test--scan root) :items)) 1)))))

(ert-deftest emacs-pi-index-persists-ledger-markers-without-showing-them ()
  (emacs-pi-cache-test--with-store
    (let ((ledger (expand-file-name "observation-pack/ledger.jsonl" root)))
      (make-directory (file-name-directory ledger))
      (with-temp-file ledger
        (insert "{\"event\":\"full\",\"id\":\"obs\",\"request\":1,\"tool\":\"read\"}\n"))
      (should-not (plist-get (emacs-pi-cache-test--scan root) :items))
      (emacs-pi-cache-test--restart)
      (should-not (plist-get (emacs-pi-cached-sessions (list root)) :items))
      (cl-letf (((symbol-function 'emacs-pi-history--auxiliary-ledger-p)
                 (lambda (&rest _) (ert-fail "Unchanged ledger was inspected again"))))
        (should-not (plist-get (emacs-pi-cache-test--scan root) :items))))))

(ert-deftest emacs-pi-index-disabled-or-unwritable-does-not-break-scans ()
  (emacs-pi-cache-test--with-store
    (emacs-pi-cache-test--session (expand-file-name "a.jsonl" root) "a")
    (let ((emacs-pi-history-cache-directory nil))
      (should (= (length (plist-get (emacs-pi-cache-test--scan root) :items)) 1)))
    (should-not (file-exists-p emacs-pi-history-cache-directory))
    (with-temp-file emacs-pi-history-cache-directory (insert "not a directory"))
    (should (= (length (plist-get (emacs-pi-cache-test--scan root) :items)) 1))))

(provide 'history-cache-test)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; history-cache-test.el ends here
