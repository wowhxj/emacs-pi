;;; persistent-test.el --- Persistent native client integration -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-pi)

(defun emacs-pi-persistent-test--wait (predicate &optional seconds)
  "Wait SECONDS for PREDICATE while servicing real process filters."
  (let ((deadline (+ (float-time) (or seconds 12))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defun emacs-pi-persistent-test--states (runtime)
  "Return test-owned instance metadata under RUNTIME, omitting credentials."
  (let (states)
    (when (file-directory-p runtime)
      (dolist (dir (directory-files runtime t "\\`[a-f0-9]\\{32\\}\\'"))
        (let ((file (expand-file-name "state.json" dir)))
          (when (file-readable-p file)
            (with-temp-buffer
              (insert-file-contents file)
              (let ((state (emacs-pi--jparse (buffer-string))))
                (remhash "token" state)
                (push state states)))))))
    states))

(defun emacs-pi-persistent-test--open (file root)
  "Open FILE in ROOT through the real public API and await verification."
  (let (ready failure)
    (let ((_pending (emacs-pi-open-session
                   file :directory root :display 'none
                   :on-ready (lambda (value) (setq ready value))
                   :on-error (lambda (value) (setq failure value)))))
      (emacs-pi-persistent-test--wait (lambda () (or ready failure)))
      (should-not failure)
      (should (buffer-live-p ready))
      ready)))

(ert-deftest emacs-pi-runtime-public-inventory-is-readonly-and-cancellable ()
  (skip-unless (executable-find "node"))
  (let* ((root (make-temp-file "/tmp/pi-status-" t))
         (emacs-pi-runtime-directory (expand-file-name "missing" root))
         done failure result)
    (unwind-protect
        (progn
          (emacs-pi-inspect-runtimes (lambda (value) (setq result value done t))
                                     :on-error (lambda (value) (setq failure value done t)))
          (emacs-pi-persistent-test--wait (lambda () done))
          (should-not failure) (should-not result)
          (should-not (file-exists-p emacs-pi-runtime-directory))
          (setq done nil)
          (let ((cancel (emacs-pi-inspect-runtimes (lambda (_) (setq done t))
                                                  :on-error (lambda (_) (setq done t)))))
            (funcall cancel) (accept-process-output nil .1)
            (should-not done))
          (should-not (file-exists-p emacs-pi-runtime-directory)))
      (delete-directory root t))))

(ert-deftest emacs-pi-persistent-native-detach-reconnect-and-explicit-quit ()
  (skip-unless (executable-find "node"))
  (let* ((root (make-temp-file "/tmp/pi-ert-" t))
         (file (expand-file-name "history.jsonl" root))
         (emacs-pi-persistent t)
         (emacs-pi-runtime-directory (expand-file-name "run" root))
         (emacs-pi-executable
          (expand-file-name "test/fake-pi.py"
                            (file-name-directory (locate-library "emacs-pi"))))
         (buffers nil))
    (with-temp-file file
      (insert (emacs-pi--jencode
               (emacs-pi--jobject "type" "session" "id" "persistent-native-test"
                                  "cwd" root)) "\n"))
    (unwind-protect
        (let* ((first (emacs-pi-persistent-test--open file root))
               (session (buffer-local-value 'emacs-pi--session first))
               (connection (emacs-pi-session-connection session))
               (state (car (emacs-pi-persistent-test--states emacs-pi-runtime-directory)))
               (pid (emacs-pi--jget state "piPid"))
               (sent nil))
          (push first buffers)
          (should (emacs-pi-rpc-persistent connection))
          (let (inventory failure done)
            (emacs-pi-inspect-runtimes (lambda (value) (setq inventory value done t))
                                       :on-error (lambda (value) (setq failure value done t)))
            (emacs-pi-persistent-test--wait (lambda () done))
            (should-not failure)
            (should (equal (plist-get (car inventory) :status) "running"))
            (should (equal (plist-get (car inventory) :activity) "unknown"))
            (should (plist-get (car inventory) :hasController))
            (should-not (plist-member (car inventory) :token)))
          (emacs-pi-session-submit session "retained across buffer close" nil nil
                                   (lambda (value) (setq sent value)))
          (emacs-pi-persistent-test--wait
           (lambda () (and sent (not (emacs-pi-session-running session))
                           (= 2 (length (emacs-pi-session-messages session))))))
          (should (plist-get sent :ok))
          (kill-buffer first)
          (emacs-pi-persistent-test--wait
           (lambda () (not (process-live-p (emacs-pi-rpc-process connection)))))
          (should (process-attributes pid))
          (should (equal "running"
                         (emacs-pi--jget
                          (car (emacs-pi-persistent-test--states emacs-pi-runtime-directory))
                          "status")))
          (let* ((second (emacs-pi-persistent-test--open file root))
                 (again (buffer-local-value 'emacs-pi--session second)))
            (push second buffers)
            (should (equal pid (emacs-pi--jget
                               (car (emacs-pi-persistent-test--states
                                     emacs-pi-runtime-directory)) "piPid")))
            (should (= 2 (length (emacs-pi-session-messages again))))
            (with-current-buffer second (emacs-pi-quit))
            (emacs-pi-persistent-test--wait (lambda () (not (buffer-live-p second))))
            (should (file-exists-p file))
            (should (equal "finished"
                           (emacs-pi--jget
                            (car (emacs-pi-persistent-test--states emacs-pi-runtime-directory))
                            "status")))))
      ;; Explicitly terminate only this fixture's backend, even after an assertion failure.
      (dolist (buffer buffers)
        (when (buffer-live-p buffer)
          (let ((session (buffer-local-value 'emacs-pi--session buffer)) (done nil))
            (when (process-live-p (emacs-pi-rpc-process (emacs-pi-session-connection session)))
              (emacs-pi-session-shutdown session (lambda (_result) (setq done t)))
              (emacs-pi-persistent-test--wait (lambda () done))))
          (kill-buffer buffer)))
      (when (seq-some (lambda (state) (equal (emacs-pi--jget state "status") "running"))
                      (emacs-pi-persistent-test--states emacs-pi-runtime-directory))
        (let* ((buffer (emacs-pi-persistent-test--open file root))
               (session (buffer-local-value 'emacs-pi--session buffer)) (done nil))
          (emacs-pi-session-shutdown session (lambda (_result) (setq done t)))
          (emacs-pi-persistent-test--wait (lambda () done))
          (kill-buffer buffer)))
      (delete-directory root t))))

(ert-deftest emacs-pi-persistent-snapshot-restores-text-and-questions-once ()
  (let* ((calls 0)
         (session (make-emacs-pi-session
                   :generation 1 :on-extension (lambda (_session _request) (cl-incf calls))))
         (question (emacs-pi--jobject "type" "extension_ui_request" "id" "pending"
                                      "method" "confirm"))
         (snapshot (emacs-pi--jobject "type" "emacs_pi_bridge_state"
                                      "activeText" "stream while disconnected"
                                      "activeTool" "bash" "questions" (vector question))))
    (emacs-pi-session-handle-event session snapshot)
    (emacs-pi-session-handle-event session snapshot)
    (emacs-pi-session-handle-event session question)
    (should (= calls 1))
    (should (equal (emacs-pi-session-active-message session) "stream while disconnected"))
    (should (equal (emacs-pi-session-active-tool session) "bash"))))

(ert-deftest emacs-pi-persistent-finish-failure-is-not-success ()
  (let* ((connection (make-emacs-pi-rpc :persistent t))
         (session (make-emacs-pi-session :generation 1 :connection connection :running t))
         result)
    (cl-letf (((symbol-function 'emacs-pi-rpc-request)
               (lambda (_conn command _args callback &optional _timeout)
                 (should (equal command "emacs_pi_finish"))
                 (funcall callback '(:ok nil :message "still stopping")))))
      (emacs-pi-session-shutdown session (lambda (value) (setq result value))))
    (should-not (plist-get result :ok))
    (should (eq (emacs-pi-session-phase session) 'unknown))
    (should (emacs-pi-session-running session))))

(ert-deftest emacs-pi-owner-discovery-unknown-and-id-mismatch-never-restore ()
  (let ((emacs-pi-persistent t) failure opened missing)
    (cl-letf (((symbol-function 'emacs-pi--open-session-file) (lambda (&rest _) (setq opened t)))
              ((symbol-function 'emacs-pi-inspect-runtimes)
               (lambda (ok &rest _) (funcall ok '((:status "unknown" :sessionFile nil))))))
      (emacs-pi-open-session "/missing/session.jsonl" :on-error (lambda (_) (setq failure t)) :on-missing (lambda () (setq missing t)))
      (should failure) (should-not opened) (should-not missing))
    (setq failure nil)
    (cl-letf (((symbol-function 'emacs-pi--open-session-file) (lambda (&rest _) (setq opened t)))
              ((symbol-function 'emacs-pi-inspect-runtimes)
               (lambda (ok &rest _) (funcall ok '((:status "running" :sessionFile "/missing/session.jsonl" :sessionId "other" :cwd "/missing"))))))
      (emacs-pi-open-session "/missing/session.jsonl" :expected-id "selected" :on-error (lambda (_) (setq failure t)) :on-missing (lambda () (setq missing t)))
      (should failure) (should-not opened) (should-not missing))))

(ert-deftest emacs-pi-explicit-reload-releases-only-confirmed-attach-generation ()
  (let* ((session (make-emacs-pi-session :phase 'ready :runtime-target '(:generation "old")
                                        :connection (make-emacs-pi-rpc :persistent t))) scheduled)
    (cl-letf (((symbol-function 'emacs-pi--require-session) (lambda () session))
              ((symbol-function 'emacs-pi-session-shutdown) (lambda (_session cb) (funcall cb '(:ok t))))
              ((symbol-function 'run-at-time) (lambda (&rest args) (setq scheduled args))))
      (emacs-pi-reload)
      (should-not (emacs-pi-session-runtime-target session))
      (should (eq (nth 2 scheduled) 'emacs-pi-session-restart)))))

(ert-deftest emacs-pi-recovery-overflow-is-visible-and-never-ready-queue-proof ()
  (let ((session (make-emacs-pi-session :queue-known t)))
    (emacs-pi-session-handle-event session (emacs-pi--jobject "type" "emacs_pi_bridge_recovery_warning"
                                                          "recoveryIncomplete" t "queueIncomplete" t))
    (should-not (emacs-pi-session-queue-known session))
    (should (equal (emacs-pi-session-error session) emacs-pi-session--recovery-warning))
    (emacs-pi-session-handle-event session (emacs-pi--jobject "type" "emacs_pi_bridge_state"))
    (should-not (emacs-pi-session-error session))
    (should-not (emacs-pi-session-queue-known session))))

(ert-deftest emacs-pi-native-history-picker-defers-resource-checks-to-owner-first-api ()
  (let (selected)
    (cl-letf (((symbol-function 'emacs-pi-open-session)
               (lambda (path &rest options) (setq selected (cons path options)))))
      (emacs-pi--resume-record '(:path "/missing/history.jsonl" :cwd "/missing/project" :id "exact"))
      (should (equal (car selected) "/missing/history.jsonl"))
      (should (equal (plist-get (cdr selected) :expected-id) "exact"))
      (should (equal (plist-get (cdr selected) :directory) "/missing/project")))))

(provide 'persistent-test)
;;; persistent-test.el ends here
