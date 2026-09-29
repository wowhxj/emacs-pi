;;; emacs-pi-queue.el --- Editable Pi queue view -*- lexical-binding: t; -*-

;;; Commentary:
;; Stage queue edits locally and apply them through clear_queue plus ordered
;; steer/follow_up requests.  Pi RPC does not expose individual queue items.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-pi-core)
(require 'emacs-pi-session)
(require 'emacs-pi-input)

(defvar emacs-pi--recovery)

(cl-defstruct emacs-pi-queue-item id lane text images known)

(defvar-local emacs-pi--queue-session nil)
(defvar-local emacs-pi-queue--base nil)
(defvar-local emacs-pi-queue--steering nil)
(defvar-local emacs-pi-queue--follow-up nil)
(defvar-local emacs-pi-queue--next-id 0)
(defvar-local emacs-pi-queue--dirty nil)
(defvar-local emacs-pi-queue--busy nil)
(defvar-local emacs-pi-queue--notice nil)

(defvar-local emacs-pi-queue-edit--parent nil)
(defvar-local emacs-pi-queue-edit--item-object nil)
(defvar-local emacs-pi-queue-edit--images nil)
(defvar-local emacs-pi-queue-edit--preview nil)

(defvar emacs-pi-queue-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'emacs-pi-queue-edit)
    (define-key map (kbd "M-<up>") #'emacs-pi-queue-move-up)
    (define-key map (kbd "M-<down>") #'emacs-pi-queue-move-down)
    (define-key map (kbd "s") #'emacs-pi-queue-move-to-steering)
    (define-key map (kbd "f") #'emacs-pi-queue-move-to-follow-up)
    (define-key map (kbd "d") #'emacs-pi-queue-delete)
    (define-key map (kbd "g") #'emacs-pi-queue-refresh)
    (define-key map (kbd "C-c C-c") #'emacs-pi-queue-apply)
    (define-key map (kbd "q") #'emacs-pi-queue-quit)
    map)
  "Keys for the Pi queue list.")

(define-derived-mode emacs-pi-queue-mode special-mode "Pi-Queue"
  "Major mode for staging changes to Pi's queued messages.")

(defvar emacs-pi-queue-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'emacs-pi-queue-edit-save)
    (define-key map (kbd "C-c C-k") #'emacs-pi-queue-edit-cancel)
    (define-key map (kbd "C-c C-a") #'emacs-pi-queue-edit-add-image)
    (define-key map (kbd "C-c C-p") #'emacs-pi-queue-edit-paste-image)
    (define-key map (kbd "C-c C-d") #'emacs-pi-queue-edit-remove-image)
    (define-key map (kbd "C-c C-r") #'emacs-pi-queue-edit-replace-image)
    map)
  "Keys for editing one queued message.")

(define-derived-mode emacs-pi-queue-edit-mode text-mode "Pi-Queue-Edit"
  "Major mode for editing queued text and images."
  (setq-local header-line-format
              "C-c C-c save · C-c C-k cancel · C-c C-a add image · C-c C-p paste · C-c C-d remove · C-c C-r replace"))

(defun emacs-pi-queue--snapshot (session)
  "Return SESSION's steering and follow-up text lists."
  (cons (emacs-pi--array-list (emacs-pi-session-steering session))
        (emacs-pi--array-list (emacs-pi-session-follow-up session))))

(defun emacs-pi-queue--all-items ()
  "Return all staged queue items in lane order."
  (append emacs-pi-queue--steering emacs-pi-queue--follow-up))

(defun emacs-pi-queue--desired-snapshot ()
  "Return text lists represented by the staged queue."
  (cons (mapcar #'emacs-pi-queue-item-text emacs-pi-queue--steering)
        (mapcar #'emacs-pi-queue-item-text emacs-pi-queue--follow-up)))

(defun emacs-pi-queue--make-items (session snapshot)
  "Build editable items from SESSION and SNAPSHOT."
  (let ((attachments (emacs-pi-session-queue-attachments session))
        (all (append (car snapshot) (cdr snapshot)))
        (result nil))
    (dolist (lane '((steering . car) (follow-up . cdr)))
      (dolist (text (funcall (cdr lane) snapshot))
        (let* ((image-value (and attachments (gethash text attachments)))
               (duplicate (> (cl-count text all :test #'equal) 1))
               (known (and image-value
                           (not (eq image-value :ambiguous))
                           (or (not duplicate) (eq image-value :text-only)))))
          (push (make-emacs-pi-queue-item
                 :id (cl-incf emacs-pi-queue--next-id)
                 :lane (car lane) :text text
                 :images (and (listp image-value) image-value)
                 :known known)
                result))))
    (nreverse result)))

(defun emacs-pi-queue--load (session)
  "Replace staged data with SESSION's latest queue."
  (setq emacs-pi-queue--base (emacs-pi-queue--snapshot session)
        emacs-pi-queue--next-id 0
        emacs-pi-queue--dirty nil
        emacs-pi-queue--notice nil)
  (let ((items (emacs-pi-queue--make-items session emacs-pi-queue--base)))
    (setq emacs-pi-queue--steering
          (cl-remove-if-not (lambda (item)
                              (eq (emacs-pi-queue-item-lane item) 'steering))
                            items)
          emacs-pi-queue--follow-up
          (cl-remove-if-not (lambda (item)
                              (eq (emacs-pi-queue-item-lane item) 'follow-up))
                            items))))

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

(defun emacs-pi-queue--item-at-point ()
  "Return the staged queue item at point."
  (let ((id (get-text-property (point) 'emacs-pi-queue-id)))
    (or (cl-find id (emacs-pi-queue--all-items)
                 :key #'emacs-pi-queue-item-id)
        (user-error "Move point to a queued message"))))

(defun emacs-pi-queue--render-item (item index)
  "Insert queue ITEM at INDEX with its image previews."
  (let ((start (point)))
    (insert (format "  %d. %s\n" index
                    (replace-regexp-in-string
                     "[\r\n]+" " ↵ " (emacs-pi-queue-item-text item))))
    (if (not (emacs-pi-queue-item-known item))
        (insert (propertize "     [attachments unknown; cannot apply edits]\n"
                            'face 'warning))
      (dolist (image (emacs-pi-queue-item-images item))
        (insert "     "
                (or (emacs-pi--queue-image-preview image) "[image]")
                " " (or (emacs-pi--jget image "name") "image") "\n")))
    (add-text-properties start (point)
                         (list 'emacs-pi-queue-id (emacs-pi-queue-item-id item)
                               'mouse-face 'highlight))))

(defun emacs-pi--queue-render (session)
  "Render SESSION's queue and any staged edits."
  (when (and (not emacs-pi-queue--dirty)
             (not emacs-pi-queue--busy)
             (not (equal emacs-pi-queue--base
                         (emacs-pi-queue--snapshot session))))
    (emacs-pi-queue--load session))
  (let ((inhibit-read-only t)
        (selected (get-text-property (point) 'emacs-pi-queue-id)))
    (erase-buffer)
    (insert (propertize "Pi queue" 'face 'bold)
            (cond (emacs-pi-queue--busy " · applying…\n")
                  (emacs-pi-queue--dirty " · modified locally\n")
                  (t "\n"))
            "RET edit · M-↑/↓ reorder · s/f change lane · d remove\n"
            "C-c C-c apply · g discard local edits/refresh · q discard and close\n\n")
    (when emacs-pi-queue--notice
      (insert (propertize (concat emacs-pi-queue--notice "\n\n")
                          'face 'warning)))
    (cond
     ((not (emacs-pi-session-queue-known session))
      (insert "Queue details have not arrived yet.\n"))
     (t
      (when (and emacs-pi-queue--dirty
                 (not (equal emacs-pi-queue--base
                             (emacs-pi-queue--snapshot session))))
        (insert (propertize
                 "Pi's queue changed while you edited. Refresh before applying.\n\n"
                 'face 'warning)))
      (dolist (group `(("Steering" . ,emacs-pi-queue--steering)
                       ("Follow-up" . ,emacs-pi-queue--follow-up)))
        (insert (format "%s (%d):\n" (car group) (length (cdr group))))
        (if (cdr group)
            (cl-loop for item in (cdr group)
                     for index from 1
                     do (emacs-pi-queue--render-item item index))
          (insert "  (empty)\n"))
        (insert "\n"))))
    (insert (propertize
             "Apply clears and resends the queue. Pi may consume messages while running.\n"
             'face 'shadow))
    (goto-char (point-min))
    (when selected
      (let ((found (text-property-search-forward 'emacs-pi-queue-id selected t)))
        (when found (goto-char (prop-match-beginning found)))))))

(defun emacs-pi-show-queue ()
  "Show an editable staging view of Pi's steering and follow-up queue."
  (interactive)
  (let* ((session (or (and (derived-mode-p 'emacs-pi-queue-mode)
                           emacs-pi--queue-session)
                      (and (derived-mode-p 'emacs-pi-chat-mode)
                           emacs-pi--session)
                      (user-error "Not in an emacs-pi chat")))
         (buffer (get-buffer-create
                  (format "*pi-queue:%s*"
                          (substring (emacs-pi-session-client-id session) 0 6)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'emacs-pi-queue-mode)
        (emacs-pi-queue-mode)
        (setq-local emacs-pi--queue-session session)
        (setq-local revert-buffer-function
                    (lambda (&rest _) (emacs-pi-queue-refresh))))
      (emacs-pi--queue-render session))
    (pop-to-buffer buffer)))

(defun emacs-pi-queue-quit ()
  "Discard staged edits and close the queue list and its item editors."
  (interactive)
  (when (or emacs-pi-queue--busy
            (and emacs-pi--queue-session
                 (emacs-pi-session-queue-rewriting emacs-pi--queue-session)))
    (user-error "Queue rewrite is in progress; wait for it to finish"))
  (let ((parent (current-buffer)))
    (dolist (buffer (buffer-list))
      (when (with-current-buffer buffer
              (and (derived-mode-p 'emacs-pi-queue-edit-mode)
                   (eq emacs-pi-queue-edit--parent parent)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))
    (if-let* ((window (get-buffer-window parent t)))
        (quit-window t window)
      (kill-buffer parent))
    (when (buffer-live-p parent) (kill-buffer parent))))

(defun emacs-pi-queue-refresh ()
  "Discard staged changes and reload Pi's current queue."
  (interactive)
  (when emacs-pi-queue--busy
    (user-error "Queue rewrite is still in progress"))
  (when (and emacs-pi-queue--dirty
             (not (y-or-n-p "Discard staged queue changes? ")))
    (user-error "Queue refresh cancelled"))
  (emacs-pi-queue--load emacs-pi--queue-session)
  (emacs-pi--queue-render emacs-pi--queue-session))

(defun emacs-pi-queue--ensure-editable ()
  "Reject list edits while a queue rewrite is underway."
  (when emacs-pi-queue--busy
    (user-error "Queue rewrite is still in progress")))

(defun emacs-pi-queue--move (offset)
  "Move the selected item by OFFSET within its lane."
  (emacs-pi-queue--ensure-editable)
  (let* ((item (emacs-pi-queue--item-at-point))
         (lane (emacs-pi-queue-item-lane item))
         (items (if (eq lane 'steering) emacs-pi-queue--steering
                  emacs-pi-queue--follow-up))
         (index (cl-position item items))
         (target (+ index offset)))
    (when (or (< target 0) (>= target (length items)))
      (user-error "Already at the end of this lane"))
    (cl-rotatef (nth index items) (nth target items))
    (setq emacs-pi-queue--dirty t)
    (emacs-pi--queue-render emacs-pi--queue-session)))

(defun emacs-pi-queue-move-up ()
  "Move the selected queued message earlier."
  (interactive)
  (emacs-pi-queue--move -1))

(defun emacs-pi-queue-move-down ()
  "Move the selected queued message later."
  (interactive)
  (emacs-pi-queue--move 1))

(defun emacs-pi-queue--move-to (lane)
  "Move the selected queued message to LANE's end."
  (emacs-pi-queue--ensure-editable)
  (let ((item (emacs-pi-queue--item-at-point)))
    (unless (eq (emacs-pi-queue-item-lane item) lane)
      (setq emacs-pi-queue--steering
            (delq item emacs-pi-queue--steering)
            emacs-pi-queue--follow-up
            (delq item emacs-pi-queue--follow-up))
      (setf (emacs-pi-queue-item-lane item) lane)
      (if (eq lane 'steering)
          (setq emacs-pi-queue--steering
                (append emacs-pi-queue--steering (list item)))
        (setq emacs-pi-queue--follow-up
              (append emacs-pi-queue--follow-up (list item))))
      (setq emacs-pi-queue--dirty t)
      (emacs-pi--queue-render emacs-pi--queue-session))))

(defun emacs-pi-queue-move-to-steering ()
  "Promote the selected queued message to steering."
  (interactive)
  (emacs-pi-queue--move-to 'steering))

(defun emacs-pi-queue-move-to-follow-up ()
  "Move the selected queued message to follow-up."
  (interactive)
  (emacs-pi-queue--move-to 'follow-up))

(defun emacs-pi-queue-delete ()
  "Stage removal of the selected queued message."
  (interactive)
  (emacs-pi-queue--ensure-editable)
  (let ((item (emacs-pi-queue--item-at-point)))
    (setq emacs-pi-queue--steering (delq item emacs-pi-queue--steering)
          emacs-pi-queue--follow-up (delq item emacs-pi-queue--follow-up)
          emacs-pi-queue--dirty t)
    (emacs-pi--queue-render emacs-pi--queue-session)))

(defun emacs-pi-queue-edit--show-images ()
  "Show the editor's pending image attachments after its text."
  (when (derived-mode-p 'emacs-pi-queue-edit-mode)
    (unless (overlayp emacs-pi-queue-edit--preview)
      (setq emacs-pi-queue-edit--preview
            (make-overlay (point-max) (point-max) nil nil t)))
    (move-overlay emacs-pi-queue-edit--preview (point-max) (point-max))
    (overlay-put
     emacs-pi-queue-edit--preview 'after-string
     (when emacs-pi-queue-edit--images
       (concat
        "\n\nAttachments:\n"
        (mapconcat
         (lambda (image)
           (concat "  " (or (emacs-pi--queue-image-preview image) "[image]")
                   " " (or (emacs-pi--jget image "name") "image")))
         emacs-pi-queue-edit--images "\n")
        "\n")))))

(defun emacs-pi-queue-edit ()
  "Edit the selected queued message and its images in a separate buffer."
  (interactive)
  (emacs-pi-queue--ensure-editable)
  (let* ((item (emacs-pi-queue--item-at-point))
         (parent (current-buffer))
         (name (format "*pi-queue-edit:%s:%s*"
                       (substring (emacs-pi-session-client-id
                                   emacs-pi--queue-session) 0 6)
                       (emacs-pi-queue-item-id item)))
         (buffer (get-buffer-create name)))
    (unless (emacs-pi-queue-item-known item)
      (user-error "Cannot edit: Pi did not provide this item's image data"))
    (unless (with-current-buffer buffer
              (and (derived-mode-p 'emacs-pi-queue-edit-mode)
                   (eq emacs-pi-queue-edit--item-object item)))
      (with-current-buffer buffer
        (emacs-pi-queue-edit-mode)
        (setq-local emacs-pi-queue-edit--parent parent)
        (setq-local emacs-pi-queue-edit--item-object item)
        (setq-local emacs-pi-queue-edit--images
                    (copy-sequence (emacs-pi-queue-item-images item)))
        (insert (emacs-pi-queue-item-text item))
        (set-buffer-modified-p nil)
        (add-hook
         'after-change-functions
         (lambda (&rest _)
           (when (overlayp emacs-pi-queue-edit--preview)
             (move-overlay emacs-pi-queue-edit--preview
                           (point-max) (point-max))))
         nil t)
        (emacs-pi-queue-edit--show-images)))
    (pop-to-buffer buffer)))

(defun emacs-pi-queue-edit--item ()
  "Return the item associated with this queue editor."
  (unless (buffer-live-p emacs-pi-queue-edit--parent)
    (user-error "The queue view has closed"))
  (let ((item emacs-pi-queue-edit--item-object))
    (with-current-buffer emacs-pi-queue-edit--parent
      (if (memq item (emacs-pi-queue--all-items))
          item
        (user-error "This queued message no longer exists")))))

(defun emacs-pi-queue-edit-save ()
  "Save this message's staged text and image changes."
  (interactive)
  (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
         (item (emacs-pi-queue-edit--item))
         (images emacs-pi-queue-edit--images)
         (parent emacs-pi-queue-edit--parent))
    (when (string-empty-p (string-trim text))
      (user-error "Queued message cannot be empty; delete it in the queue view"))
    (with-current-buffer parent
      (emacs-pi-queue--ensure-editable)
      (setf (emacs-pi-queue-item-text item) text
            (emacs-pi-queue-item-images item) images)
      (setq emacs-pi-queue--dirty t)
      (emacs-pi--queue-render emacs-pi--queue-session))
    (set-buffer-modified-p nil)
    (quit-window t)
    (when (buffer-live-p parent) (pop-to-buffer parent))))

(defun emacs-pi-queue-edit-cancel ()
  "Discard edits to this queued message."
  (interactive)
  (set-buffer-modified-p nil)
  (quit-window t))

(defun emacs-pi-queue-edit-add-image (file)
  "Attach PNG or JPEG FILE to this queued message."
  (interactive "fImage file: ")
  (setq emacs-pi-queue-edit--images
        (append emacs-pi-queue-edit--images
                (list (emacs-pi-input--image-object file))))
  (emacs-pi-queue-edit--show-images))

(defun emacs-pi-queue-edit-paste-image ()
  "Attach a PNG image from the macOS clipboard."
  (interactive)
  (let ((program (emacs-pi-input--pngpaste-program)))
    (unless program (user-error "Install pngpaste to paste clipboard images"))
    (let ((file (make-temp-file "emacs-pi-queue-image-" nil ".png")))
      (unwind-protect
          (progn
            (unless (and (zerop (call-process program nil nil nil file))
                         (> (file-attribute-size (file-attributes file)) 0))
              (user-error "Clipboard does not contain a PNG image"))
            (setq emacs-pi-queue-edit--images
                  (append emacs-pi-queue-edit--images
                          (list (emacs-pi-input--image-object
                                 file "clipboard.png"))))
            (emacs-pi-queue-edit--show-images))
        (when (file-exists-p file) (delete-file file))))))

(defun emacs-pi-queue-edit--choose-image ()
  "Return the index of an image selected from this editor."
  (unless emacs-pi-queue-edit--images
    (user-error "This message has no attached images"))
  (let ((choices (cl-loop for image in emacs-pi-queue-edit--images
                          for index from 0
                          collect (cons (format "%d. %s" (1+ index)
                                                (or (emacs-pi--jget image "name")
                                                    "image"))
                                        index))))
    (cdr (assoc (completing-read "Image: " choices nil t)
                choices))))

(defun emacs-pi-queue-edit-remove-image ()
  "Remove one image from this queued message."
  (interactive)
  (let ((index (emacs-pi-queue-edit--choose-image)))
    (setq emacs-pi-queue-edit--images
          (cl-loop for image in emacs-pi-queue-edit--images
                   for current from 0
                   unless (= current index) collect image))
    (emacs-pi-queue-edit--show-images)))

(defun emacs-pi-queue-edit-replace-image (file)
  "Replace a selected image with PNG or JPEG FILE."
  (interactive "fReplacement image: ")
  (let ((index (emacs-pi-queue-edit--choose-image)))
    (setf (nth index emacs-pi-queue-edit--images)
          (emacs-pi-input--image-object file))
    (emacs-pi-queue-edit--show-images)))

(defun emacs-pi-queue--cache-items (session items)
  "Record known image data for queued ITEMS in SESSION."
  (let ((attachments (or (emacs-pi-session-queue-attachments session)
                         (setf (emacs-pi-session-queue-attachments session)
                               (make-hash-table :test #'equal)))))
    (clrhash attachments)
    (dolist (item items)
      (let* ((text (emacs-pi-queue-item-text item))
             (images (emacs-pi-queue-item-images item))
             (previous (gethash text attachments)))
        (puthash text
                 (cond ((eq previous :ambiguous) :ambiguous)
                       ((and previous
                             (or images (not (eq previous :text-only))))
                        :ambiguous)
                       (images images)
                       (t :text-only))
                 attachments)))))

(defun emacs-pi-queue--recovery (session items &optional uncertain)
  "Save unsubmitted ITEMS for SESSION's composer recovery."
  (when-let* ((chat (emacs-pi-session-buffer session)))
    (when (buffer-live-p chat)
      (with-current-buffer chat
        (dolist (item (reverse items))
          (push (list :text (emacs-pi-queue-item-text item)
                      :attachments (emacs-pi-queue-item-images item)
                      :uncertain uncertain)
                emacs-pi--recovery))))))

(defun emacs-pi-queue--unexpected-error (buffer session err)
  "Release SESSION's rewrite guard after unexpected ERR in BUFFER."
  (setf (emacs-pi-session-queue-rewriting session) nil)
  (let ((notice (format "Queue rewrite failed in Emacs: %s. Check Pi's queue before retrying."
                        (error-message-string err))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq emacs-pi-queue--busy nil
              emacs-pi-queue--notice notice)
        (ignore-errors
          (emacs-pi-queue--recovery
           session (emacs-pi-queue--all-items) t)
          (emacs-pi--queue-render session))))
    (message "%s" notice)))

(defun emacs-pi-queue--request-args (item)
  "Return RPC arguments for queued ITEM."
  (let ((args (emacs-pi--jobject "message" (emacs-pi-queue-item-text item))))
    (when-let* ((images (emacs-pi-queue-item-images item)))
      (puthash
       "images"
       (vconcat
        (mapcar (lambda (image)
                  (emacs-pi--jobject
                   "type" "image"
                   "mimeType" (emacs-pi--jget image "mimeType")
                   "data" (emacs-pi--jget image "data")))
                images))
       args))
    args))

(defun emacs-pi-queue--send-sequence (session items callback)
  "Send ITEMS in lane order; call CALLBACK with result, sent and pending."
  (let ((generation (emacs-pi-session-generation session)))
    (cl-labels
        ((send-next (pending sent)
           (if (null pending)
               (funcall callback '(:ok t) (nreverse sent) nil)
             (let ((item (car pending)))
               (condition-case err
                   (emacs-pi-rpc-request
                    (emacs-pi-session-connection session)
                    (if (eq (emacs-pi-queue-item-lane item) 'steering)
                        "steer" "follow_up")
                    (emacs-pi-queue--request-args item)
                    (lambda (result)
                      (if (and (plist-get result :ok)
                               (= generation (emacs-pi-session-generation session)))
                          (send-next (cdr pending) (cons item sent))
                        (funcall callback result (nreverse sent) pending)))
                    30)
                 (error
                  (funcall callback
                           (list :ok nil :message (error-message-string err)
                                 :uncertain-p t)
                           (nreverse sent) pending)))))))
      (send-next items nil))))

(defun emacs-pi-queue--match-cleared (actual original)
  "Return ACTUAL cleared queue as items matched to ORIGINAL image data."
  (let ((available (copy-sequence original))
        (result nil))
    (dolist (lane `((steering . ,(car actual))
                    (follow-up . ,(cdr actual))))
      (dolist (text (cdr lane))
        (let ((match (cl-find-if
                      (lambda (item)
                        (and (eq (emacs-pi-queue-item-lane item) (car lane))
                             (equal (emacs-pi-queue-item-text item) text)))
                      available)))
          (if match
              (progn
                (setq available (delq match available))
                (push match result))
            (push (make-emacs-pi-queue-item
                   :lane (car lane) :text text :known nil)
                  result)))))
    (nreverse result)))

(defun emacs-pi-queue--finish (buffer session result sent pending notice)
  "Finish a rewrite and show RESULT, SENT, PENDING and NOTICE."
  (setf (emacs-pi-session-queue-rewriting session) nil)
  (emacs-pi-queue--cache-items session sent)
  (when pending
    (emacs-pi-queue--recovery session pending
                              (plist-get result :uncertain-p)))
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq emacs-pi-queue--busy nil)
      (emacs-pi-queue--load session)
      (setq emacs-pi-queue--notice notice)
      (emacs-pi--queue-render session)))
  (message "%s" notice))

(defun emacs-pi-queue--apply-cleared (buffer session base original desired result)
  "Rewrite queue after successful clear RESULT, from ORIGINAL to DESIRED."
  (let* ((data (plist-get result :data))
         (actual (cons (emacs-pi--array-list (emacs-pi--jget data "steering"))
                       (emacs-pi--array-list (emacs-pi--jget data "followUp"))))
         (matched (equal actual base))
         (items (if matched desired
                  (emacs-pi-queue--match-cleared actual original))))
    (emacs-pi-queue--send-sequence
     session items
     (lambda (replay-result sent pending)
       (condition-case err
           (emacs-pi-queue--finish
            buffer session replay-result sent pending
            (cond
             ((not (plist-get replay-result :ok))
              (format "Queue rewrite stopped: %s. Unsent items saved for M-x emacs-pi-recover-input."
                      (or (plist-get replay-result :message) "RPC error")))
             ((not matched)
              (if (cl-some (lambda (item)
                             (not (emacs-pi-queue-item-known item)))
                           items)
                  "Queue changed during apply; restored Pi's text, but some image data was unavailable."
                "Queue changed during apply; restored Pi's messages. Refresh and edit again."))
             ((and (not (emacs-pi-session-running session))
                   (let ((remaining (emacs-pi-queue--snapshot session)))
                     (or (car remaining) (cdr remaining))))
              "Queue edits applied. Pi is idle; send a prompt to process pending messages.")
             (t "Queue edits applied.")))
         (error (emacs-pi-queue--unexpected-error buffer session err)))))))

(defun emacs-pi-queue--clear-failed (buffer session original result)
  "Handle failed clear RESULT, preserving staged edits when safe."
  (let* ((uncertain (plist-get result :uncertain-p))
         (notice (format "Queue clear failed: %s%s"
                         (or (plist-get result :message) "RPC error")
                         (if uncertain
                             "; original items saved as uncertain recovery"
                           "; staged edits kept"))))
    (setf (emacs-pi-session-queue-rewriting session) nil)
    (when uncertain
      (emacs-pi-queue--recovery session original t))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq emacs-pi-queue--busy nil)
        (when uncertain (emacs-pi-queue--load session))
        (setq emacs-pi-queue--notice notice)
        (emacs-pi--queue-render session)))
    (message "%s" notice)))

(defun emacs-pi-queue-apply ()
  "Apply staged edits by clearing and rebuilding Pi's queue."
  (interactive)
  (emacs-pi-queue--ensure-editable)
  (unless emacs-pi-queue--dirty
    (user-error "No staged queue changes"))
  (let* ((session emacs-pi--queue-session)
         (base emacs-pi-queue--base)
         (original (emacs-pi-queue--make-items session base))
         (desired (emacs-pi-queue--all-items))
         (buffer (current-buffer)))
    (unless (eq (emacs-pi-session-phase session) 'ready)
      (user-error "Pi chat is not ready"))
    (unless (equal base (emacs-pi-queue--snapshot session))
      (user-error "Pi queue changed; press g to refresh before applying"))
    (when (cl-some (lambda (item) (not (emacs-pi-queue-item-known item)))
                   original)
      (user-error "Cannot rewrite queue: some original image data is unknown"))
    (when (cl-some (lambda (item) (not (emacs-pi-queue-item-known item)))
                   desired)
      (user-error "Cannot rewrite queue: some image data is unknown"))
    (let ((seen (make-hash-table :test #'equal)))
      (dolist (item desired)
        (let* ((text (emacs-pi-queue-item-text item))
               (earlier (gethash text seen)))
          (when (and earlier
                     (or (emacs-pi-queue-item-images earlier)
                         (emacs-pi-queue-item-images item)))
            (user-error "Identical queued text with images cannot be matched safely"))
          (puthash text item seen))))
    (setq emacs-pi-queue--busy t)
    (setf (emacs-pi-session-queue-rewriting session) t)
    (condition-case err
        (progn
          (emacs-pi--queue-render session)
          (emacs-pi-rpc-request
           (emacs-pi-session-connection session) "clear_queue" nil
           (lambda (result)
             (condition-case callback-error
                 (if (plist-get result :ok)
                     (emacs-pi-queue--apply-cleared
                      buffer session base original desired result)
                   (emacs-pi-queue--clear-failed
                    buffer session original result))
               (error (emacs-pi-queue--unexpected-error
                       buffer session callback-error))))
           30))
      (error (emacs-pi-queue--unexpected-error buffer session err)))))

(provide 'emacs-pi-queue)
;;; emacs-pi-queue.el ends here
