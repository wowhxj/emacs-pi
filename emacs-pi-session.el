;;; emacs-pi-session.el --- Pi chat state and RPC orchestration -*- lexical-binding: t; -*-

;;; Commentary:
;; Each session owns its Pi process; the project directory is not an identity.

;;; Code:

(require 'cl-lib)
(require 'emacs-pi-core)
(require 'emacs-pi-rpc)
(require 'emacs-pi-history)

(cl-defstruct emacs-pi-session
  client-id generation root buffer connection session-id session-file name
  phase running compacting waiting model thinking messages active-message
  tools active-tool context-usage steering follow-up queue-known last-prompt error
  commands executable arguments environment on-change on-extension)

(defun emacs-pi-session--changed (session kind &optional data)
  "Notify SESSION observer of KIND and DATA."
  (when (emacs-pi-session-on-change session)
    (condition-case err
        (funcall (emacs-pi-session-on-change session) session
                 (list :kind kind :data data))
      (error (message "emacs-pi UI error: %s" (error-message-string err))))))

(defun emacs-pi-session--messages-from-entries (response)
  "Return active branch messages from get_entries RESPONSE."
  (let* ((branch (emacs-pi-history-active-branch
                  (emacs-pi--jget response "entries")
                  (emacs-pi--jget response "leafId"))))
    (when (plist-get branch :ok)
      (delq nil (mapcar (lambda (entry)
                          (when (equal (emacs-pi--jget entry "type") "message")
                            (emacs-pi--jget entry "message")))
                        (plist-get branch :entries))))))

(defun emacs-pi-session--tools-from-messages (messages)
  "Build completed tool states from persisted MESSAGES."
  (let ((tools (make-hash-table :test #'equal)))
    (dolist (message messages)
      (when (equal (emacs-pi--jget message "role") "toolResult")
        (when-let* ((id (emacs-pi--jget message "toolCallId")))
          (puthash id
                   (emacs-pi--jobject
                    "type" "tool_execution_end"
                    "isError" (emacs-pi--jget message "isError")
                    "result" (emacs-pi--jobject
                              "content" (emacs-pi--jget message "content")))
                   tools))))
    tools))

(defun emacs-pi-session--refresh-history (session &optional callback)
  "Reload active branch for SESSION, then call CALLBACK."
  (let ((generation (emacs-pi-session-generation session)))
    (emacs-pi-rpc-request
     (emacs-pi-session-connection session) "get_entries" nil
     (lambda (result)
       (when (= generation (emacs-pi-session-generation session))
         (when (plist-get result :ok)
           (let ((messages (emacs-pi-session--messages-from-entries
                            (plist-get result :data))))
             (when (listp messages)
               (setf (emacs-pi-session-messages session) messages
                     (emacs-pi-session-tools session)
                     (emacs-pi-session--tools-from-messages messages))
               (emacs-pi-session--changed session 'history))))
         (when callback (funcall callback result)))))))

(defun emacs-pi-session-refresh-stats (session)
  "Refresh SESSION's current context usage from Pi."
  (let ((generation (emacs-pi-session-generation session)))
    (emacs-pi-rpc-request
     (emacs-pi-session-connection session) "get_session_stats" nil
     (lambda (result)
       (when (and (= generation (emacs-pi-session-generation session))
                  (plist-get result :ok))
         (setf (emacs-pi-session-context-usage session)
               (emacs-pi--jget (plist-get result :data) "contextUsage"))
         (emacs-pi-session--changed session 'status))))))

(defun emacs-pi-session--start (session)
  "Start or restart the Pi process for SESSION."
  (let* ((generation (emacs-pi-session-generation session))
         (args (append (list (emacs-pi-session-executable session) "--mode" "rpc")
                       (when (emacs-pi-session-session-file session)
                         (list "--session" (emacs-pi-session-session-file session)))
                       (emacs-pi-session-arguments session)))
         (conn (emacs-pi-rpc-start
                (emacs-pi-session-client-id session) generation
                (emacs-pi-session-root session) args
                (lambda (_connection event)
                  (when (= generation (emacs-pi-session-generation session))
                    (emacs-pi-session-handle-event session event)))
                (lambda (_connection reason)
                  (when (= generation (emacs-pi-session-generation session))
                    (setf (emacs-pi-session-phase session) 'dead
                          (emacs-pi-session-running session) nil
                          (emacs-pi-session-error session) (plist-get reason :message))
                    (emacs-pi-session--changed session 'status)))
                (emacs-pi-session-environment session))))
    (setf (emacs-pi-session-connection session) conn
          (emacs-pi-session-phase session) 'syncing)
    (emacs-pi-session--changed session 'status)
    (emacs-pi-rpc-request
     conn "get_state" nil
     (lambda (result)
       (when (= generation (emacs-pi-session-generation session))
         (if (not (plist-get result :ok))
             (progn
               (setf (emacs-pi-session-phase session) 'dead
                     (emacs-pi-session-error session) (plist-get result :message))
               (emacs-pi-session--changed session 'status))
           (let ((state (plist-get result :data)))
             (setf (emacs-pi-session-session-id session)
                   (emacs-pi--jget state "sessionId")
                   (emacs-pi-session-session-file session)
                   (or (emacs-pi-session-session-file session)
                       (emacs-pi--jget state "sessionFile"))
                   (emacs-pi-session-name session)
                   (emacs-pi--jget state "sessionName")
                   (emacs-pi-session-model session)
                   (emacs-pi--jget state "model")
                   (emacs-pi-session-thinking session)
                   (emacs-pi--jget state "thinkingLevel")
                   (emacs-pi-session-running session)
                   (emacs-pi--jtrue-p (emacs-pi--jget state "isStreaming")))
             (emacs-pi-session--refresh-history
              session
              (lambda (history-result)
                (if (plist-get history-result :ok)
                    (progn
                      (setf (emacs-pi-session-phase session) 'ready)
                      (emacs-pi-session-refresh-stats session)
                      (emacs-pi-rpc-request
                       conn "get_commands" nil
                       (lambda (commands-result)
                         (when (and (= generation (emacs-pi-session-generation session))
                                    (plist-get commands-result :ok))
                           (setf (emacs-pi-session-commands session)
                                 (emacs-pi--array-list
                                  (emacs-pi--jget (plist-get commands-result :data)
                                                  "commands")))))))
                  (setf (emacs-pi-session-phase session) 'dead
                        (emacs-pi-session-error session)
                        (plist-get history-result :message)))
                (emacs-pi-session--changed session 'status)))))))
     30)))

(cl-defun emacs-pi-session-create (root executable &optional arguments environment
                                       session-file on-change on-extension)
  "Create Pi chat at ROOT using EXECUTABLE and start asynchronously."
  (let ((session
         (make-emacs-pi-session
          :client-id (emacs-pi--uuid) :generation 1
          :root (emacs-pi--local-root root) :phase 'starting
          :messages nil :tools (make-hash-table :test #'equal)
          :executable executable :arguments arguments
          :environment environment :session-file session-file
          :on-change on-change :on-extension on-extension)))
    (run-at-time 0 nil (lambda () (when (eq (emacs-pi-session-phase session) 'starting)
                                  (emacs-pi-session--start session))))
    session))

(defun emacs-pi-session-handle-event (session event)
  "Apply Pi EVENT to SESSION and inform its observer."
  (let ((type (emacs-pi--jget event "type")))
    (pcase type
      ("agent_start" (setf (emacs-pi-session-running session) t)
       (emacs-pi-session--changed session 'status))
      ("agent_settled"
       (setf (emacs-pi-session-running session) nil
             (emacs-pi-session-compacting session) nil
             (emacs-pi-session-active-tool session) nil)
       (emacs-pi-session--changed session 'status)
       (emacs-pi-session--refresh-history session)
       (emacs-pi-session-refresh-stats session))
      ("message_start"
       (when (equal (emacs-pi--jget (emacs-pi--jget event "message") "role")
                    "assistant")
         (setf (emacs-pi-session-active-message session) "")
         (emacs-pi-session--changed session 'stream)))
      ("message_update"
       (let ((part (emacs-pi--jget event "assistantMessageEvent")))
         (when (equal (emacs-pi--jget part "type") "text_delta")
           (setf (emacs-pi-session-active-message session)
                 (concat (or (emacs-pi-session-active-message session) "")
                         (or (emacs-pi--jget part "delta") "")))
           (emacs-pi-session--changed session 'stream))))
      ("message_end"
       (let ((message (emacs-pi--jget event "message")))
         (when (member (emacs-pi--jget message "role") '("user" "assistant" "toolResult"))
           (setf (emacs-pi-session-messages session)
                 (append (emacs-pi-session-messages session) (list message)))
           (when (equal (emacs-pi--jget message "role") "assistant")
             (setf (emacs-pi-session-active-message session) nil))
           (emacs-pi-session--changed session 'message))))
      ("tool_execution_start"
       (let ((id (emacs-pi--jget event "toolCallId")))
         (when id (puthash id event (emacs-pi-session-tools session))
               (setf (emacs-pi-session-active-tool session)
                     (emacs-pi--jget event "toolName"))
               (emacs-pi-session--changed session 'tool))))
      ("tool_execution_end"
       (let ((id (emacs-pi--jget event "toolCallId")))
         (when id (puthash id event (emacs-pi-session-tools session))
               (setf (emacs-pi-session-active-tool session) nil)
               (emacs-pi-session--changed session 'tool))))
      ("queue_update"
       (setf (emacs-pi-session-steering session) (emacs-pi--jget event "steering")
             (emacs-pi-session-follow-up session) (emacs-pi--jget event "followUp")
             (emacs-pi-session-queue-known session) t)
       (emacs-pi-session--changed session 'status))
      ("compaction_start"
       (setf (emacs-pi-session-compacting session) t)
       (emacs-pi-session--changed session 'status))
      ("compaction_end"
       (setf (emacs-pi-session-compacting session) nil)
       (emacs-pi-session--changed session 'status)
       (emacs-pi-session-refresh-stats session))
      ("thinking_level_changed"
       (setf (emacs-pi-session-thinking session) (emacs-pi--jget event "level"))
       (emacs-pi-session--changed session 'status))
      ("session_info_changed"
       (setf (emacs-pi-session-name session) (emacs-pi--jget event "name"))
       (emacs-pi-session--changed session 'status))
      ("extension_ui_request"
       (when (emacs-pi-session-on-extension session)
         (funcall (emacs-pi-session-on-extension session) session event)))
      (_ nil))))

(defun emacs-pi-session-submit (session text &optional images behavior callback)
  "Send TEXT and IMAGES to SESSION with BEHAVIOR; call CALLBACK."
  (unless (eq (emacs-pi-session-phase session) 'ready)
    (user-error "Pi chat is not ready"))
  (let ((args (emacs-pi--jobject "message" text)))
    (when images
      (puthash "images"
               (vconcat
                (mapcar (lambda (image)
                          (emacs-pi--jobject
                           "type" "image"
                           "mimeType" (emacs-pi--jget image "mimeType")
                           "data" (emacs-pi--jget image "data")))
                        images))
               args))
    (when (or behavior (emacs-pi-session-running session))
      (puthash "streamingBehavior" (or behavior "followUp") args))
    (setf (emacs-pi-session-last-prompt session) text)
    (emacs-pi-session--changed session 'status)
    (emacs-pi-rpc-request (emacs-pi-session-connection session)
                          "prompt" args (or callback #'ignore) 30)))

(defun emacs-pi-session-stop (session clear-queue callback)
  "Abort SESSION, clearing queued work when CLEAR-QUEUE is non-nil."
  (if clear-queue
      (emacs-pi-rpc-request
       (emacs-pi-session-connection session) "clear_queue" nil
       (lambda (result)
         (if (plist-get result :ok)
             (emacs-pi-rpc-request (emacs-pi-session-connection session)
                                   "abort" nil
                                   (lambda (abort-result)
                                     (funcall callback
                                              (plist-put abort-result :cleared
                                                         (plist-get result :data))))
                                   120)
           (funcall callback result))))
    (emacs-pi-rpc-request (emacs-pi-session-connection session)
                          "abort" nil callback 120)))

(defun emacs-pi-session-restart (session)
  "Restart SESSION against its persisted Pi session, without resending."
  (cl-incf (emacs-pi-session-generation session))
  (when-let* ((old (emacs-pi-session-connection session)))
    (emacs-pi-rpc-close old))
  (setf (emacs-pi-session-phase session) 'starting
        (emacs-pi-session-running session) nil
        (emacs-pi-session-active-message session) nil
        (emacs-pi-session-error session) nil)
  (emacs-pi-session--start session))

(defun emacs-pi-session-shutdown (session)
  "Stop SESSION's Pi process."
  (when-let* ((connection (emacs-pi-session-connection session)))
    (emacs-pi-rpc-close connection))
  (setf (emacs-pi-session-phase session) 'dead
        (emacs-pi-session-running session) nil)
  (emacs-pi-session--changed session 'status))

(provide 'emacs-pi-session)
;;; emacs-pi-session.el ends here
