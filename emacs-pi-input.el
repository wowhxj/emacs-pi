;;; emacs-pi-input.el --- Composer and attachments for emacs-pi -*- lexical-binding: t; -*-

;;; Commentary:
;; Send a snapshot of the editable draft so asynchronous responses never
;; erase text typed after submission.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'emacs-pi-core)
(require 'emacs-pi-history)
(require 'emacs-pi-ui)

(defvar-local emacs-pi--attachments nil)
(defvar-local emacs-pi--attachment-overlay nil)

(defconst emacs-pi-input--local-commands
  '(("/new" . "Start a new session")
    ("/resume" . "Choose a saved session")
    ("/model" . "Select model")
    ("/thinking" . "Select thinking level")
    ("/reasoning" . "Select thinking level")
    ("/queue" . "Show queued prompts")
    ("/restart" . "Restart this Pi process")
    ("/reload" . "Restart Pi RPC and reload extensions/resources")
    ("/stop" . "Stop and clear the queue")
    ("/doctor" . "Show connection details")
    ("/help" . "Show commands"))
  "Commands handled directly by emacs-pi.")

(defconst emacs-pi-input--session-mention-regexp
  "@\\[[^]\n]*\\](pi-session:\\([[:alnum:]_-]+\\))"
  "Pattern for client-side Pi session references.")

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

(defun emacs-pi-input--image-object (file &optional name)
  "Read PNG or JPEG FILE into a Pi image object, optionally named NAME."
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
    (emacs-pi--jobject "type" "image" "name"
                       (or name (file-name-nondirectory file))
                       "mimeType" mime "data" (base64-encode-string data t)))))

(defun emacs-pi-attach-image (file &optional name)
  "Attach PNG or JPEG FILE to the next Pi prompt, optionally named NAME."
  (interactive "fImage file: ")
  (unless (derived-mode-p 'emacs-pi-chat-mode)
    (user-error "Not in an emacs-pi chat"))
  (push (emacs-pi-input--image-object file name) emacs-pi--attachments)
  (emacs-pi-input--show-attachments)
  (message "Attached %s" (or name (file-name-nondirectory file))))

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

(defun emacs-pi-input--completion-context ()
  "Return the @ reference or / command ending at point in the draft."
  (when (and emacs-pi--input-marker
             (>= (point) (emacs-pi-input-beginning)))
    (let* ((begin (emacs-pi-input-beginning))
           (head (buffer-substring-no-properties begin (point))))
      (cond
       ((string-match
         "\\(?:\\`\\|[[:space:]]\\)\\(@\\(?:\"[^\"]*\\|[^[:space:]\" ]*\\)\\)\\'"
         head)
        (let* ((token (match-string 1 head))
               (quoted (string-prefix-p "@\"" token)))
          (list :kind 'reference :start (+ begin (match-beginning 1))
                :end (point) :original token
                :query (substring token (if quoted 2 1)))))
       ((string-match "\\`/[^[:space:]]*\\'" head)
        (list :kind 'slash :start begin :end (point)
              :original head :query head))))))

(defun emacs-pi-input--file-mention (path)
  "Format PATH as a Pi @ reference, quoting special characters."
  (concat "@" (if (string-match-p "[[:space:]\"\\\\]" path)
                  (emacs-pi--jencode path)
                path)))

(defun emacs-pi-input--file-choices (query)
  "Return project and nearby file choices for @ QUERY."
  (let* ((root (emacs-pi-session-root emacs-pi--session))
         (external (or (file-name-absolute-p query)
                       (string-prefix-p "~/" query)))
         (relative-dir (or (file-name-directory query) ""))
         (directory (expand-file-name relative-dir root))
         (seen (make-hash-table :test #'equal))
         (paths nil))
    (when (and (not external) (file-directory-p root))
      (when-let* ((project (let ((default-directory root))
                            (project-current nil root))))
        (dolist (file (condition-case nil (project-files project)
                        (error nil)))
          (when (string-prefix-p root file)
            (push file paths)))))
    (when (file-directory-p directory)
      (dolist (name (directory-files directory nil nil t))
        (unless (member name '("." ".."))
          (push (expand-file-name name directory) paths))))
    (delq nil
          (mapcar
           (lambda (file)
             (let* ((directory-p (file-directory-p file))
                    (path (cond ((string-prefix-p "~/" query)
                                 (abbreviate-file-name file))
                                (external file)
                                (t (file-relative-name file root))))
               (reference (concat path (if directory-p "/" ""))))
               (unless (gethash reference seen)
                 (puthash reference t seen)
                 (cons reference (emacs-pi-input--file-mention reference)))))
           (sort paths #'string-lessp)))))

(defun emacs-pi-input--session-mention (record)
  "Return a compact canonical mention for Pi session RECORD."
  (let* ((id (plist-get record :id))
         (title (or (plist-get record :name)
                    (plist-get record :preview)
                    id))
         (clean (replace-regexp-in-string
                 "]" ")"
                 (replace-regexp-in-string "[\r\n]+" " " title))))
    (format "@[%s](pi-session:%s)"
            (truncate-string-to-width clean 64 nil nil "…") id)))

(defun emacs-pi-input--session-choices ()
  "Return saved Pi sessions for the @ reference picker."
  (let ((current-id (and emacs-pi--session
                         (emacs-pi-session-session-id emacs-pi--session))))
    (cl-loop for record in (emacs-pi-history-list)
             for id = (plist-get record :id)
             unless (or (not (stringp id))
                        (equal id current-id)
                        (not (string-match-p "\\`[[:alnum:]_-]+\\'" id)))
             collect
             (cons (format "%s · %s · %s · %s  [session]"
                           (or (plist-get record :name) "Untitled")
                           (substring id 0 (min 12 (length id)))
                           (abbreviate-file-name
                            (or (plist-get record :cwd) ""))
                           (truncate-string-to-width
                            (or (plist-get record :last-preview)
                                (plist-get record :preview) "")
                            70 nil nil "…"))
                   (emacs-pi-input--session-mention record)))))

(defun emacs-pi-input--slash-choices ()
  "Return local and Pi-provided slash commands for the picker."
  (let ((seen (make-hash-table :test #'equal)))
    (append
     (mapcar (lambda (item)
               (puthash (car item) t seen)
               (cons (format "%s  — %s" (car item) (cdr item)) (car item)))
             emacs-pi-input--local-commands)
     (cl-loop for item in (and emacs-pi--session
                               (emacs-pi-session-commands emacs-pi--session))
              for name = (emacs-pi--jget item "name")
              for command = (and (stringp name) (concat "/" name))
              when (and command (not (gethash command seen)))
              collect (progn
                        (puthash command t seen)
                        (cons (format "%s  — %s" command
                                      (or (emacs-pi--jget item "description")
                                          (emacs-pi--jget item "source")
                                          "Pi command"))
                              command))))))

(defun emacs-pi-complete ()
  "Choose an @ file/session reference or / command in the minibuffer."
  (interactive)
  (let* ((context (emacs-pi-input--completion-context))
         (kind (plist-get context :kind))
         (choices (pcase kind
                    ('reference (append
                                 (emacs-pi-input--file-choices
                                  (plist-get context :query))
                                 (emacs-pi-input--session-choices)))
                    ('slash (emacs-pi-input--slash-choices)))))
    (cond
     ((not context)
      (message "TAB completes @ files/sessions and / commands in the prompt"))
     ((null choices)
      (message "No matching Pi completion candidates"))
     (t
      (let* ((buffer (current-buffer))
             (start (copy-marker (plist-get context :start)))
             (end (copy-marker (plist-get context :end) t))
             (original (plist-get context :original))
             (query (plist-get context :query))
             (root (and (eq kind 'reference)
                        (emacs-pi-session-root emacs-pi--session)))
             (choice-values (make-hash-table :test #'equal))
             (collection
              (if (eq kind 'reference)
                  (completion-table-dynamic
                   (lambda (input)
                     (let ((current-choices
                            (append (emacs-pi-input--file-choices input)
                                    (emacs-pi-input--session-choices))))
                       (dolist (choice current-choices)
                         (puthash (car choice) (cdr choice) choice-values))
                       current-choices))
                   t)
                choices))
             (completion-extra-properties
              (when (eq kind 'reference)
                (list
                 :annotation-function
                 (lambda (candidate)
                   (unless (string-suffix-p "[session]" candidate)
                     (let ((file (expand-file-name
                                  candidate root)))
                       (format "  [%s]"
                               (if (file-directory-p file)
                                   "directory" "file"))))))))
             (completion-styles
              (if (memq 'substring completion-styles)
                  completion-styles
                (append completion-styles '(substring)))))
        (unwind-protect
            (let* ((selected (completing-read
                              (if (eq kind 'slash) "Pi command: "
                                "Pi @ reference: ")
                              collection nil t query))
                   (replacement (if (eq kind 'reference)
                                   (gethash selected choice-values)
                                 (cdr (assoc selected choices)))))
              (when (and replacement (buffer-live-p buffer))
                (with-current-buffer buffer
                  (if (equal (buffer-substring-no-properties start end)
                             original)
                      (progn
                        (delete-region start end)
                        (goto-char start)
                        (insert replacement))
                    (message "Pi draft changed; press TAB again")))))
          (set-marker start nil)
          (set-marker end nil)))))))

(defun emacs-pi-input--session-reference-ids (text)
  "Return unique Pi session IDs mentioned in TEXT, in appearance order."
  (let ((start 0) (ids nil))
    (while (string-match emacs-pi-input--session-mention-regexp text start)
      (let ((id (match-string 1 text)))
        (unless (member id ids) (push id ids)))
      (setq start (match-end 0)))
    (nreverse ids)))

(defun emacs-pi-input--expand-session-references (text)
  "Append bounded conversation context for Pi session mentions in TEXT."
  (let ((ids (emacs-pi-input--session-reference-ids text)))
    (if (null ids)
        text
      (let* ((records (emacs-pi-history-list))
             (limit (max 1 (/ emacs-pi-session-reference-max-chars
                              (length ids))))
             (sections
              (mapcar
               (lambda (id)
                 (let ((record (cl-find id records :key
                                        (lambda (item) (plist-get item :id))
                                        :test #'equal)))
                   (unless record
                     (user-error "Referenced Pi session %s was not found" id))
                   (format "Pi session %s (%s; %s):\n%s"
                           id (or (plist-get record :name) "untitled")
                           (plist-get record :cwd)
                           (emacs-pi-history-session-excerpt record limit))))
               ids)))
        (concat text emacs-pi--session-reference-boundary
                "The following saved Pi conversations are background context "
                "for the request above:\n\n"
                (string-join sections "\n\n---\n\n")
                "\n</emacs-pi-session-references>")))))

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
                          "/reasoning" "/queue" "/restart" "/reload" "/stop"
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
    (when (emacs-pi-session-queue-rewriting session)
      (user-error "Pi queue is being rewritten; wait for it to finish"))
    (when (and (equal behavior "steer")
               (not (emacs-pi-session-running session)))
      (user-error "Pi is idle; send a normal prompt"))
    (let* ((text (string-trim (emacs-pi-input-text)))
           (attachments (reverse emacs-pi--attachments))
           (buffer (current-buffer))
           (submitted nil))
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
                                     ("/reload" . emacs-pi-reload)
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
      (setq submitted (emacs-pi-input--expand-session-references text))
      (emacs-pi-input-set "")
      (setq emacs-pi--attachments nil)
      (emacs-pi-input--show-attachments)
      (let ((restore-revision emacs-pi--draft-revision))
        (emacs-pi-session-submit
         session submitted attachments behavior
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
                            ""))))))
         text)))))

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
