;;; emacs-pi-rpc.el --- Pi JSONL subprocess transport -*- lexical-binding: t; -*-

;;; Commentary:
;; Asynchronous, per-chat JSONL transport.  No user interface code lives here.

;;; Code:

(require 'cl-lib)
(require 'emacs-pi-core)

(cl-defstruct emacs-pi-rpc
  id generation process stderr-buffer receive-buffer pending counter
  on-event on-exit status close-timer)

(cl-defstruct emacs-pi-rpc-pending command callback timer)

(defvar emacs-pi-rpc-default-timeout 30)
(defvar emacs-pi-rpc-max-record-bytes (* 64 1024 1024))
(defvar emacs-pi-rpc-max-backlog-bytes (* 128 1024 1024))

(defun emacs-pi-rpc--deliver (callback &rest arguments)
  "Call CALLBACK with ARGUMENTS without breaking the process filter."
  (condition-case err
      (apply callback arguments)
    (error (message "emacs-pi RPC callback error: %s" (error-message-string err)))))

(defun emacs-pi-rpc--settle (connection id result)
  "Settle request ID on CONNECTION once with RESULT."
  (when-let* ((pending (gethash id (emacs-pi-rpc-pending connection))))
    (remhash id (emacs-pi-rpc-pending connection))
    (when (emacs-pi-rpc-pending-timer pending)
      (cancel-timer (emacs-pi-rpc-pending-timer pending)))
    (when (emacs-pi-rpc-pending-callback pending)
      (emacs-pi-rpc--deliver (emacs-pi-rpc-pending-callback pending) result))))

(defun emacs-pi-rpc--finish (connection kind message expected)
  "Finish CONNECTION with KIND and MESSAGE; EXPECTED means deliberate close."
  (unless (eq (emacs-pi-rpc-status connection) 'dead)
    (setf (emacs-pi-rpc-status connection) 'dead)
    (when-let* ((timer (emacs-pi-rpc-close-timer connection)))
      (cancel-timer timer))
    (let (ids)
      (maphash (lambda (id _entry) (push id ids)) (emacs-pi-rpc-pending connection))
      (dolist (id ids)
        (emacs-pi-rpc--settle connection id
                              (list :ok nil :kind 'process-exit
                                    :message message :uncertain-p t))))
    ;; A protocol error can reach here from inside the receive buffer's
    ;; process filter.  Defer deletion until the filter has unwound.
    (let ((receive (emacs-pi-rpc-receive-buffer connection)))
      (run-at-time 0 nil
                   (lambda ()
                     (when (buffer-live-p receive) (kill-buffer receive)))))
    (when (emacs-pi-rpc-on-exit connection)
      (emacs-pi-rpc--deliver
       (emacs-pi-rpc-on-exit connection)
       connection
       (list :kind kind :message message :expected-p expected)))))

(defun emacs-pi-rpc--handle-line (connection line)
  "Dispatch complete JSON LINE for CONNECTION."
  (condition-case err
      (let* ((record (emacs-pi--jparse line))
             (type (emacs-pi--jget record "type")))
        (cond
         ((equal type "response")
          (let* ((id (emacs-pi--jget record "id"))
                 (pending (and (stringp id)
                               (gethash id (emacs-pi-rpc-pending connection)))))
            (when pending
              (emacs-pi-rpc--settle
               connection id
               (if (not (equal (emacs-pi--jget record "command")
                               (emacs-pi-rpc-pending-command pending)))
                   (list :ok nil :kind 'protocol :message "Response command mismatch")
                 (if (emacs-pi--jtrue-p (emacs-pi--jget record "success"))
                     (list :ok t :data (emacs-pi--jget record "data") :raw record)
                   (list :ok nil :kind 'rpc
                         :message (or (emacs-pi--jget record "error") "Pi rejected request")
                         :raw record)))))))
         (t (when (emacs-pi-rpc-on-event connection)
              (emacs-pi-rpc--deliver
               (emacs-pi-rpc-on-event connection) connection record)))))
    (error
     (emacs-pi-rpc--finish connection 'protocol (error-message-string err) nil)
     (when (process-live-p (emacs-pi-rpc-process connection))
       (delete-process (emacs-pi-rpc-process connection))))))

(defun emacs-pi-rpc--filter (connection chunk)
  "Append CHUNK and process complete LF records for CONNECTION."
  (when (not (eq (emacs-pi-rpc-status connection) 'dead))
    (with-current-buffer (emacs-pi-rpc-receive-buffer connection)
      (goto-char (point-max))
      (insert chunk)
      (if (> (buffer-size) emacs-pi-rpc-max-backlog-bytes)
          (progn
            (emacs-pi-rpc--finish connection 'protocol "Pi output backlog exceeded limit" nil)
            (when (process-live-p (emacs-pi-rpc-process connection))
              (delete-process (emacs-pi-rpc-process connection))))
        (goto-char (point-min))
        (while (and (not (eq (emacs-pi-rpc-status connection) 'dead))
                    (search-forward "\n" nil t))
          (let* ((end (1- (point)))
                 (length (- end (point-min)))
                 (line (buffer-substring-no-properties (point-min) end)))
            (delete-region (point-min) (point))
            (goto-char (point-min))
            (if (> (string-bytes line) emacs-pi-rpc-max-record-bytes)
                (progn
                  (emacs-pi-rpc--finish connection 'protocol "Pi record exceeded limit" nil)
                  (when (process-live-p (emacs-pi-rpc-process connection))
                    (delete-process (emacs-pi-rpc-process connection))))
              (when (> length 0)
                (emacs-pi-rpc--handle-line
                 connection (string-remove-suffix "\r" line))))))
        (when (> (buffer-size) emacs-pi-rpc-max-record-bytes)
          (emacs-pi-rpc--finish connection 'protocol "Pi record exceeded limit" nil)
          (when (process-live-p (emacs-pi-rpc-process connection))
            (delete-process (emacs-pi-rpc-process connection))))))))

(cl-defun emacs-pi-rpc-start (id generation root argv on-event on-exit
                                &optional environment)
  "Start Pi in ROOT using ARGV and return a connection for ID.
GENERATION invalidates callbacks from older processes.  ENVIRONMENT
is an optional complete process environment list."
  (let* ((connection
          (make-emacs-pi-rpc :id id :generation generation
                             :stderr-buffer (generate-new-buffer " *emacs-pi-stderr*")
                             :receive-buffer (generate-new-buffer " *emacs-pi-receive*")
                             :pending (make-hash-table :test #'equal)
                             :counter 0 :status 'starting
                             :on-event on-event :on-exit on-exit))
         (default-directory root)
         (process-environment (or environment process-environment)))
    (condition-case err
        (setf (emacs-pi-rpc-process connection)
              (make-process
               :name (format "emacs-pi-%s" (substring id 0 (min 8 (length id))))
               :command argv :connection-type 'pipe :coding 'utf-8-unix
               :noquery t :stderr (emacs-pi-rpc-stderr-buffer connection)
               :filter (lambda (_process chunk)
                         (emacs-pi-rpc--filter connection chunk))
               :sentinel (lambda (_process event)
                           (emacs-pi-rpc--finish connection 'process-exit
                                                 (string-trim event)
                                                 (eq (emacs-pi-rpc-status connection)
                                                     'closing)))))
      (error
       (emacs-pi-rpc--finish connection 'start (error-message-string err) nil)))
    (when (process-live-p (emacs-pi-rpc-process connection))
      (setf (emacs-pi-rpc-status connection) 'ready))
    connection))

(defun emacs-pi-rpc-request (connection command args callback &optional timeout)
  "Send COMMAND and JSON ARGS to CONNECTION; call CALLBACK once.
Return request ID or nil when no live process exists."
  (if (not (process-live-p (emacs-pi-rpc-process connection)))
      (progn (when callback
               (emacs-pi-rpc--deliver callback
                                       '(:ok nil :kind send :message "Pi process is not running")))
             nil)
    (let* ((id (format "%s:%d:%d" (emacs-pi-rpc-id connection)
                       (emacs-pi-rpc-generation connection)
                       (cl-incf (emacs-pi-rpc-counter connection))))
           (object (emacs-pi--jobject "id" id "type" command))
           (pending (make-emacs-pi-rpc-pending :command command :callback callback)))
      (when (hash-table-p args)
        (maphash (lambda (key value) (puthash key value object)) args))
      (puthash id pending (emacs-pi-rpc-pending connection))
      (setf (emacs-pi-rpc-pending-timer pending)
            (run-at-time (or timeout emacs-pi-rpc-default-timeout) nil
                         (lambda ()
                           (emacs-pi-rpc--settle
                            connection id
                            '(:ok nil :kind timeout :message "Pi response timed out"
                                  :uncertain-p t)))))
      (condition-case err
          (process-send-string (emacs-pi-rpc-process connection)
                               (concat (emacs-pi--jencode object) "\n"))
        (error (emacs-pi-rpc--settle
                connection id (list :ok nil :kind 'send
                                    :message (error-message-string err)))))
      id)))

(defun emacs-pi-rpc-reply (connection object)
  "Send extension UI response OBJECT through CONNECTION."
  (when (process-live-p (emacs-pi-rpc-process connection))
    (process-send-string (emacs-pi-rpc-process connection)
                         (concat (emacs-pi--jencode object) "\n"))))

(defun emacs-pi-rpc-close (connection)
  "Close CONNECTION, settling outstanding requests."
  (unless (memq (emacs-pi-rpc-status connection) '(dead closing))
    (setf (emacs-pi-rpc-status connection) 'closing)
    (if (process-live-p (emacs-pi-rpc-process connection))
        (progn
          (condition-case nil
              (process-send-eof (emacs-pi-rpc-process connection))
            (error (delete-process (emacs-pi-rpc-process connection))))
          (setf (emacs-pi-rpc-close-timer connection)
                (run-at-time 3 nil
                             (lambda ()
                               (when (process-live-p (emacs-pi-rpc-process connection))
                                 (delete-process (emacs-pi-rpc-process connection)))))))
      (emacs-pi-rpc--finish connection 'closed "Closed" t))))

(provide 'emacs-pi-rpc)
;;; emacs-pi-rpc.el ends here
