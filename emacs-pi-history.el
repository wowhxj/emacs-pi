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

(defcustom emacs-pi-history-request-timeout 180
  "Seconds to wait for Pi to return session history over RPC."
  :type 'number :group 'emacs-pi)

(defvar emacs-pi-history--cache (make-hash-table :test #'equal)
  "Session records keyed by canonical path and filesystem identity/metadata.")

(defun emacs-pi-history-directory ()
  "Return the directory to scan for Pi session JSONL files."
  (expand-file-name
   (or emacs-pi-session-directory
       (getenv "PI_CODING_AGENT_SESSION_DIR")
       (expand-file-name "sessions" (or (getenv "PI_CODING_AGENT_DIR")
                                          "~/.pi/agent")))))

(defun emacs-pi-history-active-branch (entries leaf-id &optional allow-truncated)
  "Return active branch in ENTRIES from LEAF-ID.
When ALLOW-TRUNCATED is non-nil, a missing parent at the beginning is
accepted as the root of a partial history."
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
       ((not (gethash cursor table))
        (if allow-truncated
            (setq cursor nil)
          (setq error-kind 'missing-parent)))
       (t (puthash cursor t seen)
          (let ((entry (gethash cursor table)))
            (push entry branch)
            (setq cursor (emacs-pi--jget entry "parentId"))))))
    (if error-kind
        (list :ok nil :kind error-kind :id cursor)
      (list :ok t :entries branch))))

(defun emacs-pi-history-entry-after-byte-window (path max-bytes)
  "Return an entry ID to pass as `get_entries' since for PATH.
If PATH exceeds MAX-BYTES, return an ID near the start of its recent
MAX-BYTES suffix.  A 1 MiB margin is reserved for the RPC envelope and
JSON serialization overhead."
  (let* ((size (file-attribute-size (file-attributes path)))
         (window (max 1 (- max-bytes (* 1024 1024)))))
    (when (> size max-bytes)
      (with-temp-buffer
        (insert-file-contents path)
        (let* ((end-byte (or (position-bytes (point-max)) 1))
               (offset (max 1 (- end-byte window)))
               (position (or (byte-to-position offset) (point-min))))
          (goto-char position)
          (unless (bolp) (forward-line 1))
          (let (id done)
            (while (and (not done) (not (eobp)))
              (let ((entry (condition-case nil
                               (emacs-pi--jparse
                                (buffer-substring-no-properties
                                 (line-beginning-position) (line-end-position)))
                             (error nil))))
                (setq id (and entry
                              (not (equal (emacs-pi--jget entry "type") "session"))
                              (emacs-pi--jget entry "id"))
                      done (stringp id)))
              (unless done (forward-line 1)))
            id))))))

(defun emacs-pi-history--consume (record line)
  "Accumulate one JSON LINE into mutable plist RECORD."
  (condition-case nil
      (let* ((entry (emacs-pi--jparse line))
             (message (emacs-pi--jget entry "message"))
             (role (emacs-pi--jget message "role")))
        (pcase (emacs-pi--jget entry "type")
          ("session"
           (setf (plist-get record :id) (emacs-pi--jget entry "id")
                 (plist-get record :cwd) (emacs-pi--jget entry "cwd")
                 (plist-get record :created) (emacs-pi--jget entry "timestamp")))
          ("session_info"
           (setf (plist-get record :name) (emacs-pi--jget entry "name")))
          ("message"
           (cl-incf (plist-get record :message-count))
           (when (equal role "user")
             (let ((text (emacs-pi--message-text message)))
               (unless (plist-get record :has-user)
                 (setf (plist-get record :preview)
                       (if (string-empty-p text) "[Non-text user message]" text)))
               (setf (plist-get record :has-user) t)
               (unless (string-empty-p text)
                 (setf (plist-get record :last-preview) text))))
           (when (member role '("user" "assistant"))
             (let* ((stamp (emacs-pi--jget message "timestamp"))
                    (seconds (if (numberp stamp) (/ stamp 1000.0)
                               (let ((entry-time (emacs-pi--jget entry "timestamp")))
                                 (unless (stringp entry-time)
                                   (error "Missing message timestamp"))
                                 (float-time (date-to-time entry-time))))))
               (setf (plist-get record :activity)
                     (max seconds (or (plist-get record :activity) seconds))))))))
    (error (cl-incf (plist-get record :invalid-lines))))
  record)

(defun emacs-pi-history--empty-record (path)
  "Make an accumulator for PATH."
  (list :path path :id nil :cwd nil :created nil :preview nil
        :last-preview nil :name nil :message-count 0 :has-user nil
        :activity nil :invalid-lines 0))

(defun emacs-pi-history--finish-record (record)
  "Finish accumulated RECORD without guessing unknown states."
  (let ((activity (plist-get record :activity)))
    (setf (plist-get record :modified) (and activity (seconds-to-time activity))
          (plist-get record :time-source) (and activity 'message)
          (plist-get record :empty)
          (if (plist-get record :has-user) nil
            (if (> (plist-get record :invalid-lines) 0) 'unknown t))
          (plist-get record :internal) 'unknown
          (plist-get record :archived) 'unknown))
  record)

(defun emacs-pi-history--record (path &optional _attributes)
  "Read a complete session preview from PATH, including diagnostics."
  (let ((record (emacs-pi-history--empty-record path)))
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents path)
          (goto-char (point-min))
          (while (not (eobp))
            (unless (= (line-beginning-position) (line-end-position))
              (emacs-pi-history--consume
               record (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (forward-line 1)))
      (error (cl-incf (plist-get record :invalid-lines))))
    (when (stringp (plist-get record :id))
      (emacs-pi-history--finish-record record))))

(defun emacs-pi-history--signature (attributes)
  "Return content metadata and identity from file ATTRIBUTES, excluding atime."
  (when attributes
    (list (file-attribute-size attributes)
          (file-attribute-modification-time attributes)
          (file-attribute-status-change-time attributes)
          (file-attribute-inode-number attributes)
          (file-attribute-device-number attributes))))

(defun emacs-pi-history--auxiliary-ledger-p (path)
  "Recognize an observation ledger, not a Pi session, using location and schema."
  (and (equal (file-name-nondirectory path) "ledger.jsonl")
       (equal (file-name-nondirectory (directory-file-name (file-name-directory path)))
              "observation-pack")
       (condition-case nil
           (with-temp-buffer
             (let ((coding-system-for-read 'utf-8-unix))
               (insert-file-contents path nil 0 (min 65536 (file-attribute-size (file-attributes path)))))
             (goto-char (point-min))
             (let ((entry (emacs-pi--jparse (buffer-substring-no-properties (point) (line-end-position)))))
               (and (not (emacs-pi--jget entry "type"))
                    (member (emacs-pi--jget entry "event") '("full" "placeholder"))
                    (emacs-pi--jget entry "id") (emacs-pi--jget entry "tool")
                    (emacs-pi--jget entry "request"))))
         (error nil))))

(defun emacs-pi-history--cached-record (path)
  "Return PATH's preview, reparsing only when its identity or metadata changes."
  (setq path (file-truename path))
  (let* ((attributes (file-attributes path))
         (key (emacs-pi-history--signature attributes))
         (cached (gethash path emacs-pi-history--cache))
         (record (if (and key (equal key (car cached))) (cdr cached)
                   (and key (if (emacs-pi-history--auxiliary-ledger-p path) '(:auxiliary t)
                              (emacs-pi-history--record path attributes))))))
    (when (equal key (emacs-pi-history--signature (file-attributes path)))
      (puthash path (cons key record) emacs-pi-history--cache))
    (unless (plist-get record :auxiliary) record)))

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
          (lambda (a b) (time-less-p (or (plist-get b :modified) '(0 0))
                                     (or (plist-get a :modified) '(0 0)))))))

;;;###autoload
(cl-defun emacs-pi-list-sessions (on-success &key directories on-error)
  "Read sessions cooperatively without starting Pi; return a cancel function.
Unchanged files reuse an in-memory cache; observation ledgers are excluded.
ON-SUCCESS receives a plist with :items and :diagnostics.  Each item has
:source (canonical storage directory), :path, :id, :cwd, :preview,
:modified and :time-source.  Unknown flags use the symbol `unknown'.
ON-ERROR receives a diagnostic string on fatal failure.  Cancellation
silently suppresses callbacks.  Partial failures appear in :diagnostics."
  (let ((pending (mapcar (lambda (dir) (cons (expand-file-name dir) nil))
                         (or directories (list (emacs-pi-history-directory)))))
        (seen (make-hash-table :test #'equal))
        items diagnostics timer cancelled input record source offset size signature)
    (cl-labels
        ((record-diagnostics (value)
           (when (> (plist-get value :invalid-lines) 0)
             (push (list :path (plist-get value :path)
                         :invalid-lines (plist-get value :invalid-lines)
                         :message (format "Invalid session records: %d" (plist-get value :invalid-lines)))
                   diagnostics)))
         (accept-record (value)
           (setf (plist-get value :source) source)
           (push value items)
           (record-diagnostics value))
         (close-input ()
           (when (buffer-live-p input) (kill-buffer input))
           (setq input nil))
         (tick ()
           (unless cancelled
             (condition-case err
                 (let ((budget 1000) (deadline (+ (float-time) 0.01)))
                   (while (and (> budget 0) (< (float-time) deadline)
                               (or input pending))
                     (cl-decf budget)
                     (if input
                         (with-current-buffer input
                           (if (and (< offset size)
                                    (or (eobp)
                                        (not (save-excursion
                                               (search-forward "\n" nil t)))))
                               (let ((start (point))
                                     (end (min size (+ offset 65536))))
                                 (delete-region (point-min) start)
                                 (goto-char (point-max))
                                 (let ((coding-system-for-read 'no-conversion))
                                   (insert-file-contents (plist-get record :path)
                                                         nil offset end))
                                 (setq offset end)
                                 (goto-char (point-min)))
                             (if (eobp)
                               (progn
                                 (if (stringp (plist-get record :id))
                                     (progn
                                       (setq record (emacs-pi-history--finish-record record))
                                       (accept-record record)
                                       (when (equal signature (emacs-pi-history--signature
                                                               (file-attributes (plist-get record :path))))
                                         (puthash (plist-get record :path)
                                                  (cons signature (copy-sequence record)) emacs-pi-history--cache)))
                                   (push (list :path (plist-get record :path)
                                               :message "Missing session header") diagnostics)
                                   (record-diagnostics record))
                                 (close-input))
                             (unless (= (line-beginning-position) (line-end-position))
                               (emacs-pi-history--consume
                                record (decode-coding-string
                                        (buffer-substring-no-properties
                                         (line-beginning-position) (line-end-position))
                                        'utf-8)))
                             (when input (forward-line 1)))))
                       (pcase-let* ((`(,path . ,root) (pop pending)))
                         (condition-case nil
                             (cond
                              ((file-symlink-p path) nil)
                              ((file-directory-p path)
                               (let ((canonical (file-truename path)))
                                 (unless (gethash canonical seen)
                                   (puthash canonical t seen)
                                   (dolist (child (directory-files path t
                                                                 directory-files-no-dot-files-regexp))
                                     (push (cons child (or root canonical)) pending)))))
                              ((string-suffix-p ".jsonl" path)
                               (let* ((canonical (file-truename path))
                                      (attributes (file-attributes canonical))
                                      (key (emacs-pi-history--signature attributes))
                                      (cached (gethash canonical emacs-pi-history--cache))
                                      (hit (and key (equal key (car cached)))))
                                 (unless (gethash canonical seen)
                                   (puthash canonical t seen)
                                   (setq source root)
                                   (cond
                                    ((and hit (plist-get (cdr cached) :auxiliary)) nil)
                                    ((and hit (stringp (plist-get (cdr cached) :id)))
                                     (accept-record (copy-sequence (cdr cached))))
                                    ((emacs-pi-history--auxiliary-ledger-p canonical)
                                     (when (equal key (emacs-pi-history--signature (file-attributes canonical)))
                                       (puthash canonical (cons key '(:auxiliary t)) emacs-pi-history--cache)))
                                    (t
                                     (setq record (emacs-pi-history--empty-record canonical)
                                           signature key offset 0
                                           size (file-attribute-size attributes)
                                           input (generate-new-buffer " *pi-session-scan*"))
                                     (with-current-buffer input (set-buffer-multibyte nil)))))))
                              ((not (file-exists-p path))
                               (push (list :path path :message "Path does not exist") diagnostics)))
                           (error
                            (close-input)
                            (push (list :path path :message "Cannot read session path") diagnostics))))))
                   (if (or input pending)
                       (setq timer (run-at-time 0.01 nil #'tick))
                     (setq cancelled t)
                     (funcall on-success
                              (list :items (nreverse items)
                                    :diagnostics (nreverse diagnostics)))))
               (error
                (setq cancelled t)
                (close-input)
                (if on-error (funcall on-error (error-message-string err))
                  (message "emacs-pi: session scan failed")))))))
      (setq timer (run-at-time 0 nil #'tick))
      (lambda ()
        (setq cancelled t)
        (when timer (cancel-timer timer))
        (close-input)))))

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
