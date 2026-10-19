;;; emacs-pi.el --- Chat with Pi Coding Agent in Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 emacs-pi contributors
;; Author: emacs-pi contributors
;; Version: 0.3.4
;; Package-Requires: ((emacs "29.1") (markdown-mode "2.3"))
;; Keywords: tools, processes, convenience
;; URL: https://github.com/wowhxj/emacs-pi

;;; Commentary:
;; A native, single-buffer Emacs client for Pi's local JSONL RPC mode.
;; See README.md for setup and the current feature boundaries.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'emacs-pi-core)
(require 'emacs-pi-rpc)
(require 'emacs-pi-history)
(require 'emacs-pi-session)
(require 'emacs-pi-ui)
(require 'emacs-pi-input)
(require 'emacs-pi-queue)

(defgroup emacs-pi nil "Emacs client for Pi Coding Agent." :group 'tools)
(defvar vertico-sort-function)

(defcustom emacs-pi-executable "pi"
  "Pi executable used for each chat process."
  :type 'string :group 'emacs-pi)

(defcustom emacs-pi-extra-arguments nil
  "Additional arguments passed to Pi when starting RPC mode."
  :type '(repeat string) :group 'emacs-pi)

(defcustom emacs-pi-show-thinking t
  "Whether to show available thinking text."
  :type 'boolean :group 'emacs-pi)

(defvar emacs-pi--chats (make-hash-table :test #'equal)
  "Live chat buffers keyed by client identity.")

(defun emacs-pi--session-change (session change)
  "Refresh the chat and its queue view after SESSION CHANGE."
  (emacs-pi-ui-schedule session change)
  (when (eq (plist-get change :kind) 'status)
    (when-let* ((buffer (get-buffer
                         (format "*pi-queue:%s*"
                                 (substring (emacs-pi-session-client-id session)
                                            0 6)))))
      (with-current-buffer buffer
        (when (eq emacs-pi--queue-session session)
          (emacs-pi--queue-render session))))))

(defun emacs-pi--show-chat (buffer &optional display)
  "Show Pi chat BUFFER according to DISPLAY.
Nil preserves the existing sole-window behavior.  `current' keeps the
window layout, `none' does not display BUFFER, and other values are
passed to `display-buffer' as an action."
  (pcase display
    ('none nil)
    ('current (switch-to-buffer buffer))
    ('nil (switch-to-buffer buffer) (delete-other-windows))
    (_ (display-buffer buffer display)))
  buffer)

(defun emacs-pi--check-arguments ()
  "Reject arguments that would change RPC and session lifecycle."
  (dolist (arg emacs-pi-extra-arguments)
    (when (member arg '("--mode" "--print" "-p" "--continue" "-c"
                        "--resume" "-r" "--session" "--session-id"
                        "--fork" "--no-session" "--session-dir"))
      (user-error "emacs-pi manages Pi option %s" arg))))

(defun emacs-pi--require-session ()
  "Return current Pi session or raise a user-facing error."
  (or (and (derived-mode-p 'emacs-pi-chat-mode) emacs-pi--session)
      (user-error "Not in an emacs-pi chat")))

(defun emacs-pi--extension (session request)
  "Handle an extension UI REQUEST for SESSION."
  (let* ((method (emacs-pi--jget request "method"))
         (id (emacs-pi--jget request "id"))
         (generation (emacs-pi-session-generation session))
         (buffer (emacs-pi-session-buffer session)))
    (when (and (buffer-live-p buffer) (stringp id))
      (pcase method
        ((or "select" "confirm" "input" "editor")
         (run-at-time
          0 nil
          (lambda ()
            (when (and (buffer-live-p buffer)
                       (= generation (emacs-pi-session-generation session)))
              (with-current-buffer buffer
                (let ((reply (emacs-pi--jobject "type" "extension_ui_response"
                                               "id" id)))
                  (condition-case nil
                      (pcase method
                        ("select"
                         (puthash "value"
                                  (completing-read
                                   (format "%s: "
                                           (or (emacs-pi--jget request "title") "Pi select"))
                                   (emacs-pi--array-list
                                    (emacs-pi--jget request "options"))
                                   nil t)
                                  reply))
                        ("confirm"
                         (puthash "confirmed"
                                  (if (y-or-n-p
                                       (format "%s %s "
                                               (or (emacs-pi--jget request "title")
                                                   "Pi confirm")
                                               (or (emacs-pi--jget request "message") "")))
                                      t :false)
                                  reply))
                        ((or "input" "editor")
                         (puthash "value"
                                  (read-string
                                   (format "%s: "
                                           (or (emacs-pi--jget request "title")
                                               "Pi input"))
                                   (emacs-pi--jget request "prefill"))
                                  reply)))
                    (quit (puthash "cancelled" t reply)))
                  (when (= generation (emacs-pi-session-generation session))
                    (emacs-pi-rpc-reply (emacs-pi-session-connection session)
                                        reply))))))))
        ("notify" (message "Pi: %s" (emacs-pi--jget request "message")))
        ("set_editor_text"
         (with-current-buffer buffer
           (when (string-empty-p (emacs-pi-input-text))
             (emacs-pi-input-set (or (emacs-pi--jget request "text") "")))))
        (_ nil)))))

(defun emacs-pi--open (root &optional session-file display)
  "Open a new chat at ROOT, optionally restoring SESSION-FILE."
  (emacs-pi--check-arguments)
  (unless (or (file-executable-p emacs-pi-executable)
              (executable-find emacs-pi-executable))
    (user-error "Pi executable not found; set emacs-pi-executable"))
  (let* ((root (emacs-pi--local-root root))
         (args (append (when emacs-pi-session-directory
                         (list "--session-dir"
                               (expand-file-name emacs-pi-session-directory)))
                       emacs-pi-extra-arguments))
         (session
          (emacs-pi-session-create root emacs-pi-executable args
                                   nil session-file
                                   #'emacs-pi--session-change
                                   #'emacs-pi--extension))
         (buffer (emacs-pi-ui-create session)))
    (puthash (emacs-pi-session-client-id session) buffer emacs-pi--chats)
    (emacs-pi--show-chat buffer display)
    (emacs-pi-ui-render session)
    buffer))

;;;###autoload
(cl-defun emacs-pi-open-session
    (session-file &key directory session-directory (display 'current)
                  on-ready on-error)
  "Restore SESSION-FILE without a picker or window deletion.
DIRECTORY overrides the recorded working directory.  SESSION-DIRECTORY
is a per-call storage override.  DISPLAY is `current', `none', or a
`display-buffer' action.  Return the chat buffer immediately; ON-READY
receives it only after RPC verifies the exact file and ID.  ON-ERROR
receives a diagnostic string.  A terminal callback runs at most once."
  (unless (and (stringp session-file) (not (file-remote-p session-file))
               (file-regular-p session-file))
    (user-error "An existing local Pi session file is required"))
  (let* ((path (file-truename session-file))
         (header (with-temp-buffer
                   (insert-file-contents path nil 0 65536)
                   (goto-char (point-min))
                   (emacs-pi--jparse
                    (buffer-substring-no-properties
                     (point-min) (line-end-position)))))
         (id (emacs-pi--jget header "id"))
         (root (or directory (emacs-pi--jget header "cwd")))
         existing)
    (unless (and (equal (emacs-pi--jget header "type") "session")
                 (stringp id) (stringp root) (not (file-remote-p root))
                 (file-directory-p root))
      (user-error "Invalid Pi session header or project directory"))
    (setq root (emacs-pi--local-root root))
    (maphash
     (lambda (_key buffer)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (let ((file (and emacs-pi--session
                            (emacs-pi-session-session-file emacs-pi--session))))
             (when (and (stringp file) (file-exists-p file)
                        (file-equal-p file path))
               (setq existing buffer))))))
     emacs-pi--chats)
    (when existing
      (with-current-buffer existing
        (unless (equal root (emacs-pi-session-root emacs-pi--session))
          (user-error "Pi session is already open in another directory"))))
    (let* ((emacs-pi-session-directory
            (or session-directory emacs-pi-session-directory))
           (buffer (or existing (emacs-pi--open root path 'none)))
           (session (buffer-local-value 'emacs-pi--session buffer))
           (generation nil)
           (deadline (+ (float-time)
                        (max 35 (+ emacs-pi-history-request-timeout 10))))
           (done nil)
           timer)
      (when existing
        (let* ((connection (emacs-pi-session-connection session))
               (process (and connection (emacs-pi-rpc-process connection))))
          (when (and (eq (emacs-pi-session-phase session) 'dead)
                     (not (and process (process-live-p process))))
            (emacs-pi-session-restart session)
            (setf (emacs-pi-session-error session) nil))))
      (setq generation (emacs-pi-session-generation session))
      (emacs-pi--show-chat buffer display)
      (cl-labels
          ((finish (failure)
             (unless done
               (setq done t)
               (when timer (cancel-timer timer))
               (if failure
                   (if on-error (funcall on-error failure)
                     (message "emacs-pi: %s" failure))
                 (when on-ready (funcall on-ready buffer)))))
           (check ()
             (cond
              ((/= generation (emacs-pi-session-generation session))
               (finish "Pi connection changed during restore"))
              ((not (buffer-live-p buffer)) (finish "Pi chat buffer was killed"))
              ((> (float-time) deadline) (finish "Pi session restore timed out"))
              ((eq (emacs-pi-session-phase session) 'dead)
               (finish (or (emacs-pi-session-error session) "Pi process exited")))
              ((eq (emacs-pi-session-phase session) 'ready)
               (let ((connection (emacs-pi-session-connection session)))
                 (if (not (and connection
                               (process-live-p (emacs-pi-rpc-process connection))))
                     (finish "Pi connection is not live")
                   (cancel-timer timer)
                   (setq timer (run-at-time 30 nil #'finish "Pi state check timed out"))
                   (emacs-pi-rpc-request
                    connection "get_state" nil
                    (lambda (result)
                      (let* ((state (plist-get result :data))
                             (file (emacs-pi--jget state "sessionFile")))
                        (finish
                         (unless (and (eq (emacs-pi-session-phase session) 'ready)
                                      (eq (emacs-pi-rpc-status connection) 'ready)
                                      (process-live-p (emacs-pi-rpc-process connection))
                                      (= generation (emacs-pi-session-generation session))
                                      (eq connection (emacs-pi-session-connection session))
                                      (buffer-live-p buffer)
                                      (plist-get result :ok)
                                      (equal id (emacs-pi--jget state "sessionId"))
                                      (stringp file) (file-exists-p file)
                                      (file-equal-p path file))
                           "Pi restored a different or unverifiable session")))))))))))
        (setq timer (run-at-time 0.01 0.05 #'check)))
      buffer)))

;;;###autoload
(cl-defun emacs-pi-create-session
    (directory &key session-directory (display 'current) on-ready on-error)
  "Create a fresh Pi session in existing local DIRECTORY without a picker.
Return its buffer immediately.  ON-READY receives the buffer after the
new RPC connection answers get_state; ON-ERROR receives a diagnostic.
SESSION-DIRECTORY overrides storage for this call.  No prompt is sent."
  (unless (and (stringp directory) (not (file-remote-p directory))
               (file-directory-p directory))
    (user-error "An existing local project directory is required"))
  (let* ((root (emacs-pi--local-root directory))
         (emacs-pi-session-directory (or session-directory emacs-pi-session-directory))
         (buffer (emacs-pi--open root nil 'none))
         (session (buffer-local-value 'emacs-pi--session buffer))
         (generation (emacs-pi-session-generation session))
         (deadline (+ (float-time) 35)) timer done)
    (emacs-pi--show-chat buffer display)
    (cl-labels
        ((finish (failure)
           (unless done
             (setq done t)
             (when timer (cancel-timer timer))
             (if failure
                 (if on-error (funcall on-error failure) (message "emacs-pi: %s" failure))
               (when on-ready (funcall on-ready buffer)))))
         (check ()
           (cond
            ((not (buffer-live-p buffer)) (finish "Pi chat buffer was killed"))
            ((/= generation (emacs-pi-session-generation session)) (finish "Pi connection changed during creation"))
            ((> (float-time) deadline) (finish "Pi session creation timed out; a session may already exist"))
            ((eq (emacs-pi-session-phase session) 'dead)
             (finish (or (emacs-pi-session-error session) "Pi process exited")))
            ((eq (emacs-pi-session-phase session) 'ready)
             (let ((connection (emacs-pi-session-connection session)))
               (if (not (and connection (process-live-p (emacs-pi-rpc-process connection))))
                   (finish "Pi connection is not live")
                 (cancel-timer timer)
                 (setq timer (run-at-time 30 nil #'finish "Pi state check timed out; a session may already exist"))
                 (emacs-pi-rpc-request
                  connection "get_state" nil
                  (lambda (result)
                    (let ((id (emacs-pi--jget (plist-get result :data) "sessionId")))
                      (finish
                       (unless (and (plist-get result :ok) (stringp id) (not (string-empty-p id))
                                    (buffer-live-p buffer) (= generation (emacs-pi-session-generation session))
                                    (eq connection (emacs-pi-session-connection session))
                                    (eq (emacs-pi-session-phase session) 'ready)
                                    (eq (emacs-pi-rpc-status connection) 'ready)
                                    (process-live-p (emacs-pi-rpc-process connection))
                                    (equal root (emacs-pi-session-root session)))
                         "Pi new session could not be verified")))))))))))
      (setq timer (run-at-time 0.01 0.05 #'check)))
    buffer))

;;;###autoload
(defun emacs-pi-chat (&optional root)
  "Choose a saved Pi session in ROOT, or start a new one."
  (interactive)
  (let* ((start (if buffer-file-name
                    (file-name-directory buffer-file-name) default-directory))
         (directory (or root (read-directory-name "Pi project root: " start
                                                   nil nil))))
    (setq directory (emacs-pi--local-root directory))
    (let ((records (emacs-pi-history-list directory)))
      (if records
          (emacs-pi--pick-session records directory)
        (emacs-pi--open directory)))))

;;;###autoload
(defun emacs-pi-new-session ()
  "Start another Pi chat in the current chat's project."
  (interactive)
  (emacs-pi--open (emacs-pi-session-root (emacs-pi--require-session))))

(defun emacs-pi--session-column (value width)
  "Return VALUE fitted and padded to display WIDTH."
  (let* ((clean (replace-regexp-in-string "[[:space:]\n\r]+" " " (or value "")))
         (short (truncate-string-to-width clean width nil nil "…")))
    (concat short (make-string (max 0 (- width (string-width short))) ?\s))))

(defun emacs-pi--middle-truncate (value width)
  "Shorten VALUE to WIDTH while preserving its beginning and end."
  (if (<= (string-width value) width)
      value
    (let* ((usable (1- width))
           (head (/ (+ usable 1) 2))
           (tail (- usable head))
           (total (string-width value)))
      (concat (truncate-string-to-width value head)
              "…"
              (truncate-string-to-width value total (- total tail))))))

(defun emacs-pi--session-label (record)
  "Format RECORD as date, ID, workspace, and prompt preview."
  (let* ((date (format-time-string "%Y-%m-%d %H:%M"
                                   (plist-get record :modified)))
         (id (plist-get record :id))
         (cwd (abbreviate-file-name (plist-get record :cwd)))
         (name (plist-get record :name))
         (prompt (or (plist-get record :last-preview)
                     (plist-get record :preview)))
         (preview (cond ((and (stringp name) (stringp prompt)
                              (not (string-empty-p prompt)))
                         (format "%s · %s" name prompt))
                        (name name)
                        (prompt prompt)
                        (t "(empty session)")))
         (preview-width (max 20 (- (window-body-width) 72))))
    (concat (emacs-pi--session-column date 16) "  "
            (emacs-pi--session-column (substring id 0 (min 12 (length id))) 12)
            "  " (emacs-pi--session-column
                   (emacs-pi--middle-truncate cwd 34) 34) "  "
            (truncate-string-to-width
             (replace-regexp-in-string "[[:space:]\n\r]+" " " preview)
             preview-width nil nil "…"))))

(defun emacs-pi--resume-record (record)
  "Open RECORD, switching to a live chat when already open."
  (let* ((path (file-truename (plist-get record :path)))
         (cwd (plist-get record :cwd))
         (existing nil))
    (unless (file-directory-p cwd)
      (user-error "Pi session project directory no longer exists: %s" cwd))
    (maphash
     (lambda (_id buffer)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when-let* ((session-file
                        (and emacs-pi--session
                             (emacs-pi-session-session-file emacs-pi--session))))
             (when (and (file-exists-p session-file)
                        (file-equal-p session-file path))
               (setq existing buffer))))))
     emacs-pi--chats)
    (if existing (emacs-pi--show-chat existing)
      (emacs-pi--open cwd path))))

(defun emacs-pi--pick-session (records &optional new-root)
  "Choose from RECORDS; offer a new session in NEW-ROOT when supplied."
  (let* ((choices (mapcar (lambda (record)
                            (cons (emacs-pi--session-label record) record))
                          records))
         (choices (if new-root
                      (append choices '(("[New session]" . :new)))
                    choices))
         (selected (let ((vertico-sort-function nil))
                     (completing-read
                      (if new-root
                          "Pi session in this directory (choose or create): "
                        "Resume Pi (date | ID | directory | prompt): ")
                      choices nil t)))
         (record (cdr (assoc selected choices))))
    (cond ((eq record :new) (emacs-pi--open new-root))
          (record (emacs-pi--resume-record record)))))

;;;###autoload
(defun emacs-pi-resume ()
  "Choose a persisted Pi session from a detailed global list."
  (interactive)
  (let ((records (emacs-pi-history-list)))
    (unless records
      (user-error "No Pi sessions found in %s" (emacs-pi-history-directory)))
    (emacs-pi--pick-session records)))

;;;###autoload
(defun emacs-pi-switch-chat ()
  "Switch among active emacs-pi chat buffers."
  (interactive)
  (let (choices)
    (maphash (lambda (_id buffer)
               (when (buffer-live-p buffer)
                 (push (cons (buffer-name buffer) buffer) choices)))
             emacs-pi--chats)
    (unless choices (user-error "No active Pi chats"))
    (emacs-pi--show-chat
     (cdr (assoc (completing-read "Pi chat: " choices nil t)
                 choices)))))

(defun emacs-pi-stop ()
  "Clear queued prompts and stop the current Pi run."
  (interactive)
  (let* ((buffer (current-buffer))
         (session (emacs-pi--require-session))
         (attachments (and (emacs-pi-session-queue-attachments session)
                           (copy-hash-table
                            (emacs-pi-session-queue-attachments session)))))
    (emacs-pi-session-stop
     session t
     (lambda (result)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (let* ((cleared (plist-get result :cleared))
                  (texts (append
                          (emacs-pi--array-list (emacs-pi--jget cleared "steering"))
                          (emacs-pi--array-list (emacs-pi--jget cleared "followUp")))))
             (dolist (text texts)
               (let ((images (and attachments (gethash text attachments))))
                 (push (list :text text
                             :attachments (and (listp images) images)
                             :uncertain nil)
                     emacs-pi--recovery)))))
       (message "Pi stop: %s"
                (if (plist-get result :ok) "done"
                  (or (plist-get result :message) "failed"))))))))

(defun emacs-pi-abort-current ()
  "Stop the current run while retaining queued prompts."
  (interactive)
  (emacs-pi-session-stop
   (emacs-pi--require-session) nil
   (lambda (result)
     (message "Pi abort: %s"
              (if (plist-get result :ok) "done"
                (or (plist-get result :message) "failed"))))))

(defun emacs-pi-restart ()
  "Restart this chat's Pi process and reload its session."
  (interactive)
  (emacs-pi-session-restart (emacs-pi--require-session)))

(defun emacs-pi-reload ()
  "Reload Pi extensions and resources by restarting the idle RPC process."
  (interactive)
  (let ((session (emacs-pi--require-session)))
    (unless (and (eq (emacs-pi-session-phase session) 'ready)
                 (not (emacs-pi-session-running session)))
      (user-error "Wait for Pi to become idle before /reload"))
    (emacs-pi-session-restart session)))

(defun emacs-pi-shutdown ()
  "Shut down the Pi process while leaving the transcript visible."
  (interactive)
  (emacs-pi-session-shutdown (emacs-pi--require-session)))

(defun emacs-pi-quit ()
  "Close this chat, stopping its Pi process and killing its buffer."
  (interactive)
  (when (emacs-pi-session-queue-rewriting
         (emacs-pi--require-session))
    (user-error "Pi queue is being rewritten; wait for it to finish"))
  (kill-buffer (current-buffer)))

(defun emacs-pi-help ()
  "Show commands supported by this client and chat keys."
  (interactive)
  (let ((commands (emacs-pi-input--slash-choices)))
    (with-help-window "*emacs-pi-help*"
      (princ "Slash commands available in emacs-pi (client + current Pi RPC resources):\n")
      (dolist (choice commands)
        (princ (format "  %s\n" (car choice))))
      (princ (format "\nPi CLI commands without a full RPC workflow (not exposed): %s\n"
                     (string-join emacs-pi-input--unsupported-cli-commands ", ")))
      (princ "/reload restarts the RPC process to reload extensions and resources.\n")
      (princ "RET send · S-RET newline · C-c C-s steer · C-c C-k stop\n")
      (princ "C-c C-l queue · C-c C-r resume · C-c C-b switch chats · C-c C-q close\n")
      (princ "Queue: RET edit · M-up/down reorder · s/f lane · d delete · C-c C-c apply\n")
      (princ "i focus input from history · C-a stay after You>\n")
      (princ "RET/TAB on a Process or tool heading toggles its steps\n")
      (princ "M-p/M-n prompt history · TAB/M-TAB minibuffer completion\n")
      (princ "C-c C-o opens the image at point; click × to remove an attachment.\n\n")
      (princ "M-x emacs-pi-attach-image adds a PNG/JPEG to the next prompt.\n")
      (princ "@path is a path hint; @session includes saved dialogue context.\n"))))

(defun emacs-pi-compact (&optional instructions clear-command-draft)
  "Compact the current Pi context using optional INSTRUCTIONS.
CLEAR-COMMAND-DRAFT is non-nil when called from the /compact composer command."
  (interactive
   (list (let ((text (string-trim
                      (read-string "Pi compact instructions (empty for default): "))))
           (unless (string-empty-p text) text)) nil))
  (let* ((session (emacs-pi--require-session))
         (buffer (current-buffer))
         (draft (emacs-pi-input-text))
         (draft-revision emacs-pi--draft-revision))
    (when emacs-pi--attachments
      (user-error "Remove or send attached images before /compact"))
    (emacs-pi-session-compact
     session instructions
     (lambda (result)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (if (plist-get result :ok)
               (message "Pi context compacted")
             (message "Pi compact: %s%s"
                      (plist-get result :message)
                      (if (plist-get result :uncertain-p)
                          " (status unknown; inspect the session before retrying)"
                        "")))))))
    (emacs-pi--clear-command-draft buffer draft draft-revision
                                   clear-command-draft)))

(defun emacs-pi--clear-command-draft (buffer draft revision clear-command-draft)
  "Clear BUFFER's command draft only if it still matches DRAFT and REVISION."
  (when (and clear-command-draft (buffer-live-p buffer))
    (with-current-buffer buffer
      (when (and (= revision emacs-pi--draft-revision)
                 (equal draft (emacs-pi-input-text)))
        (emacs-pi-input-set "")))))

(defun emacs-pi-set-session-name (&optional name clear-command-draft)
  "Show or set the current Pi session NAME."
  (interactive
   (list (let ((text (string-trim
                      (read-string "Pi session name (empty to show): "))))
           (unless (string-empty-p text) text)) nil))
  (let* ((session (emacs-pi--require-session))
         (buffer (current-buffer))
         (draft (emacs-pi-input-text))
         (revision emacs-pi--draft-revision))
    (if (not (and (stringp name) (not (string-empty-p name))))
        (progn
          (emacs-pi--clear-command-draft buffer draft revision clear-command-draft)
          (message "Pi session: %s" (or (emacs-pi-session-name session) "(unnamed)")))
      (emacs-pi-rpc-request
       (emacs-pi-session-connection session) "set_session_name"
       (emacs-pi--jobject "name" name)
       (lambda (result)
         (if (plist-get result :ok)
             (progn
               (setf (emacs-pi-session-name session) name)
               (emacs-pi-ui-schedule session nil)
               (emacs-pi--clear-command-draft buffer draft revision clear-command-draft)
               (message "Pi session renamed: %s" name))
           (message "Pi session name: %s" (plist-get result :message))))
       120))))

(defun emacs-pi-show-session-stats (&optional _ignored clear-command-draft)
  "Show current Pi session statistics."
  (interactive)
  (let* ((session (emacs-pi--require-session))
         (buffer (current-buffer))
         (draft (emacs-pi-input-text))
         (revision emacs-pi--draft-revision))
    (emacs-pi-rpc-request
     (emacs-pi-session-connection session) "get_session_stats" nil
     (lambda (result)
       (if (not (plist-get result :ok))
           (message "Pi session stats: %s" (plist-get result :message))
         (let* ((data (plist-get result :data))
                (usage (emacs-pi--jget data "contextUsage"))
                (tokens (emacs-pi--jget data "tokens")))
           (with-help-window "*emacs-pi-session*"
             (princ (format "Session: %s\\nSession file: %s\\n"
                            (or (emacs-pi-session-name session) "(unnamed)")
                            (or (emacs-pi--jget data "sessionFile")
                                (emacs-pi-session-session-file session)
                                "unknown")))
             (princ (format "Messages: %s user, %s assistant\\nTool calls: %s\\n"
                            (or (emacs-pi--jget data "userMessages") 0)
                            (or (emacs-pi--jget data "assistantMessages") 0)
                            (or (emacs-pi--jget data "toolCalls") 0)))
             (princ (format "Tokens: %s\\nCost: %s\\nContext: %s / %s (%s%%)\\n"
                            (or (emacs-pi--jget tokens "total") "unknown")
                            (or (emacs-pi--jget data "cost") "unknown")
                            (or (emacs-pi--jget usage "tokens") "unknown")
                            (or (emacs-pi--jget usage "contextWindow") "unknown")
                            (or (emacs-pi--jget usage "percent") "unknown"))))
           (emacs-pi--clear-command-draft buffer draft revision clear-command-draft))))
     120)))

(defun emacs-pi-copy-last-response (&optional _ignored clear-command-draft)
  "Copy the last assistant response to the kill ring."
  (interactive)
  (let* ((session (emacs-pi--require-session))
         (buffer (current-buffer))
         (draft (emacs-pi-input-text))
         (revision emacs-pi--draft-revision))
    (emacs-pi-rpc-request
     (emacs-pi-session-connection session) "get_last_assistant_text" nil
     (lambda (result)
       (let ((text (and (plist-get result :ok)
                        (emacs-pi--jget (plist-get result :data) "text"))))
         (if (stringp text)
             (progn
               (kill-new text)
               (emacs-pi--clear-command-draft buffer draft revision clear-command-draft)
               (message "Copied last Pi response"))
           (message "Pi copy: %s" (or (plist-get result :message)
                                      "No assistant text to copy")))))
     120)))

(defun emacs-pi-export-session (&optional output-path clear-command-draft)
  "Export the current Pi session to HTML, optionally at OUTPUT-PATH."
  (interactive
   (list (let ((path (string-trim
                      (read-string "HTML output path (empty for automatic): "))))
           (unless (string-empty-p path) path)) nil))
  (let* ((session (emacs-pi--require-session))
         (buffer (current-buffer))
         (draft (emacs-pi-input-text))
         (revision emacs-pi--draft-revision)
         (path (and output-path
                    (expand-file-name output-path (emacs-pi-session-root session))))
         (args (and path (emacs-pi--jobject "outputPath" path))))
    (emacs-pi-rpc-request
     (emacs-pi-session-connection session) "export_html" args
     (lambda (result)
       (if (plist-get result :ok)
           (let ((exported (emacs-pi--jget (plist-get result :data) "path")))
             (emacs-pi--clear-command-draft buffer draft revision clear-command-draft)
             (message "Pi session exported: %s" exported))
         (message "Pi export: %s" (plist-get result :message))))
     120)))

(defun emacs-pi-clone-session (&optional _ignored clear-command-draft)
  "Clone the current active session branch."
  (interactive)
  (let* ((session (emacs-pi--require-session))
         (buffer (current-buffer))
         (draft (emacs-pi-input-text))
         (revision emacs-pi--draft-revision))
    (emacs-pi-session-clone
     session
     (lambda (result)
       (if (not (plist-get result :ok))
           (message "Pi clone: %s" (plist-get result :message))
         (if (emacs-pi--jtrue-p
              (emacs-pi--jget (plist-get result :data) "cancelled"))
             (message "Pi clone cancelled")
           (emacs-pi--clear-command-draft buffer draft revision clear-command-draft)
           (message "Pi session cloned")))))))

(defun emacs-pi-fork-session (&optional _ignored clear-command-draft)
  "Fork the current session from a selected user message."
  (interactive)
  (let* ((session (emacs-pi--require-session))
         (buffer (current-buffer))
         (draft (emacs-pi-input-text))
         (revision emacs-pi--draft-revision))
    (when (emacs-pi-session-running session)
      (user-error "Stop the current Pi run before forking"))
    (emacs-pi-rpc-request
     (emacs-pi-session-connection session) "get_fork_messages" nil
     (lambda (result)
       (if (not (plist-get result :ok))
           (message "Pi fork: %s" (plist-get result :message))
         (run-at-time
          0 nil
          (lambda ()
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (let* ((messages (emacs-pi--array-list
                                  (emacs-pi--jget (plist-get result :data) "messages")))
                       (choices
                        (cl-loop for item in messages
                                 for index from 1
                                 for id = (emacs-pi--jget item "entryId")
                                 for text = (emacs-pi--jget item "text")
                                 when (and id (stringp text))
                                 collect (cons (format "%d. %s" index
                                                      (truncate-string-to-width
                                                       text 72 nil nil "…"))
                                               id)))
                       (choice (and choices
                                    (assoc (completing-read "Fork from: "
                                                            choices nil t)
                                           choices))))
                  (if (not choice)
                      (message "No user messages available to fork")
                    (emacs-pi-session-fork
                     session (cdr choice)
                     (lambda (fork-result)
                       (if (not (plist-get fork-result :ok))
                           (message "Pi fork: %s"
                                    (plist-get fork-result :message))
                         (if (emacs-pi--jtrue-p
                              (emacs-pi--jget (plist-get fork-result :data)
                                             "cancelled"))
                             (message "Pi fork cancelled")
                           (emacs-pi--clear-command-draft
                            buffer draft revision clear-command-draft)
                           (message "Pi forked from selected message"))))))))))))
     120))))

(defun emacs-pi-select-model ()
  "Select an available provider/model for this Pi chat."
  (interactive)
  (let* ((session (emacs-pi--require-session))
         (buffer (current-buffer)))
    (when (emacs-pi-session-running session)
      (user-error "Stop the current Pi run before changing models"))
    (emacs-pi-rpc-request
     (emacs-pi-session-connection session) "get_available_models" nil
     (lambda (result)
       (if (not (plist-get result :ok))
           (message "Pi models: %s" (plist-get result :message))
         (run-at-time
          0 nil
          (lambda ()
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (let* ((models (emacs-pi--array-list
                                (emacs-pi--jget (plist-get result :data) "models")))
                       (choices (mapcar
                                 (lambda (model)
                                   (cons (format "%s/%s"
                                                 (emacs-pi--jget model "provider")
                                                 (emacs-pi--jget model "id")) model))
                                 models))
                       (chosen (and choices
                                    (cdr (assoc (completing-read "Pi model: "
                                                                 choices nil t)
                                                choices)))))
                  (when chosen
                    (emacs-pi-rpc-request
                     (emacs-pi-session-connection session) "set_model"
                     (emacs-pi--jobject
                      "provider" (emacs-pi--jget chosen "provider")
                      "modelId" (emacs-pi--jget chosen "id"))
                     (lambda (set-result)
                       (if (plist-get set-result :ok)
                           (progn
                             (setf (emacs-pi-session-model session)
                                   (plist-get set-result :data))
                             (emacs-pi-rpc-request
                              (emacs-pi-session-connection session)
                              "get_state" nil
                              (lambda (state-result)
                                (when (plist-get state-result :ok)
                                  (setf (emacs-pi-session-thinking session)
                                        (emacs-pi--jget
                                         (plist-get state-result :data)
                                         "thinkingLevel"))
                                  (emacs-pi-ui-schedule session nil))))
                             (emacs-pi-session-refresh-stats session)
                             (emacs-pi-ui-schedule session nil))
                         (message "Pi model: %s"
                                  (plist-get set-result :message))))))))))))))))

(defun emacs-pi-select-thinking ()
  "Select a thinking level supported by the current Pi model."
  (interactive)
  (let* ((session (emacs-pi--require-session))
         (buffer (current-buffer)))
    (when (emacs-pi-session-running session)
      (user-error "Stop the current Pi run before changing thinking level"))
    (emacs-pi-rpc-request
     (emacs-pi-session-connection session) "get_available_thinking_levels" nil
     (lambda (result)
       (if (not (plist-get result :ok))
           (message "Pi thinking levels: %s" (plist-get result :message))
         (run-at-time
          0 nil
          (lambda ()
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (let* ((levels (emacs-pi--array-list
                                (emacs-pi--jget (plist-get result :data) "levels")))
                       (level (and levels
                                   (completing-read "Pi thinking: " levels nil t))))
                  (when level
                    (emacs-pi-rpc-request
                     (emacs-pi-session-connection session) "set_thinking_level"
                     (emacs-pi--jobject "level" level)
                     (lambda (set-result)
                       (if (plist-get set-result :ok)
                           (progn
                             (setf (emacs-pi-session-thinking session) level)
                             (emacs-pi-ui-schedule session nil))
                         (message "Pi thinking: %s"
                                  (plist-get set-result :message))))))))))))))))

(defun emacs-pi-insert-file (file)
  "Insert a path reference to FILE in the current Pi draft."
  (interactive (list (read-file-name "Reference file: " default-directory
                                     nil t)))
  (emacs-pi--require-session)
  (goto-char (point-max))
  (unless (or (string-empty-p (emacs-pi-input-text))
              (memq (char-before) '(32 9 10)))
    (insert " "))
  (let ((path (if (file-in-directory-p
                   file (emacs-pi-session-root emacs-pi--session))
                  (file-relative-name file
                                      (emacs-pi-session-root emacs-pi--session))
                (expand-file-name file))))
    (insert "@" (if (string-match-p "[[:space:]]" path)
                    (emacs-pi--jencode path) path))))

(defun emacs-pi-doctor ()
  "Display Pi executable and the current chat's connection status."
  (interactive)
  (let ((session (and (derived-mode-p 'emacs-pi-chat-mode)
                      emacs-pi--session)))
    (message "Pi executable: %s; chat: %s; session: %s"
             (or (executable-find emacs-pi-executable) emacs-pi-executable)
             (if session (emacs-pi-session-phase session) "none")
             (if session (or (emacs-pi-session-session-id session) "pending")
               "none"))))

(provide 'emacs-pi)
;;; emacs-pi.el ends here
