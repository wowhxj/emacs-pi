;;; native-process-child.el --- Isolated real-process smoke driver -*- lexical-binding: t; -*-

(require 'emacs-pi)

(defun emacs-pi-smoke--wait (predicate)
  "Await PREDICATE in this disposable Emacs, never touch a user server."
  (let ((deadline (+ (float-time) 15)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (unless (funcall predicate) (error "Persistent smoke deadline exceeded"))))

(let* ((root (getenv "EMACS_PI_SMOKE_ROOT"))
       (mode (getenv "EMACS_PI_SMOKE_MODE"))
       (emacs-pi-persistent t)
       (emacs-pi-runtime-directory (expand-file-name "run" root))
       (emacs-pi-executable (or (getenv "PI_EXECUTABLE") "pi"))
       (emacs-pi-extra-arguments '("--offline" "--no-extensions" "--no-mcp"
                                   "--no-skills" "--no-prompt-templates" "--no-tools"))
       ready failure)
  (let* ((_pending (emacs-pi-open-session
                  (expand-file-name "history.jsonl" root) :directory root :display 'none
                  :on-ready (lambda (value) (setq ready value))
                  :on-error (lambda (value) (setq failure value))))
         buffer session)
    (emacs-pi-smoke--wait (lambda () (or ready failure)))
    (when failure (error "Real Pi restore failed: %s" failure))
    (setq buffer ready session (buffer-local-value 'emacs-pi--session ready))
    (if (equal mode "resume")
        (let (history)
          (emacs-pi-rpc-request
           (emacs-pi-session-connection session) "get_messages" nil
           (lambda (result) (setq history result)))
          (emacs-pi-smoke--wait (lambda () history))
          (unless (and (plist-get history :ok)
                       (string-match-p "detached-native-done"
                                       (emacs-pi--jencode (plist-get history :data))))
            (error "Completed detached work missing from Pi history"))
          (with-current-buffer buffer (emacs-pi-quit))
          (emacs-pi-smoke--wait (lambda () (not (buffer-live-p buffer))))
          (with-temp-file (expand-file-name "resumed" root) (insert "verified")))
      (emacs-pi-rpc-request
       (emacs-pi-session-connection session) "bash"
       (emacs-pi--jobject
        "command" (format "printf started > %s; sleep 1; printf done > %s; printf detached-native-done"
                          (shell-quote-argument (expand-file-name "started" root))
                          (shell-quote-argument (expand-file-name "done" root))))
       (lambda (_result) nil))
      (emacs-pi-smoke--wait (lambda () (file-exists-p (expand-file-name "started" root))))
      (with-temp-file (expand-file-name "armed" root) (insert "backend accepted work"))
      (if (equal mode "crash")
          (while t (accept-process-output nil 0.1))
        (kill-emacs 0)))))
