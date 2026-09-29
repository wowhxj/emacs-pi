;;; smoke-real.el --- Offline handshake against installed Pi -*- lexical-binding: t; -*-

(require 'emacs-pi)

(let* ((agent-dir (make-temp-file "emacs-pi-agent-" t))
       (project-dir (make-temp-file "emacs-pi-project-" t))
       (emacs-pi-executable (or (getenv "EMACS_PI_TEST_EXECUTABLE")
                                (executable-find "pi")))
       (buffer nil))
  (unless emacs-pi-executable (error "Pi executable not found"))
  (unwind-protect
      (progn
        (setenv "PI_CODING_AGENT_DIR" agent-dir)
        (setq buffer (emacs-pi--open project-dir))
        (let* ((session (with-current-buffer buffer emacs-pi--session))
               (deadline (+ (float-time) 10))
               (stats nil))
          (while (and (not (memq (emacs-pi-session-phase session) '(ready dead)))
                      (< (float-time) deadline))
            (accept-process-output nil 0.05))
          (unless (eq (emacs-pi-session-phase session) 'ready)
            (error "Pi handshake failed: %s" (emacs-pi-session-error session)))
          (unless (and (stringp (emacs-pi-session-session-id session))
                       (stringp (emacs-pi-session-session-file session)))
            (error "Pi handshake omitted session identity"))
          (emacs-pi-rpc-request
           (emacs-pi-session-connection session) "get_session_stats" nil
           (lambda (result) (setq stats result)))
          (while (and (null stats) (< (float-time) deadline))
            (accept-process-output nil 0.05))
          (unless (plist-get stats :ok)
            (error "Pi stats request failed: %S" stats))
          (princ (format "READY %s; stats OK\n"
                         (emacs-pi-session-session-id session)))))
    (when (buffer-live-p buffer) (kill-buffer buffer))
    (delete-directory agent-dir t)
    (delete-directory project-dir t)))

;;; smoke-real.el ends here
