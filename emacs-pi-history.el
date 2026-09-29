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

(defun emacs-pi-history--record (path)
  "Read a bounded session preview from PATH, returning a plist or nil."
  (condition-case nil
      (with-temp-buffer
        (let* ((size (file-attribute-size (file-attributes path)))
               (limit (min size (* 4 1024 1024)))
               (full-read-p (= limit size)))
          (insert-file-contents path nil 0 limit)
        (goto-char (point-min))
        (let (id cwd created preview name)
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
                         (when (and (null preview)
                                    (equal (emacs-pi--jget
                                            (emacs-pi--jget entry "message") "role")
                                           "user"))
                           (setq preview (emacs-pi--message-text
                                          (emacs-pi--jget entry "message")))))))
                  (error nil))))
            (forward-line 1))
          (when (and (stringp id) (stringp cwd))
            (list :id id :cwd cwd :path path :created created
                  :name name :preview preview
                  :modified (file-attribute-modification-time
                             (file-attributes path)))))))
    (error nil)))

(defun emacs-pi-history-list (&optional root)
  "List saved sessions, optionally filtered to ROOT.
This is a read-only local index; it never edits Pi's session files."
  (let* ((directory (emacs-pi-history-directory))
         (paths (when (file-directory-p directory)
                  (directory-files-recursively directory "\\.jsonl\\'")))
         (records (delq nil (mapcar #'emacs-pi-history--record paths))))
    (when root
      (setq records
            (seq-filter (lambda (item)
                          (string= (file-name-as-directory
                                    (expand-file-name (plist-get item :cwd)))
                                   (file-name-as-directory (expand-file-name root))))
                        records)))
    (sort records
          (lambda (a b) (time-less-p (plist-get b :modified)
                                     (plist-get a :modified))))))

(provide 'emacs-pi-history)
;;; emacs-pi-history.el ends here
