;;; emacs-pi-core.el --- Data helpers for emacs-pi -*- lexical-binding: t; -*-

;;; Commentary:
;; Small, dependency-free data definitions shared by the Pi client.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defun emacs-pi--jget (object key &optional default)
  "Read KEY from JSON OBJECT, returning DEFAULT when absent."
  (if (hash-table-p object) (gethash key object default) default))

(defun emacs-pi--jobject (&rest pairs)
  "Build a string-key JSON object from PAIRS."
  (unless (zerop (% (length pairs) 2)) (error "Odd JSON key-value list"))
  (let ((object (make-hash-table :test #'equal)))
    (while pairs
      (let ((key (pop pairs)) (value (pop pairs)))
        (unless (stringp key) (error "JSON key must be a string"))
        (puthash key value object)))
    object))

(defun emacs-pi--jparse (line)
  "Parse one JSON LINE, preserving false and null."
  (json-parse-string line :object-type 'hash-table :array-type 'array
                     :false-object :false :null-object :null))

(defun emacs-pi--jencode (object)
  "Encode OBJECT as JSON, preserving false and null."
  (json-serialize object :false-object :false :null-object :null))

(defun emacs-pi--jtrue-p (value)
  "Return non-nil exactly when JSON VALUE is true."
  (eq value t))

(defun emacs-pi--array-list (value)
  "Return JSON array VALUE as a list, or nil."
  (if (vectorp value) (append value nil) nil))

(defun emacs-pi--content-text (content)
  "Extract readable text from Pi CONTENT."
  (cond ((stringp content) content)
        ((vectorp content)
         (string-join
          (delq nil (mapcar (lambda (block)
                             (when (equal (emacs-pi--jget block "type") "text")
                               (emacs-pi--jget block "text")))
                           (append content nil))) "\n"))
        (t "")))

(defun emacs-pi--message-text (message)
  "Return human-readable text from Pi MESSAGE."
  (emacs-pi--content-text (emacs-pi--jget message "content")))

(defun emacs-pi--uuid ()
  "Create a client-local identity."
  (if (fboundp 'uuidgen-4)
      (uuidgen-4)
    (md5 (format "%s:%s:%s" (current-time) (random) (emacs-pid)))))

(defun emacs-pi--local-root (root)
  "Return canonical local ROOT with a trailing separator."
  (when (file-remote-p root) (user-error "emacs-pi does not support remote directories"))
  (unless (file-directory-p root) (user-error "Not a directory: %s" root))
  (file-name-as-directory (file-truename (expand-file-name root))))

(provide 'emacs-pi-core)
;;; emacs-pi-core.el ends here
