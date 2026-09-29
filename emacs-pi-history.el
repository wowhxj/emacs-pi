;;; emacs-pi-history.el --- Persisted Pi session discovery -*- lexical-binding: t; -*-

;;; Commentary:
;; Read-only index and active-branch reconstruction for Pi JSONL sessions.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'emacs-pi-core)

(defcustom emacs-pi-session-directory nil
  "Override Pi's session storage directory.
When nil, use Pi's environment or default agent directory."
  :type '(choice (const nil) directory) :group 'emacs-pi)

(defcustom emacs-pi-session-reference-max-chars 32000
  "Approximate total dialogue characters added for @session references."
  :type 'integer :group 'emacs-pi)

(defvar emacs-pi-history--cache (make-hash-table :test #'equal)
  "Session previews keyed by path and file size/mtime.")

(defun emacs-pi-history-directory ()
  "Return the directory to scan for Pi session JSONL files."
  (expand-file-name
   (or emacs-pi-session-directory
       (getenv "PI_CODING_AGENT_SESSION_DIR")
       (expand-file-name "sessions" (or (getenv "PI_CODING_AGENT_DIR")
                                          "~/.pi/agent")))))

(defun emacs-pi-history-active-branch (entries leaf-id)
  "Return (:ok t :entries LIST) for ENTRIES along LEAF-ID ancestry."
  (let ((table (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal))
        (cursor leaf-id)
        (branch nil)
        (error-kind nil))
    (dolist (entry (emacs-pi--array-list entries))
      (let ((id (emacs-pi--jget entry "id")))
        (when (stringp id) (puthash id entry table))))
    (while (and (stringp cursor) (not error-kind))
      (cond
       ((gethash cursor seen) (setq error-kind 'cycle))
       ((not (gethash cursor table)) (setq error-kind 'missing-parent))
       (t (puthash cursor t seen)
          (let ((entry (gethash cursor table)))
            (push entry branch)
            (setq cursor (emacs-pi--jget entry "parentId"))))))
    (if error-kind
        (list :ok nil :kind error-kind :id cursor)
      (list :ok t :entries branch))))

(defun emacs-pi-history--record (path &optional attributes)
  "Read a bounded session preview from PATH, returning a plist or nil."
  (condition-case nil
      (with-temp-buffer
        (let* ((attributes (or attributes (file-attributes path)))
               (size (file-attribute-size attributes))
               (limit (min size (* 4 1024 1024)))
               (full-read-p (= limit size)))
          (insert-file-contents path nil 0 limit)
        (goto-char (point-min))
        (let (id cwd created preview last-preview name (message-count 0))
          (while (not (eobp))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              (when (and (not (string-empty-p line))
                         (or (< (line-end-position) (point-max)) full-read-p))
                (condition-case nil
                    (let ((entry (emacs-pi--jparse line)))
                      (pcase (emacs-pi--jget entry "type")
                        ("session" (setq id (emacs-pi--jget entry "id")
                                         cwd (emacs-pi--jget entry "cwd")
                                         created (emacs-pi--jget entry "timestamp")))
                        ("session_info" (setq name (emacs-pi--jget entry "name")))
                        ("message"
                         (cl-incf message-count)
                         (when (equal (emacs-pi--jget
                                       (emacs-pi--jget entry "message") "role")
                                      "user")
                           (let ((text (emacs-pi--message-text
                                        (emacs-pi--jget entry "message"))))
                             (when (and text (not (string-empty-p text)))
                               (unless preview (setq preview text))
                               (setq last-preview text)))))))
                  (error nil))))
            (forward-line 1))
          (when (and (stringp id) (stringp cwd))
            (list :id id :cwd cwd :path path :created created
                  :name name :preview preview :last-preview last-preview
                  :message-count (and full-read-p message-count)
                  :modified (file-attribute-modification-time attributes))))))
    (error nil)))

(defun emacs-pi-history--cached-record (path)
  "Return PATH's preview, reparsing only when its file metadata changes."
  (let* ((attributes (file-attributes path))
         (key (and attributes
                   (list (file-attribute-size attributes)
                         (file-attribute-modification-time attributes))))
         (cached (gethash path emacs-pi-history--cache)))
    (if (and key (equal key (car cached)))
        (cdr cached)
      (let ((record (and key (emacs-pi-history--record path attributes))))
        (puthash path (cons key record) emacs-pi-history--cache)
        record))))

(defun emacs-pi-history-list (&optional root)
  "List saved sessions, optionally filtered to ROOT.
This is a read-only local index; it never edits Pi's session files."
  (let* ((directory (emacs-pi-history-directory))
         (paths (when (file-directory-p directory)
                  (directory-files-recursively directory "\\.jsonl\\'")))
         (records (delq nil (mapcar #'emacs-pi-history--cached-record paths))))
    (when root
      (setq records
            (seq-filter (lambda (item)
                          (and (file-directory-p (plist-get item :cwd))
                               (file-equal-p (plist-get item :cwd) root)))
                        records)))
    (sort records
          (lambda (a b) (time-less-p (plist-get b :modified)
                                     (plist-get a :modified))))))

(defun emacs-pi-history-session-excerpt (record max-chars)
  "Return the latest active-branch dialogue in RECORD, up to MAX-CHARS.
Only user and assistant text and Pi's own summaries are included."
  (let* ((max-chars (max 1 max-chars))
         (path (plist-get record :path))
         (size (and path (file-attributes path))))
    (unless size (user-error "Referenced Pi session is no longer available"))
    (when (> (file-attribute-size size) (* 64 1024 1024))
      (user-error "Referenced Pi session exceeds the 64 MiB reading limit"))
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (let (entries leaf)
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-empty-p line)
              (condition-case nil
                  (let* ((entry (emacs-pi--jparse line))
                         (kind (emacs-pi--jget entry "type"))
                         (id (emacs-pi--jget entry "id"))
                         (message (emacs-pi--jget entry "message"))
                         (role (emacs-pi--jget message "role"))
                         (text (pcase kind
                                 ("message"
                                  (when (member role '("user" "assistant"))
                                    (emacs-pi--message-text message)))
                                 ((or "compaction" "branch_summary")
                                  (emacs-pi--jget entry "summary")))))
                    (when (and (stringp id) (not (equal kind "session")))
                      (setq leaf id)
                      (push (emacs-pi--jobject
                             "id" id "parentId" (emacs-pi--jget entry "parentId")
                             "text" (when (and (stringp text)
                                               (not (string-empty-p text)))
                                      (if (> (length text) max-chars)
                                          (substring text (- (length text) max-chars))
                                        text))
                             "role" (cond ((equal kind "compaction") "Summary")
                                          ((equal kind "branch_summary")
                                           "Branch summary")
                                          ((equal role "user") "User")
                                          ((equal role "assistant") "Pi")))
                            entries)))
                (error nil))))
          (forward-line 1))
        (let* ((branch (emacs-pi-history-active-branch
                        (vconcat (nreverse entries)) leaf))
               (lines (when (plist-get branch :ok)
                        (delq nil
                              (mapcar (lambda (entry)
                                        (when-let* ((text (emacs-pi--jget
                                                           entry "text")))
                                          (format "%s: %s"
                                                  (emacs-pi--jget entry "role")
                                                  text)))
                                      (plist-get branch :entries)))))
               (dialogue (string-join lines "\n\n")))
          (unless (and lines (not (string-empty-p dialogue)))
            (user-error "Referenced Pi session has no readable dialogue"))
          (if (> (length dialogue) max-chars)
              (concat "[Earlier dialogue omitted]\n"
                      (substring dialogue (- (length dialogue) max-chars)))
            dialogue))))))

(provide 'emacs-pi-history)
;;; emacs-pi-history.el ends here
