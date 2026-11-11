# Public session APIs (development)

## Inspect persistent runtime ownership without starting Pi

```elisp
(setq cancel-runtime
      (emacs-pi-inspect-runtimes
       (lambda (instances) (message "%S" instances))
       :on-error (lambda (diagnostic) (message "%s" diagnostic))))
```

This asynchronous, cancellable API queries only `emacs-pi-runtime-directory`.
It neither creates the registry nor starts Pi, attaches a UI, takes its writer
lease, sends RPC commands, or changes a session. It works while another client
holds the controller. Cancelling terminates only the inventory query process.

Each plist contains `:instance`, `:generation`, `:status`, `:activity`,
`:sessionFile`, `:sessionDirectory`, `:sessionId`, `:cwd`, `:hasController`, and
`:persistent`. Status strings are `starting`, `running`, `stopping`, `finished`,
`exited`, `failed`, or `unknown`. The directory is the explicit `--session-dir`
when provided; otherwise it may be nil. Historical bridge versions can lack
controller/directory metadata. Missing controller information is nil/unknown,
not evidence that a writer lease is available. IDs/paths can be unknown for a
fresh or incompletely recorded instance.

**Process presence is not model activity.** Live instances deliberately report
`:activity "unknown"`, never idle; confirmed ended instances report `"stopped"`.
No prompt, response, extension question, raw error, argv, environment or token
is returned. Inventory is bounded; malformed/incomplete owner records remain
`unknown`, not absent. Empty inventory means no records in this registry only;
it says nothing about legacy/external Pi processes or a different registry.
Consumers must bind caches to the queried configuration and reject stale
results; a completed query is a point-in-time observation, not a writer lease.

## Bridge recovery and pressure boundaries (development)

The bundled Node owner validates private state version, authentication material,
working-directory/file types and recorded PID fields before reusing or replacing
an instance. An ended status alone never authorizes replacement: both recorded
PIDs must be proven absent. EPERM/invalid/missing PID facts remain possibly-live.
A live unindexed or malformed owner can conservatively block historical restore
in the registry. Concurrent cold ensures share one generation; ended restores
use an exclusive launch claim, so competing callers may receive a retry error.

At the Node transport boundary, an already-owned canonical file can reconnect
even after the history/project path disappears: missing suffixes are resolved
against the nearest existing canonical ancestor. Dangling symlinks are rejected,
not guessed. No replacement is launched while those required resources are
missing. `emacs-pi-open-session` and Hub now perform owner discovery first and
use a strict attach-only transport pinned to instance/generation/file/ID. This
transport has no launch fallback and does not need the original executable or
cwd to exist. An isolated Hub/native probe deletes history, cwd and executable,
reattaches the same generation, finishes it, then confirms another open cannot
replace it with those resources absent. Unresolved symlinks remain unknown.

JSONL parsing splits only at LF (including split UTF-8/CRLF), and after one
malformed record reports one terminal failure rather than executing later
ambiguous records. Partial input remains capped at 64 MiB. IPC and Pi stdin
admission permits one encoded frame up to 64 MiB plus at most 8 MiB of
smaller pending writes. A second large frame before drain is refused, never
retried. This preserves large input/history/snapshot support while bounding
backpressure. A slow controller can be disconnected
without replacing/pausing the owner; stdout continues to drain. Replay/active
preview remain bounded at 4 MiB with explicit preview truncation. A large frame
rejected at transport is not retried; history resynchronization may be needed.

There are at most 256 outstanding requests awaiting responses and 100/8 MiB pre-ready
proxy commands; oversized RPC identities are rejected. In-flight duplicate IDs
remain reserved across detach. None of these limits authorize prompt replay or
imply delivery certainty after a disconnect.

The retained queue plus unanswered-question aggregate is capped at 16 MiB and
256 questions (separate from the 4 MiB live-text preview). On overflow, the owner
continues draining and keeps Pi alive. It does not approve, answer, cancel or
retry work. Snapshots carry `recoveryIncomplete`, `queueIncomplete` and
`questionsIncomplete`; the Emacs UI displays an explicit warning and never uses
an incomplete queue as a known-empty queue. Replies to question IDs whose full
context was not retained are refused. Previously retained questions stay intact.
Full recovery beyond this supported budget is **not guaranteed**: inspect the
warning and explicitly finish/recover rather than approving unseen context.
Question uncertainty stays marked until native settlement; a fresh valid queue
update can restore its queue projection. These overflow negatives are controlled
RPC tests, not proof of live approval-provider behavior.

The native history picker now also uses the public owner-first open path rather
than rejecting a vanished cwd before discovery. Remaining fork/alias/reload edge
cases and live-provider model/approval workflows still require final acceptance.

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

Unchanged files reuse a memory cache shared with the synchronous history
picker. The asynchronous API also loads and atomically saves per-storage-root
JSON indexes, so signatures survive Emacs restarts. Signatures include the
parser schema, size, modification/change times, inode and device; changed or
replaced files are reparsed, and cached records retain their diagnostics.
Deleted files are removed from the completed index. Files changed during a
read are not cached. Cancellation does not publish an incomplete index.
Broken, incompatible or unwritable indexes do not fail enumeration.
Only the recognized observation-ledger schema at
`observation-pack/ledger.jsonl` is excluded; real sessions at that path
and damaged session files are not silently ignored.

For an immediate **unverified** initial display, call:

```elisp
(emacs-pi-cached-sessions '("/absolute/session/root"))
;; => (:items RECORDS :diagnostics DIAGNOSTICS :cached t)
```

This only reads summaries; it neither scans session files nor starts Pi.
Deleted or changed files may still appear until `emacs-pi-list-sessions`
finishes verification. Always use that asynchronous API afterwards, and
visibly distinguish cached rows from verified results. Older clients may
not provide the new function; consumers should check `fboundp`.

`emacs-pi-history-cache-directory` defaults to `emacs-pi/history-cache/`
under `user-emacs-directory`; nil disables disk persistence. Index files
have mode `0600` and contain paths and first/latest prompt previews, not
full transcripts. They are parsed as JSON data, never loaded as code.
Deleting them forces a rebuild. Indexes larger than 32 MiB are ignored.

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

Persistent opens now discover ownership asynchronously: consume the buffer
from `:on-ready`, not the immediate return (a discovery cancellation function).
Legacy nonpersistent opens can still return a buffer immediately. Cancellation
only suppresses discovery before handoff, not an already-started UI handshake.
Ready follows an RPC `get_state` response whose exact ID and canonical file match the
selected header/file. No prompt is sent. A terminal callback runs at most
once; restoration and verification have bounded timeouts. `display` is
`current`, `none`, or a standard `display-buffer` action; the new API does
not delete other windows. Existing interactive commands keep their
sole-window defaults. `session-directory` is a per-call storage override.
Historical recovery requires an existing local project directory; authenticated
existing-owner attach does not. Existing same-file buffers in another root are
rejected; dead sessions can restart in place.
Starting sessions are waited for rather than duplicated.

Limitations: `emacs-pi-open-session` verifies file/ID but the Pi state
response does not report authoritative execution cwd. The fork API below
also verifies the new header metadata, not runtime cwd. Do not interpret
`default-directory` or a header alone as runtime evidence. Cancellation of
an open after discovery handoff is not implemented. Attach is generation-pinned
and rejects lost/changed owners rather than falling back to historical startup.
Hub uses optional `:expected-id` to bind its selection; `:on-missing` is called
only after a successful no-owner observation, never on inspection uncertainty.

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

恢复默认不关闭其他窗口；持久模式异步查 owner，从 on-ready 获取 buffer，确认 RPC
返回的会话文件及 ID。真实 Pi 恢复、执行目录和代次竞态仍需补充验证，
尚不能视为整个 Hub 方案已经验收。不得自动发送消息验证恢复。
