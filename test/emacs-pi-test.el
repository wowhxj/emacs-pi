;;; emacs-pi-test.el --- Integration checks for emacs-pi -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-pi)

(defun emacs-pi-test--wait (predicate)
  "Wait up to five seconds for PREDICATE to become non-nil."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall predicate)))

(ert-deftest emacs-pi-json-distinguishes-false-and-null ()
  (let ((object (emacs-pi--jparse "{\"yes\":true,\"no\":false,\"empty\":null,\"items\":[]}")))
    (should (eq (emacs-pi--jget object "yes") t))
    (should (eq (emacs-pi--jget object "no") :false))
    (should (eq (emacs-pi--jget object "empty") :null))
    (should (equal (emacs-pi--jget object "items") []))
    (should (string-match-p "\"no\":false" (emacs-pi--jencode object)))))

(ert-deftest emacs-pi-malformed-rpc-record-closes-safely ()
  (let* ((receive (generate-new-buffer " *emacs-pi-test-receive*"))
         (connection (make-emacs-pi-rpc
                      :receive-buffer receive
                      :pending (make-hash-table :test #'equal)
                      :status 'ready)))
    (unwind-protect
        (progn
          (emacs-pi-rpc--filter connection "{bad json}\n")
          (should (eq (emacs-pi-rpc-status connection) 'dead)))
      (when (buffer-live-p receive) (kill-buffer receive)))))

(ert-deftest emacs-pi-active-branch-skips-abandoned-entries ()
  (let ((entries (vconcat
                  (mapcar (lambda (spec)
                            (emacs-pi--jobject "id" (nth 0 spec)
                                               "parentId" (or (nth 1 spec) :null)))
                          '(("a" nil) ("b" "a") ("c" "b")
                            ("d" "c") ("e" "b") ("f" "e"))))))
    (should (equal (mapcar (lambda (item) (emacs-pi--jget item "id"))
                           (plist-get (emacs-pi-history-active-branch entries "f")
                                      :entries))
                   '("a" "b" "e" "f")))))

(ert-deftest emacs-pi-two-chats-and-streaming-draft ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (emacs-pi-executable (expand-file-name "test/fake-pi.py"
                                               (file-name-directory
                                                (locate-library "emacs-pi"))))
         (first nil) (second nil))
    (unwind-protect
        (progn
          (setq first (emacs-pi--open root)
                second (emacs-pi--open root))
          (let ((one (with-current-buffer first emacs-pi--session))
                (two (with-current-buffer second emacs-pi--session)))
            (should-not (equal (emacs-pi-session-client-id one)
                               (emacs-pi-session-client-id two)))
            (should (emacs-pi-test--wait
                     (lambda () (and (eq (emacs-pi-session-phase one) 'ready)
                                     (eq (emacs-pi-session-phase two) 'ready)))))
            (with-current-buffer first
              (emacs-pi-input-set "hello")
              (emacs-pi-send)
              (emacs-pi-input-set "next draft"))
            (should (emacs-pi-test--wait
                     (lambda () (and (= (length (emacs-pi-session-messages one)) 2)
                                     (not (emacs-pi-session-running one))))))
            (with-current-buffer first
              (emacs-pi-ui-render one)
              (should (equal (emacs-pi-input-text) "next draft"))
              (should (save-excursion
                        (goto-char (point-min))
                        (search-forward "收到：hello" nil t))))
            (should-not (emacs-pi-session-messages two))))
      (when (buffer-live-p first) (kill-buffer first))
      (when (buffer-live-p second) (kill-buffer second))
      (delete-directory root t))))

(ert-deftest emacs-pi-slash-commands-and-completion ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (emacs-pi-executable (expand-file-name "test/fake-pi.py"
                                               (file-name-directory
                                                (locate-library "emacs-pi"))))
         (chat nil))
    (unwind-protect
        (progn
          (setq chat (emacs-pi--open root))
          (let ((session (with-current-buffer chat emacs-pi--session)))
            (should (emacs-pi-test--wait
                     (lambda () (and (eq (emacs-pi-session-phase session) 'ready)
                                     (emacs-pi-session-commands session)))))
            (with-current-buffer chat
              (emacs-pi-input-set "/de")
              (let ((capf (emacs-pi-input-completion-at-point)))
                (should capf)
                (should (member "/demo" (nth 2 capf))))
              (emacs-pi-input-set "/unknown")
              (should-error (emacs-pi-send) :type 'user-error)
              (should (equal (emacs-pi-input-text) "/unknown"))
              (emacs-pi-input-set "/demo")
              (emacs-pi-send))
            (should (emacs-pi-test--wait
                     (lambda () (= (length (emacs-pi-session-messages session)) 2))))
            (with-current-buffer chat
              (should (string-empty-p (emacs-pi-input-text))))))
      (when (buffer-live-p chat) (kill-buffer chat))
      (delete-directory root t))))

(provide 'emacs-pi-test)
;;; emacs-pi-test.el ends here
