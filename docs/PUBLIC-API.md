# Public session APIs (development)

## Enumerate without starting Pi

```elisp
(setq cancel-scan
      (emacs-pi-list-sessions
       (lambda (result) (message "%S" result))
       :directories '("/absolute/session/root")
       :on-error (lambda (error) (message "%s" error))))
;; Optional: (funcall cancel-scan)
```

The asynchronous result is `(:items RECORDS :diagnostics DIAGNOSTICS)`.
Cancellation silently suppresses callbacks and releases the scan buffer.
Each record includes `:source` (canonical storage root), `:path`, `:id`,
`:cwd`, `:created`, `:name`, `:preview`, `:last-preview`, `:message-count`,
`:modified`, `:time-source`, `:empty`, `:internal`, `:archived`, and
`:invalid-lines`. `:modified` is an Emacs time from the latest user or
assistant message, not file mtime; absent timestamps remain nil. The
first user input remains the first even if it only contains an image.
Unknown status is the symbol `unknown`, never silently assumed false.
The consumer decides filtering. Source plus path/ID identify a record.

Scanning reads 64 KiB byte chunks and yields after bounded work. A single
large JSON line must still be parsed atomically, and directory listing is
one filesystem operation; this is cooperative, not a worker thread.
Symlink entries are currently skipped. Files are read to their initial
size; malformed or partial records produce diagnostics. This is not a
transactional filesystem snapshot. Internal/subagent and archive status
remain unknown until reliable producer metadata is supported.

Unchanged files reuse an in-memory cache shared with the synchronous
history picker. Cache signatures include size, modification/change times,
inode and device; changed or replaced files are reparsed, and cached
records retain their diagnostics. Files changed during a read are not
cached. Only the recognized observation-ledger schema at
`observation-pack/ledger.jsonl` is excluded; real sessions at that path
and damaged session files are not silently ignored.

Legacy `emacs-pi-history-list` remains synchronous and uses the same
parser/cache. It now reads complete previews and sorts by message time;
unknown times sort last. It does not provide the public API's diagnostics.

## Create without a history picker

```elisp
(emacs-pi-create-session
 "/absolute/project" :display 'none
 :on-ready (lambda (buffer) (pop-to-buffer buffer))
 :on-error (lambda (error) (message "%s" error)))
```

The directory must exist and be local. Each call starts a fresh RPC session;
no resume arguments or initial prompt are sent. Storage can be selected with
`:session-directory`. The buffer is returned immediately; readiness follows a
live `get_state` response and generation check. A new session file is not
required to exist before its first message. Cancellation/timeout does not
promise to stop an already launched client.

## Restore a selected file

```elisp
(emacs-pi-open-session
 "/absolute/session.jsonl" :directory "/absolute/project"
 :display 'none
 :on-ready (lambda (buffer) (pop-to-buffer buffer))
 :on-error (lambda (error) (message "%s" error)))
```

Returns a buffer immediately, not proof of readiness. Ready follows an
RPC `get_state` response whose exact ID and canonical file match the
selected header/file. No prompt is sent. A terminal callback runs at most
once; restoration and verification have bounded timeouts. `display` is
`current`, `none`, or a standard `display-buffer` action; the new API does
not delete other windows. Existing interactive commands keep their
sole-window defaults. `session-directory` is a per-call storage override.
Missing or remote project directories are rejected. Existing same-file
buffers in another root are rejected; dead sessions can restart in place.
Starting sessions are waited for rather than duplicated.

Limitations: `emacs-pi-open-session` verifies file/ID but the Pi state
response does not report authoritative execution cwd. The fork API below
also verifies the new header metadata, not runtime cwd. Do not interpret
`default-directory` or a header alone as runtime evidence. Cancellation of
open requests and generation-race hardening are not yet implemented.

## Fork a session file into a new project directory

```elisp
(emacs-pi-fork-session-file
 "/absolute/session.jsonl" :directory "/absolute/new-project"
 :session-directory "/absolute/session-root" :display 'none
 :on-ready (lambda (buffer) (pop-to-buffer buffer))
 :on-error (lambda (error) (message "%s" error)))
```

Starts Pi with `--fork` and verifies the live RPC state has a distinct
session ID, a separate session file, the requested cwd in the new header,
and `parentSession` pointing to the original file. The source is never
modified or deleted. The consumer must compare all non-header records and
choose when (or whether) to remove the source. This verifies readiness and
fork metadata, not runtime execution cwd or behavioral equivalence.

## External @ references

`emacs-pi-reference-providers` maps a name to a function. `TAB` on `@NAME`
calls it with the chat root; a returned file path replaces `@NAME` with an
@ reference. Unregistered names keep ordinary path completion.

# 中文摘要

提供只读、可取消的异步枚举和指定文件恢复接口。枚举不启动 Pi，
部分失败通过 diagnostics 返回；首条非文本用户输入不会被后面的
文本覆盖，最近交互时间不使用文件修改时间。现有同步历史调用继续可用。

恢复默认不关闭其他窗口，先返回 buffer，再通过 on-ready 确认 RPC
返回的会话文件及 ID。真实 Pi 恢复、执行目录和代次竞态仍需补充验证，
尚不能视为整个 Hub 方案已经验收。不得自动发送消息验证恢复。
