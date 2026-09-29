;;; emacs-pi.el --- Chat with Pi Coding Agent in Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 emacs-pi contributors
;; Author: emacs-pi contributors
;; Version: 0.2.7
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
(defvar-local emacs-pi--queue-session nil)

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

(defun emacs-pi--show-chat (buffer)
  "Show Pi chat BUFFER in the selected frame's sole window."
  (switch-to-buffer buffer)
  (delete-other-windows)
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

(defun emacs-pi--open (root &optional session-file)
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
    (emacs-pi--show-chat buffer)
    (emacs-pi-ui-render session)
    buffer))

;;;###autoload
(defun emacs-pi-chat (&optional root)
  "Choose a saved Pi session in ROOT, or start a new one."
  (interactive)
  (let* ((start (if buffer-file-name
                    (file-name-directory buffer-file-name) default-directory))
         (directory (or root (read-directory-name "Pi project root: " start
                                                   nil t))))
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

(defun emacs-pi-shutdown ()
  "Shut down the Pi process while leaving the transcript visible."
  (interactive)
  (emacs-pi-session-shutdown (emacs-pi--require-session)))

(defun emacs-pi-quit ()
  "Close this chat, stopping its Pi process and killing its buffer."
  (interactive)
  (emacs-pi--require-session)
  (kill-buffer (current-buffer)))

(defun emacs-pi--queue-image-preview (image)
  "Return an inline preview for queued IMAGE when Emacs can display it."
  (let* ((mime (emacs-pi--jget image "mimeType"))
         (type (cdr (assoc mime '(("image/png" . png)
                                  ("image/jpeg" . jpeg)))))
         (data (emacs-pi--jget image "data")))
    (when (and (display-images-p) type (stringp data))
      (condition-case nil
          (propertize "[image]" 'display
                      (create-image (base64-decode-string data) type t
                                    :height 96))
        (error nil)))))

(defun emacs-pi--queue-render (session)
  "Render the latest read-only queue snapshot for SESSION."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (erase-buffer)
    (insert (propertize "Pi queue\n" 'face 'bold)
            "g refresh · q close\n\n")
    (if (not (emacs-pi-session-queue-known session))
        (insert "Queue details have not arrived yet.\n")
      (let* ((steering (emacs-pi--array-list
                        (emacs-pi-session-steering session)))
             (follow-up (emacs-pi--array-list
                         (emacs-pi-session-follow-up session)))
             (all (append steering follow-up))
             (attachments (emacs-pi-session-queue-attachments session)))
        (dolist (group `(("Steering" . ,steering)
                         ("Follow-up" . ,follow-up)))
          (insert (format "%s (%d):\n" (car group) (length (cdr group))))
          (if (cdr group)
              (cl-loop for item in (cdr group)
                       for index from 1
                       do (insert (format "  %d. %s\n" index item))
                       (let ((images (and attachments
                                          (gethash item attachments))))
                         (cond
                          ((and images
                                (> (cl-count item all :test #'equal) 1))
                           (insert "     [identical messages: image association unavailable]\n"))
                          ((eq images :ambiguous)
                           (insert "     [image association unavailable]\n"))
                          ((listp images)
                           (dolist (image images)
                             (insert "     "
                                     (or (emacs-pi--queue-image-preview image)
                                         "[image]")
                                     " "
                                     (or (emacs-pi--jget image "name") "image")
                                     "\n"))))))
            (insert "  (empty)\n"))
          (insert "\n"))))
    (insert (propertize
             "Pi RPC currently exposes only whole-queue clear; individual edits, "
             'face 'shadow)
            (propertize
             "reordering and moving between lanes require a Pi RPC queue API.\n"
             'face 'shadow))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun emacs-pi-show-queue ()
  "Show Pi's steering and follow-up queue with known image previews."
  (interactive)
  (let* ((session (emacs-pi--require-session))
         (buffer (get-buffer-create
                  (format "*pi-queue:%s*"
                          (substring (emacs-pi-session-client-id session) 0 6)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode))
      (setq-local emacs-pi--queue-session session)
      (setq-local revert-buffer-function
                  (lambda (&rest _) (emacs-pi--queue-render session)))
      (emacs-pi--queue-render session))
    (pop-to-buffer buffer)))

(defun emacs-pi-help ()
  "Show client commands and chat keys."
  (interactive)
  (with-help-window "*emacs-pi-help*"
    (princ "emacs-pi commands\n\n")
    (princ "/new  /resume  /model  /thinking  /reasoning\n")
    (princ "/queue  /restart  /stop  /doctor  /help\n\n")
    (princ "RET send · S-RET newline · C-c C-s steer · C-c C-k stop\n")
    (princ "C-c C-l queue · C-c C-r resume · C-c C-b switch chats · C-c C-q close\n")
    (princ "i focus input from history · C-a stay after You>\n")
    (princ "RET/TAB on a Process or tool heading toggles its steps\n")
    (princ "M-p/M-n prompt history · TAB/M-TAB minibuffer completion\n\n")
    (princ "M-x emacs-pi-attach-image adds a PNG/JPEG to the next prompt.\n")
    (princ "@path is a path hint; @session includes saved dialogue context.\n")))

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
