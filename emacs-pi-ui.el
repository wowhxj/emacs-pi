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
(declare-function emacs-pi-input-beginning "emacs-pi-input")
(declare-function emacs-pi-previous-prompt "emacs-pi-input")
(declare-function emacs-pi-next-prompt "emacs-pi-input")
(declare-function emacs-pi-stop "emacs-pi")
(declare-function emacs-pi-show-queue "emacs-pi")
(declare-function emacs-pi-resume "emacs-pi")
(declare-function emacs-pi-switch-chat "emacs-pi")
(declare-function emacs-pi-quit "emacs-pi")
(declare-function emacs-pi-input-completion-at-point "emacs-pi-input")
(declare-function emacs-pi-complete "emacs-pi-input")
(declare-function emacs-pi-paste "emacs-pi-input")
(defvar emacs-pi-show-thinking)
(defvar emacs-pi--chats)
(defvar emacs-pi--queue-session)

(defface emacs-pi-user-face '((t :inherit font-lock-keyword-face :weight bold))
  "Face for user labels." :group 'emacs-pi)
(defface emacs-pi-assistant-face '((t :inherit font-lock-function-name-face :weight bold))
  "Face for Pi labels." :group 'emacs-pi)
(defface emacs-pi-tool-face '((t :inherit shadow))
  "Face for tool summaries." :group 'emacs-pi)
(defface emacs-pi-input-face '((t :inherit widget-field :extend t))
  "Background of the Pi composer." :group 'emacs-pi)
(defface emacs-pi-status-face '((t :inherit mode-line))
  "Face for Pi activity in the mode line." :group 'emacs-pi)

(defvar emacs-pi-ui--process-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'emacs-pi-ui-toggle-process)
    (define-key map (kbd "TAB") #'emacs-pi-ui-toggle-process)
    (define-key map [mouse-1] #'emacs-pi-ui-toggle-process)
    map)
  "Keys on an intermediate-process heading.")

(defvar emacs-pi-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'emacs-pi-ui-return)
    (define-key map (kbd "C-c C-c") #'emacs-pi-send)
    (define-key map (kbd "S-<return>") #'newline)
    (define-key map (kbd "S-RET") #'newline)
    (define-key map (kbd "C-c C-s") #'emacs-pi-steer)
    (define-key map (kbd "C-c C-k") #'emacs-pi-stop)
    (define-key map (kbd "C-c C-l") #'emacs-pi-show-queue)
    (define-key map (kbd "C-c C-r") #'emacs-pi-resume)
    (define-key map (kbd "C-c C-b") #'emacs-pi-switch-chat)
    (define-key map (kbd "C-c C-i") #'emacs-pi-focus-input)
    (define-key map (kbd "C-c C-p") #'emacs-pi-paste)
    (define-key map (kbd "s-v") #'emacs-pi-paste)
    (define-key map (kbd "C-c C-q") #'emacs-pi-quit)
    (define-key map (kbd "M-p") #'emacs-pi-previous-prompt)
    (define-key map (kbd "M-n") #'emacs-pi-next-prompt)
    (define-key map (kbd "TAB") #'emacs-pi-ui-tab)
    (define-key map (kbd "M-TAB") #'emacs-pi-complete)
    (define-key map (kbd "i") #'emacs-pi-ui-focus-or-insert)
    (define-key map (kbd "C-a") #'emacs-pi-ui-beginning-of-line)
    map)
  "Local keys for the Pi chat buffer.")

(defvar-local emacs-pi--session nil)
(defvar-local emacs-pi--input-marker nil)
(defvar-local emacs-pi--render-timer nil)
(defvar-local emacs-pi--spinner-timer nil)
(defvar-local emacs-pi--spinner-index 0)
(defvar-local emacs-pi--input-background nil)
(defvar-local emacs-pi--user-overlays nil)
(defvar-local emacs-pi--process-overlays nil)
(defvar-local emacs-pi--fold-expanded nil)
(defvar-local emacs-pi--fold-was-running nil)
(defvar-local emacs-pi--detail-index 0)
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
  (setq-local buffer-invisibility-spec (copy-tree buffer-invisibility-spec))
  (add-to-invisibility-spec 'emacs-pi-process)
  (setq-local emacs-pi--fold-expanded (make-hash-table :test #'equal))
  (tab-line-mode 1)
  (setq-local tab-line-format '(:eval (emacs-pi-ui--header)))
  (setq-local header-line-format '(:eval (emacs-pi-ui--pinned)))
  (setq-local mode-line-misc-info
              (cons '(:eval (emacs-pi-ui--state)) mode-line-misc-info))
  (add-hook 'completion-at-point-functions
            #'emacs-pi-input-completion-at-point nil t)
  (add-hook 'after-change-functions #'emacs-pi-ui--changed nil t)
  (add-hook 'kill-buffer-hook #'emacs-pi-ui--cleanup nil t))

(defun emacs-pi-ui-focus-or-insert ()
  "Jump to the composer from history; insert i inside the composer."
  (interactive)
  (if (< (point) (emacs-pi-input-beginning))
      (emacs-pi-focus-input)
    (let ((last-command-event ?i))
      (self-insert-command 1))))

(defun emacs-pi-ui-beginning-of-line ()
  "Move to line start without entering the protected composer prompt."
  (interactive)
  (let ((composer-line
         (save-excursion
           (goto-char (emacs-pi-input-beginning))
           (line-beginning-position))))
    (move-beginning-of-line 1)
    (when (= (point) composer-line)
      (goto-char (emacs-pi-input-beginning)))))

(defun emacs-pi-ui--process-at-point ()
  "Return the process-heading overlay at point, if any."
  (or (cl-find-if (lambda (overlay) (overlay-get overlay 'emacs-pi-process))
                  (overlays-at (point)))
      (when (and (> (point) (point-min))
                 (not (eq (char-before) ?\n)))
        (cl-find-if (lambda (overlay) (overlay-get overlay 'emacs-pi-process))
                    (overlays-at (1- (point)))))))

(defun emacs-pi-ui-return ()
  "Toggle a process heading or send the composer draft."
  (interactive)
  (if (emacs-pi-ui--process-at-point)
      (emacs-pi-ui-toggle-process)
    (emacs-pi-send)))

(defun emacs-pi-ui-tab ()
  "Toggle a process heading or choose prompt completion in the minibuffer."
  (interactive)
  (if (emacs-pi-ui--process-at-point)
      (emacs-pi-ui-toggle-process)
    (emacs-pi-complete)))

(defun emacs-pi-ui--state ()
  "Return Pi's current activity for the ordinary mode line."
  (when emacs-pi--session
    (let* ((session emacs-pi--session)
           (running (emacs-pi-session-running session))
           (tool (emacs-pi-session-active-tool session))
           (phase (emacs-pi-session-phase session))
           (steering (length (emacs-pi--array-list
                              (emacs-pi-session-steering session))))
           (follow-up (length (emacs-pi--array-list
                               (emacs-pi-session-follow-up session)))))
      (propertize
       (format " Pi %s%s%s"
               (cond ((eq phase 'dead) "disconnected")
                     ((not (eq phase 'ready)) "connecting")
                     ((emacs-pi-session-compacting session) "compacting")
                     (tool (format "tool: %s" tool))
                     (running "thinking")
                     (t "idle"))
               (if running
                   (format " %c" (aref "|/-\\" (mod emacs-pi--spinner-index 4)))
                 "")
               (if (or (> steering 0) (> follow-up 0))
                   (format " [S%d F%d]" steering follow-up)
                 ""))
       'face 'emacs-pi-status-face))))

(defun emacs-pi-ui--sync-spinner ()
  "Run the mode-line spinner only while Pi is active."
  (if (and emacs-pi--session
           (emacs-pi-session-running emacs-pi--session))
      (unless emacs-pi--spinner-timer
        (let ((buffer (current-buffer)))
          (setq emacs-pi--spinner-timer
                (run-at-time 0.15 0.15
                             (lambda ()
                               (when (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (cl-incf emacs-pi--spinner-index)
                                   (force-mode-line-update t))))))))
    (when emacs-pi--spinner-timer
      (cancel-timer emacs-pi--spinner-timer)
      (setq emacs-pi--spinner-timer nil)))
  (force-mode-line-update t))

(defun emacs-pi-ui--changed (begin _end _old-length)
  "Track input edits beginning at BEGIN."
  (when (and emacs-pi--input-marker
             (>= begin (+ (marker-position emacs-pi--input-marker)
                          (length emacs-pi--composer-prefix))))
    (cl-incf emacs-pi--draft-revision)))

(defun emacs-pi-ui--user-message-face ()
  "Use the theme's warning color to highlight historical user messages."
  (let* ((warning (or (face-foreground 'warning nil t) "#d97706"))
         (rgb (and (stringp warning)
                   (ignore-errors (color-values warning))))
         (luminance (when rgb
                      (/ (+ (* 0.2126 (nth 0 rgb))
                            (* 0.7152 (nth 1 rgb))
                            (* 0.0722 (nth 2 rgb)))
                         65535.0))))
    (list :background warning
          :foreground (if (and luminance (> luminance 0.5))
                          "#111111" "#ffffff")
          :extend t)))

(defun emacs-pi-ui--format-tokens (value)
  "Format token VALUE compactly for the status line."
  (cond ((>= value 1000000) (format "%.1fM" (/ value 1000000.0)))
        ((>= value 1000) (format "%.1fk" (/ value 1000.0)))
        (t (number-to-string value))))

(defun emacs-pi-ui--header ()
  "Return Pi context usage and model for the tab line."
  (let ((session emacs-pi--session))
    (when session
      (let* ((model (emacs-pi-session-model session))
             (provider (emacs-pi--jget model "provider"))
             (id (emacs-pi--jget model "id"))
             (usage (emacs-pi-session-context-usage session))
             (tokens (emacs-pi--jget usage "tokens"))
             (window (emacs-pi--jget usage "contextWindow"))
             (left (if (and (numberp tokens) (numberp window))
                       (format "%s/%s"
                               (emacs-pi-ui--format-tokens tokens)
                               (emacs-pi-ui--format-tokens window))
                     "context: —"))
             (right (format "%s · %s"
                            (if (and provider id)
                                (format "(%s) %s" provider id)
                              "model pending")
                            (or (emacs-pi-session-thinking session)
                                "thinking pending"))))
        (concat " " left " "
                (propertize " " 'display
                            `(space :align-to (- right ,(string-width right))))
                (replace-regexp-in-string "%" "%%" right))))))

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

(defun emacs-pi-ui--insert-detail (label detail key &optional column)
  "Insert a collapsed step LABEL with expandable DETAIL under KEY.
When COLUMN is non-nil, align details on following lines to that column."
  (if (and column (bolp))
      (insert (make-string column ?\s))
    (insert "  "))
  (let ((start (point)))
    (insert "▸ " label "\n")
    (let ((body-start (point)))
      (insert (or detail "") "\n")
      (emacs-pi-ui--fold-process start body-start (point) key label))))

(defun emacs-pi-ui--tool-result-text (state)
  "Return a bounded readable result from tool execution STATE."
  (let* ((result (emacs-pi--jget state "result"))
         (blocks (emacs-pi--array-list (emacs-pi--jget result "content")))
         (texts (delq nil
                      (mapcar (lambda (block)
                                (emacs-pi--jget block "text")) blocks)))
         (content (string-join texts "\n")))
    (unless (string-empty-p content)
      (truncate-string-to-width content 4000 nil nil "…"))))

(defun emacs-pi-ui--visible-message-text (message text)
  "Hide appended reference context in displayed user MESSAGE TEXT."
  (if (equal (emacs-pi--jget message "role") "user")
      (if-let* ((boundary (string-match
                           (regexp-quote emacs-pi--session-reference-boundary)
                           text)))
          (substring text 0 boundary)
        text)
    text))

(defun emacs-pi-ui--insert-blocks (message session &optional final-only detail-column)
  "Insert MESSAGE content; FINAL-ONLY skips intermediate steps.
Align subsequent step headings to DETAIL-COLUMN when non-nil."
  (let ((content (emacs-pi--jget message "content")))
    (cond
     ((stringp content)
      (insert (emacs-pi-ui--markdown
               (emacs-pi-ui--visible-message-text message content))))
     ((vectorp content)
      (dolist (block (append content nil))
        (pcase (emacs-pi--jget block "type")
          ("text" (insert (emacs-pi-ui--markdown
                            (emacs-pi-ui--visible-message-text
                             message (or (emacs-pi--jget block "text") "")))))
          ("thinking"
           (when (and (not final-only)
                      (boundp 'emacs-pi-show-thinking) emacs-pi-show-thinking)
             (let* ((thought (or (emacs-pi--jget block "thinking") ""))
                    (summary (truncate-string-to-width
                              (replace-regexp-in-string "[\r\n]+" " " thought)
                              100 nil nil "…")))
               (emacs-pi-ui--insert-detail
                (concat "✻ Thinking: " summary) thought
                (format "thinking:%d" (cl-incf emacs-pi--detail-index))
                detail-column))))
          ("toolCall"
           (unless final-only
             (let* ((id (emacs-pi--jget block "id"))
                  (name (or (emacs-pi--jget block "name") "tool"))
                  (state (and id (gethash id (emacs-pi-session-tools session))))
                  (done (equal (emacs-pi--jget state "type")
                               "tool_execution_end"))
                  (failed (emacs-pi--jtrue-p
                           (emacs-pi--jget state "isError")))
                  (arguments (emacs-pi--jget block "arguments"))
                  (result (emacs-pi-ui--tool-result-text state))
                  (detail (concat
                           (when arguments
                             (format "Arguments: %s\n"
                                     (truncate-string-to-width
                                      (emacs-pi--jencode arguments)
                                      4000 nil nil "…")))
                           (when result (format "Result:\n%s\n" result)))))
               (emacs-pi-ui--insert-detail
                (format "%s %s" (if done (if failed "✗" "✓") "●") name)
                detail
                (format "tool:%s" (or id (cl-incf emacs-pi--detail-index)))
                detail-column))))
          ("image" (insert "[image]"))
          (_ nil)))))))

(defun emacs-pi-ui--content-types (message)
  "Return the block type strings in MESSAGE."
  (let ((content (emacs-pi--jget message "content")))
    (when (vectorp content)
      (mapcar (lambda (block) (emacs-pi--jget block "type"))
              (append content nil)))))

(defun emacs-pi-ui--final-p (message)
  "Whether MESSAGE has answer text without a tool call."
  (let ((content (emacs-pi--jget message "content")))
    (or (and (stringp content) (not (string-empty-p content)))
        (and (member "text" (emacs-pi-ui--content-types message))
             (not (member "toolCall" (emacs-pi-ui--content-types message)))))))

(defun emacs-pi-ui--thinking-blocks (message)
  "Return MESSAGE's thinking blocks."
  (let ((content (emacs-pi--jget message "content")))
    (when (vectorp content)
      (cl-remove-if-not
       (lambda (block) (equal (emacs-pi--jget block "type") "thinking"))
       (append content nil)))))

(defun emacs-pi-ui--step-count (message)
  "Count visible thinking and tool steps in MESSAGE."
  (let* ((types (emacs-pi-ui--content-types message))
         (special (cl-count-if
                   (lambda (type)
                     (or (equal type "toolCall")
                         (and emacs-pi-show-thinking
                              (equal type "thinking"))))
                   types)))
    (max 1 special)))

(defun emacs-pi-ui--process-heading (label expanded)
  "Return a process heading for LABEL, shown EXPANDED or collapsed."
  (propertize (concat (if expanded "▾ " "▸ ") label
                      (unless expanded "\n"))
              'face 'shadow))

(defun emacs-pi-ui--fold-process (start body-start end key label
                                      &optional default-expanded)
  "Fold process text START..END, where BODY-START begins its details.
DEFAULT-EXPANDED applies until the user toggles this process."
  (let* ((stored (gethash key emacs-pi--fold-expanded 'unset))
         (expanded (if (eq stored 'unset) default-expanded (eq stored t)))
         (header (make-overlay start (1- body-start) nil t nil))
         (body (make-overlay (1- body-start) end nil nil nil)))
    (overlay-put header 'display (emacs-pi-ui--process-heading label expanded))
    (overlay-put header 'emacs-pi-process body)
    (overlay-put header 'emacs-pi-process-key key)
    (overlay-put header 'emacs-pi-process-label label)
    (overlay-put header 'keymap emacs-pi-ui--process-map)
    (overlay-put header 'mouse-face 'highlight)
    (overlay-put header 'help-echo "RET, TAB or click: toggle intermediate steps")
    (overlay-put body 'invisible (unless expanded 'emacs-pi-process))
    (push header emacs-pi--process-overlays)
    (push body emacs-pi--process-overlays)))

(defun emacs-pi-ui-toggle-process (&optional event)
  "Show or hide intermediate Pi steps at point or mouse EVENT."
  (interactive (list last-input-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (let* ((header (emacs-pi-ui--process-at-point))
         (body (and header (overlay-get header 'emacs-pi-process))))
    (unless body (user-error "Move to a Pi process heading first"))
    (let* ((key (overlay-get header 'emacs-pi-process-key))
           (expanded (overlay-get body 'invisible)))
      (puthash key (if expanded t 'collapsed) emacs-pi--fold-expanded)
      (overlay-put body 'invisible (unless expanded 'emacs-pi-process))
      (overlay-put header 'display
                   (emacs-pi-ui--process-heading
                    (overlay-get header 'emacs-pi-process-label) expanded)))))

(defun emacs-pi-ui--turns (messages)
  "Group MESSAGES by user turn."
  (let (turn turns)
    (dolist (message messages)
      (when (and turn (equal (emacs-pi--jget message "role") "user"))
        (push (nreverse turn) turns)
        (setq turn nil))
      (push message turn))
    (when turn (push (nreverse turn) turns))
    (nreverse turns)))

(defun emacs-pi-ui--render-turn (turn session key active-p)
  "Render one TURN of SESSION, keeping its process fold under KEY.
ACTIVE-P means this is the turn currently being processed by Pi."
  (let* ((user (and (equal (emacs-pi--jget (car turn) "role") "user")
                    (car turn)))
         (responses (if user (cdr turn) turn))
         (assistants (cl-remove-if-not
                      (lambda (message)
                        (equal (emacs-pi--jget message "role") "assistant"))
                      responses))
         (candidate (car (last assistants)))
         (final (and candidate (emacs-pi-ui--final-p candidate) candidate))
         (steps (if final (delq final (copy-sequence assistants)) assistants))
         (thinking (and final emacs-pi-show-thinking
                        (emacs-pi-ui--thinking-blocks final)))
         (count (+ (apply #'+ (mapcar #'emacs-pi-ui--step-count steps))
                   (length thinking))))
    (when user
      (let ((start (point)))
        (emacs-pi-ui--insert-label "You: " 'emacs-pi-user-face)
        (emacs-pi-ui--insert-blocks user session)
        (unless (bolp) (insert "\n"))
        (let ((overlay (make-overlay start (point) nil t nil)))
          (overlay-put overlay 'face (emacs-pi-ui--user-message-face))
          (overlay-put overlay 'evaporate t)
          (push overlay emacs-pi--user-overlays))
        (insert "\n")))
    (when (> count 0)
      (let ((start (point))
            (label (format "Process · %d step%s" count
                           (if (= count 1) "" "s"))))
        (insert "▸ " label "\n")
        (let ((body-start (point)))
          (dolist (message steps)
            (emacs-pi-ui--insert-label "Pi step: " 'emacs-pi-tool-face)
            (emacs-pi-ui--insert-blocks
             message session nil (+ (length "Pi step: ") 2))
            (unless (bolp) (insert "\n")))
          (dolist (block thinking)
            (let* ((thought (or (emacs-pi--jget block "thinking") ""))
                   (summary (truncate-string-to-width
                             (replace-regexp-in-string "[\r\n]+" " " thought)
                             100 nil nil "…")))
              (emacs-pi-ui--insert-detail
               (concat "✻ Thinking: " summary) thought
               (format "thinking:%d" (cl-incf emacs-pi--detail-index)))))
          (emacs-pi-ui--fold-process start body-start (point) key label
                                     (and active-p (not final))))))
    (when final
      (emacs-pi-ui--insert-label "Pi: " 'emacs-pi-assistant-face)
      (emacs-pi-ui--insert-blocks final session t)
      (insert "\n\n"))))

(defun emacs-pi-ui--transcript (session)
  "Insert SESSION transcript into current buffer."
  (let* ((turns (emacs-pi-ui--turns (emacs-pi-session-messages session)))
         (active-key (1- (length turns))))
    (cl-loop for turn in turns
             for key from 0
             do (emacs-pi-ui--render-turn
                 turn session key
                 (and (emacs-pi-session-running session)
                      (= key active-key)))))
  (when-let* ((stream (emacs-pi-session-active-message session)))
    (emacs-pi-ui--insert-label "Pi: " 'emacs-pi-assistant-face)
    (insert stream (propertize " ▍\n" 'face 'shadow)))
  (when-let* ((error (emacs-pi-session-error session)))
    (insert (propertize (format "[Pi: %s]\n" error) 'face 'error))))

(defun emacs-pi-ui--sync-fold-state (session)
  "Reset process and step folds when SESSION starts or finishes a run."
  (let ((running (emacs-pi-session-running session)))
    (unless (eq running emacs-pi--fold-was-running)
      (clrhash emacs-pi--fold-expanded)
      (setq emacs-pi--fold-was-running running))))

(defun emacs-pi-ui-render (session)
  "Refresh transcript for SESSION while retaining the composer."
  (when-let* ((buffer (emacs-pi-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (emacs-pi-ui--sync-fold-state session)
        (let* ((inhibit-read-only t)
               (at-end (>= (point) (max (point-min) (- (point-max) 2))))
               (start (marker-position emacs-pi--input-marker))
               (buffer-undo-list t))
          (mapc #'delete-overlay emacs-pi--user-overlays)
          (setq emacs-pi--user-overlays nil)
          (mapc #'delete-overlay emacs-pi--process-overlays)
          (setq emacs-pi--process-overlays nil)
          (setq emacs-pi--detail-index 0)
          (save-excursion
            (delete-region (point-min) start)
            (goto-char (point-min))
            (emacs-pi-ui--transcript session)
            (add-text-properties (point-min)
                                 (marker-position emacs-pi--input-marker)
                                 '(read-only t rear-nonsticky nil))
            (when (< (point-min) (marker-position emacs-pi--input-marker))
              (add-text-properties (point-min) (1+ (point-min))
                                   '(front-sticky (read-only)))))
          (when emacs-pi--input-background
            (move-overlay emacs-pi--input-background
                          (1+ (marker-position emacs-pi--input-marker))
                          (point-max))
            (overlay-put emacs-pi--input-background 'face
                         'emacs-pi-input-face))
          (when at-end (goto-char (point-max)))
          (force-mode-line-update t))))))

(defun emacs-pi-ui-schedule (session _change)
  "Coalesce output updates for SESSION."
  (when-let* ((buffer (emacs-pi-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (emacs-pi-ui--sync-fold-state session)
        (emacs-pi-ui--sync-spinner)
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
      (let ((prefix (propertize emacs-pi--composer-prefix 'read-only t)))
        (add-text-properties 0 1 '(front-sticky (read-only)) prefix)
        (add-text-properties (1- (length prefix)) (length prefix)
                             '(rear-nonsticky (read-only)) prefix)
        (insert prefix))
      (setq-local emacs-pi--input-marker
                  (copy-marker (point-min) t))
      (setq-local emacs-pi--input-background
                  (make-overlay (1+ (marker-position emacs-pi--input-marker))
                                (point-max) nil t t))
      (overlay-put emacs-pi--input-background 'face 'emacs-pi-input-face)
      (goto-char (point-max))
      (setq buffer-undo-list nil))
    (setf (emacs-pi-session-buffer session) buffer)
    buffer))

(defun emacs-pi-ui--cleanup ()
  "Release this chat's registry entry, Pi process, and timers."
  (when emacs-pi--session
    (let* ((session emacs-pi--session)
           (id (emacs-pi-session-client-id session)))
      (when-let* ((queue (get-buffer
                          (format "*pi-queue:%s*"
                                  (substring id 0 (min 6 (length id)))))))
        (with-current-buffer queue
          (when (eq emacs-pi--queue-session session)
            (kill-buffer queue))))
      (when (and (boundp 'emacs-pi--chats)
                 (eq (gethash id emacs-pi--chats) (current-buffer)))
        (remhash id emacs-pi--chats))
      (setf (emacs-pi-session-buffer session) nil)
      (emacs-pi-session-shutdown session)))
  (when emacs-pi--render-timer
    (cancel-timer emacs-pi--render-timer)
    (setq emacs-pi--render-timer nil))
  (when emacs-pi--spinner-timer
    (cancel-timer emacs-pi--spinner-timer)
    (setq emacs-pi--spinner-timer nil)))

(provide 'emacs-pi-ui)
;;; emacs-pi-ui.el ends here
