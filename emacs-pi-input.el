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

(declare-function emacs-pi-ui--image-preview-string "emacs-pi-ui")
(declare-function emacs-pi-ui-view-image "emacs-pi-ui")

;; Optional Orderless setting; path completion binds it locally so matching
;; remains case-insensitive even when the user's global smart-case is enabled.
(defvar orderless-smart-case)

(defvar-local emacs-pi--attachments nil)
(defvar-local emacs-pi--attachment-overlay nil)

(defvar emacs-pi-input--image-remove-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'emacs-pi-input-remove-image)
    map)
  "Mouse map for removing a staged image from its preview.")

(defconst emacs-pi-input--local-commands
  '(("/new" "Start a new session" emacs-pi-new-session)
    ("/resume" "Choose a saved session" emacs-pi-resume)
    ("/model" "Select model" emacs-pi-select-model)
    ("/thinking" "Select thinking level" emacs-pi-select-thinking)
    ("/reasoning" "Select thinking level" emacs-pi-select-thinking)
    ("/name" "Show or set the session name" emacs-pi-set-session-name t t)
    ("/session" "Show session statistics" emacs-pi-show-session-stats nil t)
    ("/compact" "Compact context (optional instructions)" emacs-pi-compact t t)
    ("/fork" "Fork from a previous user message" emacs-pi-fork-session nil t)
    ("/clone" "Clone the current session branch" emacs-pi-clone-session nil t)
    ("/copy" "Copy the last assistant response" emacs-pi-copy-last-response nil t)
    ("/export" "Export this session to HTML" emacs-pi-export-session t t)
    ("/queue" "Show queued prompts" emacs-pi-show-queue)
    ("/restart" "Restart this Pi process" emacs-pi-restart)
    ("/reload" "Restart Pi RPC and reload extensions/resources" emacs-pi-reload)
    ("/stop" "Stop and clear the queue" emacs-pi-stop)
    ("/doctor" "Show connection details" emacs-pi-doctor)
    ("/quit" "Close this Pi chat" emacs-pi-quit)
    ("/help" "Show commands" emacs-pi-help))
  "Client slash commands: NAME, DESCRIPTION, FUNCTION, optional ARGS-P, ASYNC-P.")

(defconst emacs-pi-input--unsupported-cli-commands
  '("/settings" "/scoped-models" "/login" "/logout" "/llama"
    "/tree" "/import" "/share" "/bug" "/trust" "/hotkeys" "/changelog")
  "Pi CLI commands whose full interactive workflows are not exposed over RPC.")

(defconst emacs-pi-input--session-mention-regexp
  "@\\[[^]\n]*\\](pi-session:\\([[:alnum:]_-]+\\))"
  "Pattern for client-side Pi session references.")

(defcustom emacs-pi-reference-providers nil
  "Alist of (NAME . FUNCTION) for external @NAME references.
TAB on @NAME calls FUNCTION with the chat root.  It returns a file path to
insert as an @ reference, or nil to leave the draft unchanged."
  :type '(alist :key-type string :value-type function) :group 'emacs-pi)

(defcustom emacs-pi-pngpaste-executable "pngpaste"
  "Program used to paste a macOS clipboard image as PNG.
Set this to an absolute path if GUI Emacs cannot find Homebrew programs."
  :type 'string :group 'emacs-pi)

(defun emacs-pi-input-beginning ()
  "Return the first editable position in the current Pi chat."
  (unless emacs-pi--input-marker (user-error "Not in an emacs-pi chat"))
  (+ (marker-position emacs-pi--input-marker)
     (length emacs-pi--composer-prefix)))

(defun emacs-pi-input-end ()
  "Return the end of the Pi draft, before its read-only line ending."
  (max (emacs-pi-input-beginning) (1- (point-max))))

(defun emacs-pi-input-text ()
  "Return the current Pi draft without text properties."
  (buffer-substring-no-properties (emacs-pi-input-beginning)
                                  (emacs-pi-input-end)))

(defun emacs-pi-input-set (text)
  "Replace the current Pi draft with TEXT."
  (let ((begin (emacs-pi-input-beginning)))
    (delete-region begin (emacs-pi-input-end))
    (goto-char (emacs-pi-input-end))
    (insert text)))

(defun emacs-pi-focus-input ()
  "Move point to the last non-whitespace character of the Pi composer."
  (interactive)
  (goto-char (+ (emacs-pi-input-beginning)
                (length (string-trim-right (emacs-pi-input-text))))))

(defun emacs-pi-input--show-attachments ()
  "Show navigable pending image previews above the composer."
  (let ((inhibit-read-only t))
    (when emacs-pi--attachment-overlay
      (delete-region (overlay-start emacs-pi--attachment-overlay)
                     (overlay-end emacs-pi--attachment-overlay))
      (delete-overlay emacs-pi--attachment-overlay)
      (setq emacs-pi--attachment-overlay nil))
    (when emacs-pi--attachments
      (let ((start (marker-position emacs-pi--input-marker)))
        (save-excursion
          (goto-char start)
          (insert "\n")
          (cl-loop for image in (reverse emacs-pi--attachments)
                   for index from 0
                   for preview = (emacs-pi-ui--image-preview-string image)
                   do
                   (add-text-properties
                    0 (length preview)
                    (list 'emacs-pi-attachment-index index
                          'mouse-face 'highlight
                          'help-echo "C-c C-o: open; click × to remove")
                    preview)
                   (insert
                    "  " preview "  "
                    (propertize "×" 'emacs-pi-attachment-index index
                                'keymap emacs-pi-input--image-remove-map
                                'mouse-face 'highlight
                                'help-echo "mouse-1: remove this image")
                    " click to remove\n"))
          (insert "\n")
          (setq emacs-pi--attachment-overlay (make-overlay start (point)))
          (add-text-properties start (point) '(read-only t)))))))

(defun emacs-pi-input--remove-attachment (index)
  "Remove staged attachment at display INDEX, preserving other images."
  (unless (and (integerp index)
               (<= 0 index) (< index (length emacs-pi--attachments)))
    (user-error "No staged image at this position"))
  (setq emacs-pi--attachments
        (nreverse
         (cl-loop for image in (reverse emacs-pi--attachments)
                  for position from 0
                  unless (= position index) collect image)))
  (emacs-pi-input--show-attachments))

(defun emacs-pi-input-remove-image (event)
  "Remove the staged image whose × button was clicked with EVENT."
  (interactive "e")
  (let* ((position (event-start event))
         (buffer-position (posn-point position))
         (window (posn-window position)))
    (unless (window-live-p window)
      (user-error "No Pi chat at this position"))
    (with-current-buffer (window-buffer window)
      (let ((index (or (and (integerp buffer-position)
                            (get-text-property buffer-position
                                               'emacs-pi-attachment-index))
                       (and (integerp buffer-position) (> buffer-position 1)
                            (get-text-property (1- buffer-position)
                                               'emacs-pi-attachment-index)))))
        (emacs-pi-input--remove-attachment index)))))

(defun emacs-pi-input-open-image ()
  "View the image at point or choose a staged composer attachment."
  (interactive)
  (let ((historical (or (get-text-property (point) 'emacs-pi-image)
                        (and (> (point) (point-min))
                             (get-text-property (1- (point)) 'emacs-pi-image)))))
    (cond
     (historical (emacs-pi-ui-view-image historical))
     (emacs-pi--attachments
      (let* ((images (reverse emacs-pi--attachments))
             (choices (cl-loop for image in images for index from 1
                               collect (cons
                                        (format "%d. %s" index
                                                (or (emacs-pi--jget image "name")
                                                    "image"))
                                        image)))
             (selected (if (= (length choices) 1)
                           (cdar choices)
                         (cdr (assoc (completing-read "View image: " choices nil t)
                                     choices)))))
        (emacs-pi-ui-view-image selected)))
     (t (user-error "Move to a history image or attach an image first")))))

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
         "\\(?:\\`\\|[[:space:]]\\)\\(@session\\(?:[[:space:]]+[^[:space:]]*\\)?\\)\\'"
         head)
        (let* ((token (match-string 1 head))
               (start (+ begin (match-beginning 1)))
               (query (if (string-match "\\`@session[[:space:]]+\\(.*\\)\\'" token)
                          (match-string 1 token)
                        "")))
          (list :kind 'session :start start
                :end (point) :original token :query query)))
       ((and (string-match "\\(?:\\`\\|[[:space:]]\\)\\(@\\([[:alnum:]_-]+\\)\\)\\'" head)
             (assoc (match-string 2 head) emacs-pi-reference-providers))
        (list :kind 'provider :start (+ begin (match-beginning 1)) :end (point)
              :original (match-string 1 head)
              :provider (cdr (assoc (match-string 2 head) emacs-pi-reference-providers))))
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

(defun emacs-pi-input--completion-current-input (fallback)
  "Return the active minibuffer input, or FALLBACK if none is active.
Completion styles such as Orderless may ask a dynamic table for a reduced
prefix.  Path candidate generation needs the full minibuffer input to choose
the directory whose contents should be offered."
  (if-let* ((window (active-minibuffer-window))
            ((window-live-p window)))
      (with-current-buffer (window-buffer window)
        (minibuffer-contents-no-properties))
    fallback))

(defun emacs-pi-input--file-mention (path)
  "Format PATH as a Pi @ reference, quoting special characters."
  (concat "@" (if (string-match-p "[[:space:]\"\\\\]" path)
                  (emacs-pi--jencode path)
                path)))

(defun emacs-pi-input--file-choices (query root)
  "Return project and nearby file choices for @ QUERY under ROOT."
  (let* ((external (or (file-name-absolute-p query)
                       (string-prefix-p "~/" query)))
         (relative-dir (or (file-name-directory query) ""))
         (directory (expand-file-name relative-dir root))
         (seen (make-hash-table :test #'equal))
         (paths nil))
    (when (and (not external) (string-empty-p relative-dir)
               (file-directory-p root))
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
  "Return saved Pi sessions for the @session picker."
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
               (puthash (nth 0 item) t seen)
               (cons (format "%s  — %s" (nth 0 item) (nth 1 item))
                     (nth 0 item)))
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
  "Choose an @ path, @session reference, or / command in the minibuffer."
  (interactive)
  (let* ((context (emacs-pi-input--completion-context))
         (kind (plist-get context :kind))
         (root (and (eq kind 'reference)
                    (emacs-pi-session-root emacs-pi--session)))
         (query (plist-get context :query))
         (choices (pcase kind
                    ('reference (emacs-pi-input--file-choices query root))
                    ('session (emacs-pi-input--session-choices))
                    ('slash (emacs-pi-input--slash-choices)))))
    (cond
     ((not context)
      (message "TAB completes @ paths, @session references, and / commands"))
     ((eq kind 'provider)
      ;; Markers survive transcript output inserted while the provider prompts.
      (let ((start (copy-marker (plist-get context :start)))
            (end (copy-marker (plist-get context :end) t)))
        (unwind-protect
            (when-let* ((path (funcall (plist-get context :provider)
                                       (emacs-pi-session-root emacs-pi--session))))
              (if (equal (buffer-substring-no-properties start end)
                         (plist-get context :original))
                  (progn
                    (delete-region start end)
                    (goto-char start)
                    (insert (emacs-pi-input--file-mention path)))
                (message "Pi draft changed; press TAB again")))
          (set-marker start nil)
          (set-marker end nil))))
     ((null choices)
      (message "No matching Pi completion candidates"))
     (t
      (let* ((buffer (current-buffer))
             (start (copy-marker (plist-get context :start)))
             (end (copy-marker (plist-get context :end) t))
             (original (plist-get context :original))
             (choice-values (make-hash-table :test #'equal))
             (collection
              (if (eq kind 'reference)
                  (completion-table-with-metadata
                   (completion-table-dynamic
                    (lambda (input)
                      (let* ((path-input
                              (emacs-pi-input--completion-current-input input))
                             (current-choices
                              (emacs-pi-input--file-choices path-input root)))
                        ;; Keep the directory itself as an exact candidate.
                        ;; Completion frontends revalidate the selected value
                        ;; after the input changes from "dir" to "dir/".
                        (when (and (string-suffix-p "/" path-input)
                                   (file-directory-p
                                    (expand-file-name path-input root)))
                          (push (cons path-input
                                      (emacs-pi-input--file-mention path-input))
                                current-choices))
                        (dolist (choice current-choices)
                          (puthash (car choice) (cdr choice) choice-values))
                        current-choices))
                    t)
                   '((category . emacs-pi-file)))
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
                (append completion-styles '(substring))))
             (completion-category-overrides
              (cons `(emacs-pi-file (styles . ,completion-styles))
                    (assq-delete-all 'emacs-pi-file
                                     completion-category-overrides)))
             (completion-ignore-case t)
             (read-file-name-completion-ignore-case t)
             (orderless-smart-case nil))
        (unwind-protect
            (let* ((selected (completing-read
                              (pcase kind
                                ('slash "Pi command: ")
                                ('session "Pi session reference: ")
                                (_ "Pi @ path: "))
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
         ((and (string-match-p "\\`/[^[:space:]]*\\'"
                               (emacs-pi-input-text))
               (<= end (emacs-pi-input-end)))
          (list (emacs-pi-input-beginning) end
                (mapcar #'cdr (emacs-pi-input--slash-choices))
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
    (when (emacs-pi-session-compacting session)
      (user-error "Pi context is being compacted; wait for it to finish"))
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
               (local-command
                (or (assoc text emacs-pi-input--local-commands)
                    (let ((by-name (assoc name emacs-pi-input--local-commands)))
                      (and (nth 3 by-name) by-name))))
               (command (nth 2 local-command))
               (instructions
                (when (and local-command (nth 3 local-command))
                  (let ((argument (string-trim
                                   (substring text (length name)))))
                    (unless (string-empty-p argument) argument))))
               (server-command
                (seq-some (lambda (item)
                            (equal (concat "/" (emacs-pi--jget item "name")) name))
                          (emacs-pi-session-commands session))))
          (cond
           (command
            (when attachments
              (user-error "Remove or send attached images before a /command"))
            (if (or (nth 3 local-command) (nth 4 local-command))
                (funcall command instructions t)
              (funcall command)
              (when (buffer-live-p buffer)
                (with-current-buffer buffer (emacs-pi-input-set ""))))
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
    (goto-char (emacs-pi-input-end))
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
