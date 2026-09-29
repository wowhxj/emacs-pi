;;; emacs-pi-input.el --- Composer and attachments for emacs-pi -*- lexical-binding: t; -*-

;;; Commentary:
;; Send a snapshot of the editable draft so asynchronous responses never
;; erase text typed after submission.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-pi-core)
(require 'emacs-pi-ui)

(defvar-local emacs-pi--attachments nil)
(defvar-local emacs-pi--attachment-overlay nil)

(defcustom emacs-pi-pngpaste-executable "pngpaste"
  "Program used to paste a macOS clipboard image as PNG.
Set this to an absolute path if GUI Emacs cannot find Homebrew programs."
  :type 'string :group 'emacs-pi)

(defun emacs-pi-input-beginning ()
  "Return the first editable position in the current Pi chat."
  (unless emacs-pi--input-marker (user-error "Not in an emacs-pi chat"))
  (+ (marker-position emacs-pi--input-marker)
     (length emacs-pi--composer-prefix)))

(defun emacs-pi-input-text ()
  "Return the current Pi draft without text properties."
  (buffer-substring-no-properties (emacs-pi-input-beginning) (point-max)))

(defun emacs-pi-input-set (text)
  "Replace the current Pi draft with TEXT."
  (let ((begin (emacs-pi-input-beginning)))
    (delete-region begin (point-max))
    (goto-char (point-max))
    (insert text)))

(defun emacs-pi-focus-input ()
  "Move point to the last non-whitespace character of the Pi composer."
  (interactive)
  (goto-char (+ (emacs-pi-input-beginning)
                (length (string-trim-right (emacs-pi-input-text))))))

(defun emacs-pi-input--show-attachments ()
  "Update the pending image names shown above the composer."
  (when emacs-pi--attachment-overlay
    (delete-overlay emacs-pi--attachment-overlay))
  (when emacs-pi--attachments
    (setq emacs-pi--attachment-overlay
          (make-overlay (marker-position emacs-pi--input-marker)
                        (marker-position emacs-pi--input-marker)))
    (overlay-put emacs-pi--attachment-overlay 'before-string
                 (concat (propertize
                          (format "[attached: %s]\n"
                                  (string-join
                                   (mapcar (lambda (item)
                                             (emacs-pi--jget item "name"))
                                           emacs-pi--attachments) ", "))
                          'face 'shadow)))))

(defun emacs-pi-attach-image (file &optional name)
  "Attach PNG or JPEG FILE to the next Pi prompt, optionally named NAME."
  (interactive "fImage file: ")
  (unless (derived-mode-p 'emacs-pi-chat-mode)
    (user-error "Not in an emacs-pi chat"))
  (let* ((size (file-attribute-size (file-attributes file))))
    (when (> size (* 10 1024 1024)) (user-error "Image exceeds 10 MiB"))
    (let* ((data (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert-file-contents-literally file)
                 (buffer-string)))
         (mime (cond ((string-prefix-p (unibyte-string 137 80 78 71 13 10 26 10)
                                      data) "image/png")
                     ((string-prefix-p (unibyte-string 255 216 255) data)
                      "image/jpeg"))))
    (unless mime (user-error "Only PNG and JPEG images are supported"))
    (push (emacs-pi--jobject "type" "image" "name"
                             (or name (file-name-nondirectory file))
                             "mimeType" mime "data" (base64-encode-string data t))
          emacs-pi--attachments)
    (emacs-pi-input--show-attachments)
    (message "Attached %s" (or name (file-name-nondirectory file))))))

(defun emacs-pi-input--pngpaste-program ()
  "Return a usable pngpaste program, including common GUI Emacs paths."
  (or (executable-find emacs-pi-pngpaste-executable)
      (cl-find-if #'file-executable-p
                  '("/opt/homebrew/bin/pngpaste" "/usr/local/bin/pngpaste"))))

(defun emacs-pi-paste ()
  "Paste a clipboard image as an attachment, or paste ordinary text.
On macOS, `pngpaste' converts the current clipboard image to PNG."
  (interactive)
  (unless (derived-mode-p 'emacs-pi-chat-mode)
    (user-error "Not in an emacs-pi chat"))
  (when (< (point) (emacs-pi-input-beginning))
    (emacs-pi-focus-input))
  (let ((program (emacs-pi-input--pngpaste-program)))
    (if (not program)
        (yank)
      (let ((file (make-temp-file "emacs-pi-clipboard-" nil ".png")))
        (unwind-protect
            (if (and (equal (call-process program nil nil nil file) 0)
                     (> (file-attribute-size (file-attributes file)) 0))
                (emacs-pi-attach-image file "clipboard.png")
              (yank))
          (when (file-exists-p file)
            (delete-file file)))))))

(defun emacs-pi-input-completion-at-point ()
  "Complete a local @path or a client /command in the Pi composer."
  (when (and emacs-pi--input-marker
             (>= (point) (emacs-pi-input-beginning)))
    (let ((end (point)))
      (save-excursion
        (cond
         ((and (save-excursion
                 (goto-char (emacs-pi-input-beginning))
                 (looking-at-p "/[^[:space:]]*\\'"))
               (<= end (point-max)))
          (list (emacs-pi-input-beginning) end
                (append '("/new" "/resume" "/model" "/thinking"
                          "/reasoning" "/queue" "/restart" "/stop"
                          "/doctor" "/help")
                        (mapcar (lambda (item)
                                  (concat "/" (emacs-pi--jget item "name")))
                                (and emacs-pi--session
                                     (emacs-pi-session-commands emacs-pi--session))))
                :exclusive 'no))
         ((re-search-backward "@\\([^[:space:]\n]*\\)"
                              (line-beginning-position) t)
          (let* ((prefix (match-string-no-properties 1))
                 (start (match-beginning 1))
                 (slash (string-match "/[^/]*\\'" prefix))
                 (dirpart (if slash (substring prefix 0 (1+ slash)) ""))
                 (leaf (if slash (substring prefix (1+ slash)) prefix))
                 (base (cond ((string-prefix-p "~/" prefix)
                              (expand-file-name dirpart))
                             ((file-name-absolute-p prefix) dirpart)
                             (t (expand-file-name dirpart
                                                  (emacs-pi-session-root
                                                   emacs-pi--session)))))
                 (names (when (file-directory-p base)
                          (file-name-all-completions leaf base))))
            (when names
              (list start end
                    (mapcar (lambda (name) (concat dirpart name)) names)
                    :category 'emacs-pi-file :exclusive 'no)))))))))

(cl-defun emacs-pi-input--send (behavior)
  "Submit draft with optional streaming BEHAVIOR."
  (unless (derived-mode-p 'emacs-pi-chat-mode)
    (user-error "Not in an emacs-pi chat"))
  (let ((session emacs-pi--session))
    (unless (eq (emacs-pi-session-phase session) 'ready)
      (user-error "Pi chat is not ready"))
    (when (and (equal behavior "steer")
               (not (emacs-pi-session-running session)))
      (user-error "Pi is idle; send a normal prompt"))
    (let* ((text (string-trim (emacs-pi-input-text)))
           (attachments (reverse emacs-pi--attachments))
           (buffer (current-buffer)))
      (when (and (string-empty-p text) (null attachments))
        (user-error "Write a prompt or attach an image first"))
      (when (and (string-prefix-p "/" text) (null behavior))
        (let* ((name (car (split-string text "[[:space:]]+")))
               (command (cdr (assoc text
                                   '(("/new" . emacs-pi-new-session)
                                     ("/resume" . emacs-pi-resume)
                                     ("/model" . emacs-pi-select-model)
                                     ("/thinking" . emacs-pi-select-thinking)
                                     ("/reasoning" . emacs-pi-select-thinking)
                                     ("/queue" . emacs-pi-show-queue)
                                     ("/restart" . emacs-pi-restart)
                                     ("/stop" . emacs-pi-stop)
                                     ("/doctor" . emacs-pi-doctor)
                                     ("/help" . emacs-pi-help)))))
               (server-command
                (seq-some (lambda (item)
                            (equal (concat "/" (emacs-pi--jget item "name")) name))
                          (emacs-pi-session-commands session))))
          (cond
           (command
            (when attachments
              (user-error "Remove or send attached images before a /command"))
            (funcall command)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer (emacs-pi-input-set "")))
            (cl-return-from emacs-pi-input--send nil))
           ((not server-command)
            (user-error "Unknown Pi command %s; use /help" name)))))
      (emacs-pi-input-set "")
      (setq emacs-pi--attachments nil)
      (emacs-pi-input--show-attachments)
      (let ((restore-revision emacs-pi--draft-revision))
        (emacs-pi-session-submit
         session text attachments behavior
         (lambda (result)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (if (plist-get result :ok)
                   (progn
                     (unless (equal text (car emacs-pi--input-history))
                       (push text emacs-pi--input-history))
                     (setq emacs-pi--history-index nil
                           emacs-pi--history-draft nil)
                     (message "Pi accepted prompt"))
                 (if (and (not (plist-get result :uncertain-p))
                          (= restore-revision emacs-pi--draft-revision)
                          (string-empty-p (emacs-pi-input-text)))
                     (progn (emacs-pi-input-set text)
                            (setq emacs-pi--attachments attachments)
                            (emacs-pi-input--show-attachments))
                   (push (list :text text :attachments attachments
                               :uncertain (plist-get result :uncertain-p))
                         emacs-pi--recovery))
                 (message "Pi: %s%s" (plist-get result :message)
                          (if (plist-get result :uncertain-p)
                              " (send status unknown; recover with M-x emacs-pi-recover-input)"
                            "")))))))))))

(defun emacs-pi-send ()
  "Send the Pi draft, or queue a follow-up while Pi is working."
  (interactive)
  (emacs-pi-input--send nil))

(defun emacs-pi-steer ()
  "Steer the active Pi run with the current draft."
  (interactive)
  (emacs-pi-input--send "steer"))

(defun emacs-pi-recover-input ()
  "Recover an earlier rejected or uncertain prompt into the draft."
  (interactive)
  (unless emacs-pi--recovery (user-error "No saved input to recover"))
  (let* ((item (pop emacs-pi--recovery))
         (text (plist-get item :text)))
    (when (and (not (string-empty-p (emacs-pi-input-text)))
               (not (y-or-n-p "Append recovered text to current draft? ")))
      (push item emacs-pi--recovery)
      (user-error "Recovery cancelled"))
    (goto-char (point-max))
    (unless (string-empty-p (emacs-pi-input-text)) (insert "\n"))
    (insert text)
    (setq emacs-pi--attachments
          (append (plist-get item :attachments) emacs-pi--attachments))
    (emacs-pi-input--show-attachments)
    (when (plist-get item :uncertain)
      (message "This prompt may already have been sent; inspect history before resending"))))

(defun emacs-pi-input--history (direction)
  "Move through prompt history by DIRECTION."
  (unless emacs-pi--input-history (user-error "No earlier prompts"))
  (when (and (null emacs-pi--history-index) (> direction 0))
    (setq emacs-pi--history-draft (emacs-pi-input-text)))
  (let ((index (max -1 (min (1- (length emacs-pi--input-history))
                           (+ (or emacs-pi--history-index -1) direction)))))
    (setq emacs-pi--history-index (unless (= index -1) index))
    (emacs-pi-input-set
     (if (= index -1) (or emacs-pi--history-draft "")
       (nth index emacs-pi--input-history)))))

(defun emacs-pi-previous-prompt ()
  "Show the previous submitted prompt."
  (interactive)
  (emacs-pi-input--history 1))

(defun emacs-pi-next-prompt ()
  "Show the next submitted prompt or restore the unsent draft."
  (interactive)
  (emacs-pi-input--history -1))

(provide 'emacs-pi-input)
;;; emacs-pi-input.el ends here
