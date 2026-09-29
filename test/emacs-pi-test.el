;;; emacs-pi-test.el --- Integration checks for emacs-pi -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-pi)

(defun emacs-pi-test--wait (predicate)
  "Wait up to five seconds for PREDICATE to become non-nil."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall predicate)))

(ert-deftest emacs-pi-json-distinguishes-false-and-null ()
  (let ((object (emacs-pi--jparse "{\"yes\":true,\"no\":false,\"empty\":null,\"items\":[]}")))
    (should (eq (emacs-pi--jget object "yes") t))
    (should (eq (emacs-pi--jget object "no") :false))
    (should (eq (emacs-pi--jget object "empty") :null))
    (should (equal (emacs-pi--jget object "items") []))
    (should (string-match-p "\"no\":false" (emacs-pi--jencode object)))))

(ert-deftest emacs-pi-malformed-rpc-record-closes-safely ()
  (let* ((receive (generate-new-buffer " *emacs-pi-test-receive*"))
         (connection (make-emacs-pi-rpc
                      :receive-buffer receive
                      :pending (make-hash-table :test #'equal)
                      :status 'ready)))
    (unwind-protect
        (progn
          (emacs-pi-rpc--filter connection "{bad json}\n")
          (should (eq (emacs-pi-rpc-status connection) 'dead)))
      (when (buffer-live-p receive) (kill-buffer receive)))))

(ert-deftest emacs-pi-active-branch-skips-abandoned-entries ()
  (let ((entries (vconcat
                  (mapcar (lambda (spec)
                            (emacs-pi--jobject "id" (nth 0 spec)
                                               "parentId" (or (nth 1 spec) :null)))
                          '(("a" nil) ("b" "a") ("c" "b")
                            ("d" "c") ("e" "b") ("f" "e"))))))
    (should (equal (mapcar (lambda (item) (emacs-pi--jget item "id"))
                           (plist-get (emacs-pi-history-active-branch entries "f")
                                      :entries))
                   '("a" "b" "e" "f")))))

(ert-deftest emacs-pi-two-chats-and-streaming-draft ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (emacs-pi-executable (expand-file-name "test/fake-pi.py"
                                               (file-name-directory
                                                (locate-library "emacs-pi"))))
         (first nil) (second nil))
    (unwind-protect
        (progn
          (setq first (emacs-pi--open root)
                second (emacs-pi--open root))
          (let ((one (with-current-buffer first emacs-pi--session))
                (two (with-current-buffer second emacs-pi--session)))
            (should-not (equal (emacs-pi-session-client-id one)
                               (emacs-pi-session-client-id two)))
            (should (emacs-pi-test--wait
                     (lambda () (and (eq (emacs-pi-session-phase one) 'ready)
                                     (eq (emacs-pi-session-phase two) 'ready)))))
            (should (emacs-pi-test--wait
                     (lambda () (and (emacs-pi-session-context-usage one)
                                     (emacs-pi-session-context-usage two)))))
            (with-current-buffer first
              (emacs-pi-input-set "hello")
              (emacs-pi-send)
              (emacs-pi-input-set "next draft"))
            (should (emacs-pi-test--wait
                     (lambda () (and (= (length (emacs-pi-session-messages one)) 2)
                                     (not (emacs-pi-session-running one))))))
            (with-current-buffer first
              (emacs-pi-ui-render one)
              (should (string-match-p "1.2k/10.0k" (emacs-pi-ui--header)))
              (should (equal (emacs-pi-input-text) "next draft"))
              (should (save-excursion
                        (goto-char (point-min))
                        (search-forward "收到：hello" nil t))))
            (should-not (emacs-pi-session-messages two))))
      (when (buffer-live-p first) (kill-buffer first))
      (when (buffer-live-p second) (kill-buffer second))
      (delete-directory root t))))

(ert-deftest emacs-pi-slash-commands-and-completion ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (emacs-pi-executable (expand-file-name "test/fake-pi.py"
                                               (file-name-directory
                                                (locate-library "emacs-pi"))))
         (chat nil))
    (unwind-protect
        (progn
          (setq chat (emacs-pi--open root))
          (let ((session (with-current-buffer chat emacs-pi--session)))
            (should (emacs-pi-test--wait
                     (lambda () (and (eq (emacs-pi-session-phase session) 'ready)
                                     (emacs-pi-session-commands session)))))
            (with-current-buffer chat
              (emacs-pi-input-set "/de")
              (let ((capf (emacs-pi-input-completion-at-point)))
                (should capf)
                (should (member "/demo" (nth 2 capf))))
              (emacs-pi-input-set "/unknown")
              (should-error (emacs-pi-send) :type 'user-error)
              (should (equal (emacs-pi-input-text) "/unknown"))
              (emacs-pi-input-set "/demo")
              (emacs-pi-send))
            (should (emacs-pi-test--wait
                     (lambda () (= (length (emacs-pi-session-messages session)) 2))))
            (with-current-buffer chat
              (should (string-empty-p (emacs-pi-input-text))))))
      (when (buffer-live-p chat) (kill-buffer chat))
      (delete-directory root t))))

(ert-deftest emacs-pi-composer-navigation-and-background ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (session (make-emacs-pi-session :root root :client-id "nav-123456"
                                         :phase 'ready))
         (buffer (emacs-pi-ui-create session)))
    (unwind-protect
        (with-current-buffer buffer
          (emacs-pi-input-set "hello  ")
          (let ((begin (emacs-pi-input-beginning)))
            (goto-char (point-min))
            (emacs-pi-ui-focus-or-insert)
            (should (= (point) (+ begin 5)))
            (should (equal (emacs-pi-input-text) "hello  "))
            (goto-char (+ begin 3))
            (emacs-pi-ui-beginning-of-line)
            (should (= (point) begin))
            (goto-char (1- begin))
            (emacs-pi-ui-beginning-of-line)
            (should (= (point) begin))
            (emacs-pi-ui-focus-or-insert)
            (should (equal (emacs-pi-input-text) "ihello  "))
            (should (eq (overlay-get emacs-pi--input-background 'face)
                        'emacs-pi-input-face))
            (should (<= (overlay-start emacs-pi--input-background) begin))
            (should (= (overlay-end emacs-pi--input-background)
                       (point-max)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-pi-historical-user-messages-are-highlighted ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (session (make-emacs-pi-session
                   :root root :client-id "highlight-123456" :phase 'ready
                   :messages (list
                              (emacs-pi--jobject "role" "user"
                                                 "content" "First line\nsecond line")
                              (emacs-pi--jobject "role" "assistant"
                                                 "content" "Answer")
                              (emacs-pi--jobject "role" "user"
                                                 "content" "Another prompt"))))
         (buffer (emacs-pi-ui-create session)))
    (unwind-protect
        (with-current-buffer buffer
          (emacs-pi-ui-render session)
          (should (= (length emacs-pi--user-overlays) 2))
          (dolist (overlay emacs-pi--user-overlays)
            (let ((face (overlay-get overlay 'face)))
              (should (equal (plist-get face :background)
                             (or (face-foreground 'warning nil t)
                                 "#d97706")))
              (should (plist-get face :extend)))
            (should (eq (char-before (overlay-end overlay)) ?\n))
            (should (< (overlay-end overlay)
                       (marker-position emacs-pi--input-marker))))
          (goto-char (point-min))
          (search-forward "second line")
          (should (cl-some (lambda (overlay)
                             (and (<= (overlay-start overlay) (point))
                                  (< (point) (overlay-end overlay))))
                           emacs-pi--user-overlays))
          (should-not (cl-some (lambda (overlay)
                                 (<= (overlay-start overlay)
                                     (emacs-pi-input-beginning)
                                     (overlay-end overlay)))
                               emacs-pi--user-overlays))
          (emacs-pi-ui-render session)
          (should (= (length emacs-pi--user-overlays) 2))
          (should (eq (overlay-get emacs-pi--input-background 'face)
                      'emacs-pi-input-face)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-pi-only-composer-is-editable ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (session (make-emacs-pi-session :root root :client-id "edit-123456"
                                         :phase 'ready
                                         :messages (list (emacs-pi--jobject
                                                          "role" "user"
                                                          "content" "Past prompt"))))
         (buffer (emacs-pi-ui-create session)))
    (unwind-protect
        (with-current-buffer buffer
          (emacs-pi-ui-render session)
          (let ((original (buffer-string))
                (begin (emacs-pi-input-beginning)))
            (goto-char (point-min))
            (should-error (insert "x"))
            (goto-char (1- begin))
            (should-error (insert "x"))
            (should-error (delete-region (1- begin) begin))
            (should (equal (buffer-string) original))
            (goto-char begin)
            (insert "new draft")
            (should (equal (emacs-pi-input-text) "new draft"))
            (emacs-pi-ui-render session)
            (should (equal (emacs-pi-input-text) "new draft"))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-pi-pastes-clipboard-image-and-text ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (program (expand-file-name "fake-pngpaste" root))
         (session (make-emacs-pi-session :root root :client-id "paste-123456"
                                         :phase 'ready))
         (buffer (emacs-pi-ui-create session)))
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/bin/sh\nprintf '\\211PNG\\r\\n\\032\\n' > \"$1\"\n"))
          (set-file-modes program #o755)
          (with-current-buffer buffer
            (let ((emacs-pi-pngpaste-executable program))
              (goto-char (point-min))
              (emacs-pi-paste))
            (should (= (length emacs-pi--attachments) 1))
            (should (equal (emacs-pi--jget (car emacs-pi--attachments) "name")
                           "clipboard.png"))
            (should (equal (emacs-pi--jget (car emacs-pi--attachments) "mimeType")
                           "image/png"))
            (should (= (point) (emacs-pi-input-beginning)))
            (should (string-empty-p (emacs-pi-input-text)))
            (with-temp-file program (insert "#!/bin/sh\nexit 1\n"))
            (let ((emacs-pi-pngpaste-executable program)
                  (kill-ring '("plain text"))
                  (kill-ring-yank-pointer nil)
                  (interprogram-paste-function nil))
              (emacs-pi-paste))
            (should (equal (emacs-pi-input-text) "plain text"))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-pi-process-fold-survives-redraw ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (user (emacs-pi--jobject "role" "user" "content" "Please inspect"))
         (tool (emacs-pi--jobject "type" "toolCall" "id" "call-1"
                                   "name" "read"
                                   "arguments" (emacs-pi--jobject "path" "README.md")))
         (step (emacs-pi--jobject "role" "assistant" "content" (vector tool)))
         (reply (emacs-pi--jobject "role" "assistant"
                                    "content" (vector (emacs-pi--jobject
                                                       "type" "text" "text" "Done."))))
         (tools (make-hash-table :test #'equal))
         (session (make-emacs-pi-session :root root :client-id "fold-123456"
                                         :phase 'ready :messages (list user step reply)
                                         :tools tools))
         (buffer (emacs-pi-ui-create session)))
    (unwind-protect
        (with-current-buffer buffer
          (puthash "call-1"
                   (emacs-pi--jobject
                    "type" "tool_execution_end" "isError" :false
                    "result" (emacs-pi--jobject
                              "content" (vector (emacs-pi--jobject
                                                 "type" "text" "text" "file body"))))
                   tools)
          (emacs-pi-input-set "unsent draft")
          (emacs-pi-ui-render session)
          (goto-char (point-min))
          (should (search-forward "Process · 1 step" nil t))
          (should (search-forward "Done." nil t))
          (goto-char (point-min))
          (search-forward "Process")
          (let* ((header (emacs-pi-ui--process-at-point))
                 (body (overlay-get header 'emacs-pi-process)))
            (should (eq (overlay-get body 'invisible) 'emacs-pi-process))
            (emacs-pi-ui-toggle-process)
            (should-not (overlay-get body 'invisible))
            (goto-char (point-min))
            (search-forward "✓ read")
            (let* ((tool-header (emacs-pi-ui--process-at-point))
                   (tool-body (overlay-get tool-header 'emacs-pi-process)))
              (should (eq (overlay-get tool-body 'invisible)
                          'emacs-pi-process))
              (emacs-pi-ui-toggle-process)
              (should-not (overlay-get tool-body 'invisible)))
            (emacs-pi-ui-render session)
            (goto-char (point-min))
            (search-forward "Process")
            (setq header (emacs-pi-ui--process-at-point)
                  body (overlay-get header 'emacs-pi-process))
            (should-not (overlay-get body 'invisible))
            (should (equal (emacs-pi-input-text) "unsent draft"))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-pi-process-opens-during-run-and-closes-on-settle ()
  (let* ((root (make-temp-file "emacs-pi-running-fold-" t))
         (tool (emacs-pi--jobject "type" "toolCall" "id" "running-call"
                                  "name" "read"))
         (session (make-emacs-pi-session
                   :root root :client-id "running-fold-123456" :phase 'ready
                   :running t :tools (make-hash-table :test #'equal)
                   :messages (list
                              (emacs-pi--jobject "role" "user"
                                                 "content" "Inspect")
                              (emacs-pi--jobject "role" "assistant"
                                                 "content" (vector tool)))))
         (buffer (emacs-pi-ui-create session)))
    (unwind-protect
        (with-current-buffer buffer
          (cl-labels ((body (key)
                        (overlay-get
                         (cl-find-if
                          (lambda (overlay)
                            (equal (overlay-get overlay 'emacs-pi-process-key)
                                   key))
                          emacs-pi--process-overlays)
                         'emacs-pi-process))
                      (toggle (key)
                        (goto-char
                         (overlay-start
                          (cl-find-if
                           (lambda (overlay)
                             (equal (overlay-get overlay 'emacs-pi-process-key)
                                    key))
                           emacs-pi--process-overlays)))
                        (emacs-pi-ui-toggle-process)))
            (emacs-pi-ui-render session)
            (should-not (overlay-get (body 0) 'invisible))
            (should (eq (overlay-get (body "tool:running-call") 'invisible)
                        'emacs-pi-process))
            (toggle 0)
            (emacs-pi-ui-render session)
            (should (eq (overlay-get (body 0) 'invisible)
                        'emacs-pi-process))
            (toggle 0)
            (toggle "tool:running-call")
            (emacs-pi-ui-render session)
            (should-not (overlay-get (body "tool:running-call") 'invisible))
            (setf (emacs-pi-session-running session) nil)
            (emacs-pi-ui-schedule session nil)
            (emacs-pi-ui-render session)
            (should (eq (overlay-get (body 0) 'invisible)
                        'emacs-pi-process))
            (should (eq (overlay-get (body "tool:running-call") 'invisible)
                        'emacs-pi-process))
            (toggle 0)
            (emacs-pi-ui-render session)
            (should-not (overlay-get (body 0) 'invisible))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-pi-process-steps-have-no-blank-lines ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (tool-one (emacs-pi--jobject "type" "toolCall" "id" "one"
                                      "name" "read"))
         (tool-two (emacs-pi--jobject "type" "toolCall" "id" "two"
                                      "name" "ls"))
         (session (make-emacs-pi-session
                   :root root :client-id "spacing-123456" :phase 'ready
                   :tools (make-hash-table :test #'equal)
                   :messages (list
                              (emacs-pi--jobject "role" "user"
                                                 "content" "Inspect")
                              (emacs-pi--jobject "role" "assistant"
                                                 "content" (vector tool-one))
                              (emacs-pi--jobject "role" "assistant"
                                                 "content" (vector tool-two))
                              (emacs-pi--jobject "role" "assistant"
                                                 "content" "Done"))))
         (buffer (emacs-pi-ui-create session)))
    (unwind-protect
        (with-current-buffer buffer
          (emacs-pi-ui-render session)
          (let* ((header (cl-find-if
                          (lambda (overlay)
                            (equal (overlay-get overlay 'emacs-pi-process-key)
                                   "tool:one"))
                          emacs-pi--process-overlays))
                 (body (and header (overlay-get header 'emacs-pi-process))))
            (should body)
            (goto-char (overlay-end body))
            (should (looking-at-p "Pi step: "))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-pi-open-uses-full-window ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (emacs-pi-executable (expand-file-name "test/fake-pi.py"
                                               (file-name-directory
                                                (locate-library "emacs-pi"))))
         (chat nil))
    (unwind-protect
        (save-window-excursion
          (split-window-right)
          (setq chat (emacs-pi--open root))
          (should (one-window-p))
          (should (eq (window-buffer (selected-window)) chat)))
      (when (buffer-live-p chat) (kill-buffer chat))
      (delete-directory root t))))

(ert-deftest emacs-pi-quit-removes-chat-buffer-and-process ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (emacs-pi-executable (expand-file-name "test/fake-pi.py"
                                               (file-name-directory
                                                (locate-library "emacs-pi"))))
         (chat nil)
         (session nil)
         (connection nil)
         (id nil))
    (unwind-protect
        (save-window-excursion
          (setq chat (emacs-pi--open root)
                session (with-current-buffer chat emacs-pi--session)
                id (emacs-pi-session-client-id session))
          (should (emacs-pi-test--wait
                   (lambda () (eq (emacs-pi-session-phase session) 'ready))))
          (setq connection (emacs-pi-session-connection session))
          (should (eq (gethash id emacs-pi--chats) chat))
          (with-current-buffer chat
            (emacs-pi-input-set "unsent draft")
            (emacs-pi-quit))
          (should-not (buffer-live-p chat))
          (should-not (gethash id emacs-pi--chats))
          (should-not (emacs-pi-session-buffer session))
          (should (eq (emacs-pi-session-phase session) 'dead))
          (should (emacs-pi-test--wait
                   (lambda () (not (process-live-p
                                     (emacs-pi-rpc-process connection)))))))
      (when (buffer-live-p chat) (kill-buffer chat))
      (delete-directory root t))))

(ert-deftest emacs-pi-context-header-and-mode-line-state ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (usage (emacs-pi--jobject "tokens" 6200 "contextWindow" 128000))
         (model (emacs-pi--jobject "provider" "test" "id" "model"))
         (session (make-emacs-pi-session :root root :client-id "state-123456"
                                         :phase 'ready :model model
                                         :thinking "high" :context-usage usage))
         (buffer (emacs-pi-ui-create session)))
    (unwind-protect
        (with-current-buffer buffer
          (should (string-match-p "6.2k/128.0k" (emacs-pi-ui--header)))
          (should (equal (emacs-pi-ui--format-tokens 1000000) "1.0M"))
          (should (string-match-p "Pi idle" (emacs-pi-ui--state)))
          (setf (emacs-pi-session-running session) t
                (emacs-pi-session-active-tool session) "read")
          (should (string-match-p "Pi tool: read" (emacs-pi-ui--state)))
          (emacs-pi-ui-schedule session nil)
          (should emacs-pi--spinner-timer)
          (setf (emacs-pi-session-running session) nil)
          (emacs-pi-ui-schedule session nil)
          (should-not emacs-pi--spinner-timer)
          (setf (emacs-pi-session-context-usage session)
                (emacs-pi--jobject "tokens" :null "contextWindow" 128000))
          (should (string-match-p "context: —" (emacs-pi-ui--header))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-pi-root-picker-offers-existing-and-new ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (record (list :id "1234567890abcdefghijkl" :cwd root
                       :modified (current-time) :preview "First prompt"))
         (choice nil)
         (opened nil)
         (resumed nil)
         (pick-new t))
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-pi-history-list)
                   (lambda (&optional _root) (list record)))
                  ((symbol-function 'completing-read)
                   (lambda (_prompt choices &rest _args)
                     (setq choice choices)
                     (if pick-new "[New session]" (caar choices))))
                  ((symbol-function 'emacs-pi--open)
                   (lambda (directory &optional _file)
                     (setq opened directory)))
                  ((symbol-function 'emacs-pi--resume-record)
                   (lambda (entry) (setq resumed entry))))
          (emacs-pi-chat root)
          (should (equal opened (emacs-pi--local-root root)))
          (should (= (length choice) 2))
          (should (string-match-p "First prompt" (caar choice)))
          (should (string-match-p "1234567890ab" (caar choice)))
          (should (string-suffix-p "project"
                                   (emacs-pi--middle-truncate
                                    "~/very/long/nested/directory/name/project" 20)))
          (setq pick-new nil)
          (emacs-pi-chat root)
          (should (eq resumed record)))
      (delete-directory root t))))

(ert-deftest emacs-pi-history-preview-uses-latest-name ()
  (let* ((root (make-temp-file "emacs-pi-test-" t))
         (file (expand-file-name "session.jsonl" root)))
    (unwind-protect
        (progn
          (with-temp-file file
            (dolist (entry
                     (list (emacs-pi--jobject "type" "session" "id" "history-id"
                                              "cwd" root "timestamp" "2026-09-29T00:00:00Z")
                           (emacs-pi--jobject
                            "type" "message" "message"
                            (emacs-pi--jobject "role" "user" "content" "First prompt"))
                           (emacs-pi--jobject "type" "session_info" "name" "Old name")
                           (emacs-pi--jobject "type" "session_info" "name" "New name")
                           (emacs-pi--jobject
                            "type" "message" "message"
                            (emacs-pi--jobject "role" "user" "content" "Latest prompt"))))
              (insert (emacs-pi--jencode entry) "\n")))
          (let ((record (emacs-pi-history--record file)))
            (should (equal (plist-get record :name) "New name"))
            (should (equal (plist-get record :preview) "First prompt"))
            (should (equal (plist-get record :last-preview) "Latest prompt"))
            (should (= (plist-get record :message-count) 2))))
      (delete-directory root t))))

(ert-deftest emacs-pi-history-restores-tool-result-details ()
  (let* ((message (emacs-pi--jobject
                   "role" "toolResult" "toolCallId" "call-1"
                   "isError" :false
                   "content" (vector (emacs-pi--jobject
                                      "type" "text" "text" "result body"))))
         (tools (emacs-pi-session--tools-from-messages (list message)))
         (state (gethash "call-1" tools)))
    (should (equal (emacs-pi--jget state "type") "tool_execution_end"))
    (should (equal (emacs-pi-ui--tool-result-text state) "result body"))))

(ert-deftest emacs-pi-minibuffer-completion-works-with-native-styles ()
  (let* ((root (make-temp-file "emacs-pi-complete-" t))
         (file (expand-file-name "alpha file.el" root))
         (session (make-emacs-pi-session :root (file-name-as-directory root)
                                         :client-id "completion-123456"
                                         :phase 'ready))
         (buffer (emacs-pi-ui-create session))
         (record (list :id "saved-123" :name "Earlier work"
                       :cwd root :preview "First prompt")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "example"))
          (with-current-buffer buffer
            (let ((completion-styles '(basic)))
              (emacs-pi-input-set "Read @alpha")
              (cl-letf (((symbol-function 'emacs-pi-history-list)
                         (lambda (&optional _root) (list record)))
                        ((symbol-function 'completing-read)
                         (lambda (_prompt choices &rest args)
                           (should (equal (nth 2 args) "alpha"))
                           (should (memq 'substring completion-styles))
                           (should (completion-all-completions
                                    "alpha" choices nil 5))
                           (car (cl-find-if
                                 (lambda (item)
                                   (string-match-p "alpha file.el" (car item)))
                                 choices)))))
                (emacs-pi-complete))
              (should (equal (emacs-pi-input-text)
                             "Read @\"alpha file.el\""))
              (emacs-pi-input-set "Use @")
              (cl-letf (((symbol-function 'emacs-pi-history-list)
                         (lambda (&optional _root) (list record)))
                        ((symbol-function 'completing-read)
                         (lambda (_prompt choices &rest _args)
                           (car (cl-find-if
                                 (lambda (item)
                                   (string-suffix-p "[session]" (car item)))
                                 choices)))))
                (emacs-pi-complete))
              (should (equal (emacs-pi-input-text)
                             "Use @[Earlier work](pi-session:saved-123)"))
              (emacs-pi-input-set "/de")
              (setf (emacs-pi-session-commands session)
                    (list (emacs-pi--jobject "name" "demo"
                                             "description" "Demo command")))
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt choices &rest _args)
                           (car (assoc "/demo  — Demo command" choices)))))
                (emacs-pi-complete))
              (should (equal (emacs-pi-input-text) "/demo")))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-pi-session-reference-sends-active-dialogue ()
  (let* ((root (make-temp-file "emacs-pi-reference-" t))
         (file (expand-file-name "saved.jsonl" root))
         (emacs-pi-session-directory root)
         (emacs-pi-executable (expand-file-name
                               "test/fake-pi.py"
                               (file-name-directory (locate-library "emacs-pi"))))
         (buffer nil)
         (compact "Compare @[Earlier work](pi-session:saved-123)"))
    (unwind-protect
        (progn
          (with-temp-file file
            (dolist (spec '(("a" nil "user" "Initial question")
                            ("b" "a" "assistant" "First answer")
                            ("c" "b" "user" "Abandoned branch")
                            ("d" "b" "user" "Current question")
                            ("e" "d" "assistant" "Current answer")))
              (insert (emacs-pi--jencode
                       (emacs-pi--jobject
                        "type" "message" "id" (nth 0 spec)
                        "parentId" (or (nth 1 spec) :null)
                        "message" (emacs-pi--jobject
                                   "role" (nth 2 spec)
                                   "content" (nth 3 spec)))) "\n"))
            (insert (emacs-pi--jencode
                     (emacs-pi--jobject "type" "session" "id" "saved-123"
                                          "cwd" root)) "\n")
            (insert (emacs-pi--jencode
                     (emacs-pi--jobject "type" "session_info"
                                          "name" "Earlier work")) "\n"))
          (setq buffer (emacs-pi--open root))
          (let ((session (with-current-buffer buffer emacs-pi--session)))
            (should (emacs-pi-test--wait
                     (lambda () (eq (emacs-pi-session-phase session) 'ready))))
            (with-current-buffer buffer
              (emacs-pi-input-set compact)
              (emacs-pi-send))
            (should (emacs-pi-test--wait
                     (lambda () (= (length (emacs-pi-session-messages session)) 2))))
            (let* ((user (car (emacs-pi-session-messages session)))
                   (sent (emacs-pi--message-text user)))
              (should (equal (emacs-pi-session-last-prompt session) compact))
              (should (string-match-p "Current answer" sent))
              (should (string-match-p "Initial question" sent))
              (should-not (string-match-p "Abandoned branch" sent))
              (should (equal (emacs-pi-ui--visible-message-text user sent)
                             compact)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emacs-pi-missing-session-reference-preserves-draft ()
  (let* ((root (make-temp-file "emacs-pi-missing-reference-" t))
         (emacs-pi-session-directory root)
         (session (make-emacs-pi-session :root root :client-id "missing-123456"
                                         :phase 'ready))
         (buffer (emacs-pi-ui-create session))
         (draft "See @[Missing](pi-session:not-found)"))
    (unwind-protect
        (with-current-buffer buffer
          (emacs-pi-input-set draft)
          (should-error (emacs-pi-send) :type 'user-error)
          (should (equal (emacs-pi-input-text) draft)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(provide 'emacs-pi-test)
;;; emacs-pi-test.el ends here
