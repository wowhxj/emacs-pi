;;; emacs-pi-runtime.el --- Persistent Pi launcher configuration -*- lexical-binding: t; -*-

;;; Commentary:
;; Bundled Node stdlib bridge; no runtime dependency installation or Pi internals.

;;; Code:
(require 'emacs-pi-core)
(require 'seq)

(defcustom emacs-pi-persistent t
  "Whether Pi runs independently of Emacs through the bundled bridge.
Nil selects the legacy directly-owned subprocess, without persistence.
Failure in persistent mode never silently falls back to the legacy mode."
  :type 'boolean :group 'emacs-pi)

(defcustom emacs-pi-node-executable "node"
  "Node executable used to run the bundled persistent bridge."
  :type 'string :group 'emacs-pi)

(defcustom emacs-pi-runtime-directory
  (expand-file-name "~/.cache/emacs-pi/run")
  "Private local runtime directory used to discover persistent Pi instances.
Keep this path short enough for local Unix sockets.  Do not use a shared
or remote directory.  Session transcripts remain in Pi's session storage."
  :type 'directory :group 'emacs-pi)

(defconst emacs-pi-runtime--bridge-file
  (expand-file-name "emacs-pi-bridge.mjs"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Bundled bridge path, resolved relative to the installed Lisp package.")

(defvar emacs-pi-runtime--checked-node nil)

(defun emacs-pi-runtime--node ()
  "Return the configured Node executable after checking availability/version."
  (when (eq system-type 'windows-nt)
    (user-error "Persistent Pi currently requires POSIX local sockets"))
  (unless (and (file-regular-p emacs-pi-runtime--bridge-file)
               (file-readable-p emacs-pi-runtime--bridge-file))
    (user-error "Missing bundled Pi bridge: reinstall all package resources"))
  (when (file-remote-p emacs-pi-runtime-directory)
    (user-error "Pi runtime directory must be local"))
  (let ((node (or (and (file-executable-p emacs-pi-node-executable)
                       (expand-file-name emacs-pi-node-executable))
                  (executable-find emacs-pi-node-executable))))
    (unless node (user-error "Node executable unavailable; set emacs-pi-node-executable"))
    (unless (equal node emacs-pi-runtime--checked-node)
      (with-temp-buffer
        (unless (and (zerop (call-process node nil t nil "--version"))
                     (string-match "v\\([0-9]+\\)\\.\\([0-9]+\\)" (buffer-string))
                     (let ((major (string-to-number (match-string 1 (buffer-string))))
                           (minor (string-to-number (match-string 2 (buffer-string)))))
                       (or (> major 22) (and (= major 22) (>= minor 19)))))
          (user-error "Persistent Pi requires Node >=22.19")))
      (setq emacs-pi-runtime--checked-node node))
    node))

(defvar emacs-pi-runtime-attach-target nil
  "Dynamically bound existing-owner identity; never enables launch fallback.")

(defun emacs-pi-runtime-command (id root argv)
  "Wrap Pi ARGV for persistent instance ID in ROOT.
A --session file, not the project directory, identifies an existing session."
  (if emacs-pi-runtime-attach-target
      (let* ((target emacs-pi-runtime-attach-target)
             (config (emacs-pi--jobject
                      "runtime" (expand-file-name emacs-pi-runtime-directory)
                      "instance" (plist-get target :instance) "generation" (plist-get target :generation)
                      "sessionFile" (plist-get target :sessionFile) "sessionId" (plist-get target :sessionId))))
        (list (emacs-pi-runtime--node) emacs-pi-runtime--bridge-file "attach"
              (base64-encode-string (encode-coding-string (emacs-pi--jencode config) 'utf-8-unix) t)))
    (let* ((node (emacs-pi-runtime--node))
         (program (or (and (file-executable-p (car argv))
                           (expand-file-name (car argv)))
                      (executable-find (car argv))
                      (user-error "Pi executable unavailable: %s" (car argv))))
         (file (cadr (member "--session" argv)))
         (config (emacs-pi--jobject
                  "id" id "cwd" root
                  "runtime" (expand-file-name emacs-pi-runtime-directory)
                  "argv" (vconcat (cons program (cdr argv))))))
    (when file (puthash "sessionFile" (expand-file-name file root) config))
    (list node emacs-pi-runtime--bridge-file "connect"
          (base64-encode-string
           (encode-coding-string (emacs-pi--jencode config) 'utf-8-unix) t)))))

(defun emacs-pi-runtime-live-sessions ()
  "Return session IDs and files of persistent Pi runtimes still running.
Reads the registry's state files directly, without Node or a controller,
so session pickers can mark sessions that keep running in the background."
  ;; ponytail: trusts the recorded Pi pid; a recycled pid would look alive.
  (let (live)
    (dolist (file (file-expand-wildcards
                   (expand-file-name "*/state.json" emacs-pi-runtime-directory)))
      (when-let* ((state (ignore-errors
                           (with-temp-buffer
                             (insert-file-contents file)
                             (json-parse-buffer :object-type 'hash-table
                                                :null-object nil :false-object nil))))
                  (pid (gethash "piPid" state)))
        (when (and (member (gethash "status" state) '("starting" "running" "stopping"))
                   (integerp pid) (eq 0 (ignore-errors (signal-process pid 0))))
          (dolist (key '("sessionId" "sessionFile"))
            (when (stringp (gethash key state)) (push (gethash key state) live))))))
    live))

(defun emacs-pi-runtime-running-mark (record live)
  "Return a running marker when history RECORD is among LIVE sessions."
  (if (or (member (plist-get record :id) live)
          (and (plist-get record :path)
               (member (file-truename (plist-get record :path)) live)))
      (propertize " ● running" 'face 'success)
    ""))

;;;###autoload
(cl-defun emacs-pi-inspect-runtimes (on-success &key on-error)
  "Inspect this registry without starting Pi or acquiring a controller.
ON-SUCCESS receives a list of sanitized runtime plists.  Status is a string:
starting/running/stopping/finished/exited/failed/unknown.  Activity is unknown
for a live backend, NOT a model-idle assertion.  No transcript, argv, tokens
or raw diagnostic strings are returned.  Empty means no managed records in
this registry, not absence of legacy/external Pi processes.  Return silent
cancellation; ON-ERROR receives a generic diagnostic string."
  (let ((output (generate-new-buffer " *pi-runtime-inspect*")) done timer process)
    (cl-labels
        ((finish (value failure)
           (unless done
             (setq done t)
             (when timer (cancel-timer timer))
             (when (process-live-p process) (delete-process process))
             (when (buffer-live-p output) (kill-buffer output))
             (if failure
                 (when on-error (funcall on-error failure))
               (funcall on-success value)))))
      (condition-case nil
          (let* ((node (emacs-pi-runtime--node))
                 (config (emacs-pi--jobject "runtime" (expand-file-name emacs-pi-runtime-directory))))
            (setq process
                  (make-process
                   :name "emacs-pi-runtime-inspect" :buffer nil :connection-type 'pipe
                   :command (list node emacs-pi-runtime--bridge-file "inventory"
                                  (base64-encode-string (encode-coding-string (emacs-pi--jencode config) 'utf-8-unix) t))
                   :coding 'utf-8-unix :noquery t :stderr nil
                   :filter (lambda (_child text)
                             (when (and (not done) (buffer-live-p output))
                               (with-current-buffer output
                                 (goto-char (point-max)) (insert text)
                                 (when (> (buffer-size) (* 1024 1024))
                                   (finish nil "Pi runtime inventory exceeded its output limit")))))
                   :sentinel
                   (lambda (child _event)
                     (when (and (not done) (memq (process-status child) '(exit signal)))
                       (let ((value
                              (condition-case nil
                                  (with-current-buffer output
                                    (goto-char (point-min))
                                    (let ((parsed (json-parse-buffer :object-type 'plist :array-type 'array
                                                                     :null-object nil :false-object nil)))
                                      (unless (and (vectorp parsed)
                                                   (seq-every-p (lambda (row)
                                                                  (and (stringp (plist-get row :instance))
                                                                       (member (plist-get row :status)
                                                                               '("starting" "running" "stopping" "finished" "exited" "failed" "unknown")))) parsed))
                                        (error "Invalid inventory"))
                                      (append parsed nil)))
                                (error :invalid))))
                         (if (and (zerop (process-exit-status child)) (not (eq value :invalid)))
                             (finish value nil)
                           (finish nil "Pi runtime inventory could not be verified; no backend was started")))))))
            (setq timer (run-at-time 6 nil #'finish nil "Pi runtime inventory timed out; backend state is unknown")))
        (error (finish nil "Pi runtime inspection unavailable; no backend was started")))
      (lambda ()
        (unless done
          (setq done t)
          (when timer (cancel-timer timer))
          (when (process-live-p process) (delete-process process))
          (when (buffer-live-p output) (kill-buffer output)))))))

(provide 'emacs-pi-runtime)
;;; emacs-pi-runtime.el ends here
