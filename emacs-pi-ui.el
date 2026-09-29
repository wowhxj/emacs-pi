;;; emacs-pi-ui.el --- Single-buffer chat view for Pi -*- lexical-binding: t; -*-

;;; Commentary:
;; The transcript is read-only; the composer at the bottom remains editable.

;;; Code:

(require 'cl-lib)
(require 'widget)
(require 'markdown-mode)
(require 'emacs-pi-core)
(require 'emacs-pi-session)

(declare-function emacs-pi-send "emacs-pi-input")
(declare-function emacs-pi-steer "emacs-pi-input")
(declare-function emacs-pi-focus-input "emacs-pi-input")
(declare-function emacs-pi-previous-prompt "emacs-pi-input")
(declare-function emacs-pi-next-prompt "emacs-pi-input")
(declare-function emacs-pi-stop "emacs-pi")
(declare-function emacs-pi-resume "emacs-pi")
(declare-function emacs-pi-switch-chat "emacs-pi")
(declare-function emacs-pi-quit "emacs-pi")
(declare-function emacs-pi-input-completion-at-point "emacs-pi-input")

(defface emacs-pi-user-face '((t :inherit font-lock-keyword-face :weight bold))
  "Face for user labels." :group 'emacs-pi)
(defface emacs-pi-assistant-face '((t :inherit font-lock-function-name-face :weight bold))
  "Face for Pi labels." :group 'emacs-pi)
(defface emacs-pi-tool-face '((t :inherit shadow))
  "Face for tool summaries." :group 'emacs-pi)

(defvar emacs-pi-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'emacs-pi-send)
    (define-key map (kbd "C-c C-c") #'emacs-pi-send)
    (define-key map (kbd "S-<return>") #'newline)
    (define-key map (kbd "S-RET") #'newline)
    (define-key map (kbd "C-c C-s") #'emacs-pi-steer)
    (define-key map (kbd "C-c C-k") #'emacs-pi-stop)
    (define-key map (kbd "C-c C-r") #'emacs-pi-resume)
    (define-key map (kbd "C-c C-b") #'emacs-pi-switch-chat)
    (define-key map (kbd "C-c C-i") #'emacs-pi-focus-input)
    (define-key map (kbd "C-c C-q") #'emacs-pi-quit)
    (define-key map (kbd "M-p") #'emacs-pi-previous-prompt)
    (define-key map (kbd "M-n") #'emacs-pi-next-prompt)
    (define-key map (kbd "TAB") #'completion-at-point)
    map)
  "Local keys for the Pi chat buffer.")

(defvar-local emacs-pi--session nil)
(defvar-local emacs-pi--input-marker nil)
(defvar-local emacs-pi--render-timer nil)
(defvar-local emacs-pi--draft-revision 0)
(defvar-local emacs-pi--input-history nil)
(defvar-local emacs-pi--history-index nil)
(defvar-local emacs-pi--history-draft nil)
(defvar-local emacs-pi--recovery nil)
(defconst emacs-pi--composer-prefix "\nYou> ")

(define-derived-mode emacs-pi-chat-mode fundamental-mode "emacs-pi"
  "Major mode for chatting with the Pi agent."
  (setq-local truncate-lines nil)
  (setq-local buffer-read-only nil)
  (tab-line-mode 1)
  (setq-local tab-line-format '(:eval (emacs-pi-ui--header)))
  (setq-local header-line-format '(:eval (emacs-pi-ui--pinned)))
  (add-hook 'completion-at-point-functions
            #'emacs-pi-input-completion-at-point nil t)
  (add-hook 'after-change-functions #'emacs-pi-ui--changed nil t)
  (add-hook 'kill-buffer-hook #'emacs-pi-ui--cleanup nil t))

(defun emacs-pi-ui--changed (begin _end _old-length)
  "Track input edits beginning at BEGIN."
  (when (and emacs-pi--input-marker
             (>= begin (+ (marker-position emacs-pi--input-marker)
                          (length emacs-pi--composer-prefix))))
    (cl-incf emacs-pi--draft-revision)))

(defun emacs-pi-ui--header ()
  "Return one-line Pi state for the tab line."
  (let ((session emacs-pi--session))
    (when session
      (let* ((model (emacs-pi-session-model session))
             (provider (emacs-pi--jget model "provider"))
             (id (emacs-pi--jget model "id"))
             (phase (emacs-pi-session-phase session))
             (state (cond ((eq phase 'dead) "disconnected")
                          ((not (eq phase 'ready)) "connecting")
                          ((emacs-pi-session-compacting session) "compacting")
                          ((emacs-pi-session-running session) "working")
                          (t "idle"))))
        (format " Pi: %s  ·  %s  ·  %s"
                state (if (and provider id) (format "%s/%s" provider id)
                        "model pending")
                (or (emacs-pi-session-thinking session) "thinking pending"))))))

(defun emacs-pi-ui--pinned ()
  "Return the latest sent user prompt for the header line."
  (when-let* ((prompt (and emacs-pi--session
                          (emacs-pi-session-last-prompt emacs-pi--session))))
    (truncate-string-to-width
     (concat " You: " (replace-regexp-in-string "[\r\n]+" " ↵ " prompt))
     (max 10 (1- (window-width))) nil nil "…")))

(defun emacs-pi-ui--markdown (text)
  "Return TEXT with Markdown font-lock faces and its original characters."
  (condition-case nil
      (with-temp-buffer
        (insert text)
        (delay-mode-hooks (markdown-mode))
        (font-lock-ensure)
        (buffer-substring (point-min) (point-max)))
    (error text)))

(defun emacs-pi-ui--insert-label (label face)
  "Insert LABEL with FACE."
  (insert (propertize label 'face face 'read-only t)))

(defun emacs-pi-ui--insert-blocks (message session)
  "Insert displayable content from MESSAGE using SESSION tool state."
  (let ((content (emacs-pi--jget message "content")))
    (cond
     ((stringp content) (insert (emacs-pi-ui--markdown content)))
     ((vectorp content)
      (dolist (block (append content nil))
        (pcase (emacs-pi--jget block "type")
          ("text" (insert (emacs-pi-ui--markdown
                            (or (emacs-pi--jget block "text") ""))))
          ("thinking"
           (when (and (boundp 'emacs-pi-show-thinking) emacs-pi-show-thinking)
             (insert (propertize
                      (format "\n  ✻ Thinking: %s\n"
                              (truncate-string-to-width
                               (or (emacs-pi--jget block "thinking") "")
                               120 nil nil "…"))
                      'face 'shadow))))
          ("toolCall"
           (let* ((id (emacs-pi--jget block "id"))
                  (name (or (emacs-pi--jget block "name") "tool"))
                  (state (and id (gethash id (emacs-pi-session-tools session))))
                  (done (equal (emacs-pi--jget state "type")
                               "tool_execution_end"))
                  (failed (emacs-pi--jtrue-p
                           (emacs-pi--jget state "isError"))))
             (insert (propertize
                      (format "\n  %s %s\n" (if done (if failed "✗" "✓") "●") name)
                      'face 'emacs-pi-tool-face))))
          ("image" (insert "[image]"))
          (_ nil)))))))

(defun emacs-pi-ui--transcript (session)
  "Insert SESSION transcript into current buffer."
  (dolist (message (emacs-pi-session-messages session))
    (let ((role (emacs-pi--jget message "role")))
      (pcase role
        ("user"
         (emacs-pi-ui--insert-label "You: " 'emacs-pi-user-face)
         (emacs-pi-ui--insert-blocks message session)
         (insert "\n\n"))
        ("assistant"
         (let ((content (emacs-pi--jget message "content")))
           (when (or (stringp content) (and (vectorp content) (> (length content) 0)))
             (emacs-pi-ui--insert-label "Pi: " 'emacs-pi-assistant-face)
             (emacs-pi-ui--insert-blocks message session)
             (insert "\n\n"))))
        ("toolResult" nil)
        (_ nil))))
  (when-let* ((stream (emacs-pi-session-active-message session)))
    (emacs-pi-ui--insert-label "Pi: " 'emacs-pi-assistant-face)
    (insert stream (propertize " ▍\n" 'face 'shadow)))
  (when-let* ((error (emacs-pi-session-error session)))
    (insert (propertize (format "[Pi: %s]\n" error) 'face 'error))))

(defun emacs-pi-ui-render (session)
  "Refresh transcript for SESSION while retaining the composer."
  (when-let* ((buffer (emacs-pi-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let* ((inhibit-read-only t)
               (at-end (>= (point) (max (point-min) (- (point-max) 2))))
               (start (marker-position emacs-pi--input-marker))
               (buffer-undo-list t))
          (save-excursion
            (delete-region (point-min) start)
            (goto-char (point-min))
            (emacs-pi-ui--transcript session)
            (add-text-properties (point-min)
                                 (marker-position emacs-pi--input-marker)
                                 '(read-only t rear-nonsticky (read-only))))
          (when at-end (goto-char (point-max)))
          (force-mode-line-update t))))))

(defun emacs-pi-ui-schedule (session _change)
  "Coalesce output updates for SESSION."
  (when-let* ((buffer (emacs-pi-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless emacs-pi--render-timer
          (setq emacs-pi--render-timer
                (run-at-time 0.05 nil
                             (lambda ()
                               (when (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (setq emacs-pi--render-timer nil)
                                   (emacs-pi-ui-render session)))))))))))

(defun emacs-pi-ui-create (session)
  "Create the single chat buffer for SESSION."
  (let* ((name (file-name-nondirectory
                (directory-file-name (emacs-pi-session-root session))))
         (buffer (generate-new-buffer
                  (format "*pi:%s#%s*" name
                          (substring (emacs-pi-session-client-id session) 0 6)))))
    (with-current-buffer buffer
      (setq default-directory (emacs-pi-session-root session))
      (emacs-pi-chat-mode)
      (setq-local emacs-pi--session session)
      (insert (propertize emacs-pi--composer-prefix
                          'read-only t 'rear-nonsticky '(read-only)))
      (setq-local emacs-pi--input-marker
                  (copy-marker (point-min) t))
      (goto-char (point-max)))
    (setf (emacs-pi-session-buffer session) buffer)
    buffer))

(defun emacs-pi-ui--cleanup ()
  "Release this buffer's timer and Pi process."
  (when emacs-pi--render-timer
    (cancel-timer emacs-pi--render-timer)
    (setq emacs-pi--render-timer nil))
  (when emacs-pi--session
    (emacs-pi-session-shutdown emacs-pi--session)))

(provide 'emacs-pi-ui)
;;; emacs-pi-ui.el ends here
