# emacs-pi

[简体中文](README.zh-CN.md)

Development integration APIs: [enumerate and restore sessions](docs/PUBLIC-API.md)
(including current limitations and callback contracts).

A native Emacs chat interface for [Pi Coding Agent](https://github.com/badlogic/pi-mono). Each chat runs in its own Pi RPC process, so you can keep multiple project conversations open at once.

## Features

- Stream responses, thinking, and tool activity in a single Emacs buffer.
- Start, resume, and switch between Pi sessions.
- Choose available models and thinking levels; discover Pi extension commands.
- Queue follow-up prompts or steer a running conversation, and review or edit the queue.
- Attach PNG/JPEG images, paste clipboard images, and open received images externally.
- Complete slash commands, project files, and saved sessions from the input area. `@` completes files and directories; `@session` opens the saved-session picker, with aligned columns for the last user message's local timestamp and the first/latest user queries, followed by project and short ID. Sessions are sorted by last user interaction (newest first); narrow windows hide the project column. Missing timestamps show `—`, not file or assistant activity times.

## Requirements

- Emacs 29.1 or later
- [Pi Coding Agent](https://github.com/badlogic/pi-mono), available as `pi` on `PATH` or configured with `emacs-pi-executable`
- `markdown-mode` 2.3 or later
- Node.js **22.19+** for the default persistent transport; currently POSIX (macOS/Linux).
  The bundled bridge uses Node's standard library; no bridge npm install is needed.

## Persistent ownership

By default, closing a chat buffer or exiting/killing Emacs detaches its UI; Pi
continues independently. Reopening uses the existing owner first. `C-c C-q`
explicitly finishes that Pi instance and closes the UI only after confirmed
exit; `emacs-pi-shutdown` keeps the transcript UI. History is retained. Unknown
ownership never silently starts a replacement. Set `emacs-pi-persistent` to nil
only for the explicit legacy Emacs-owned mode (no persistence guarantee).

Keep `emacs-pi-runtime.el` and **`emacs-pi-bridge.mjs` beside the other Lisp
files** when installing/copying the package. Copying only `*.el` is incomplete.
The source tree contains development changes that must be published before a
remote package install can include them; this work does not update your installed
package automatically. Public persistent opens now use asynchronous `:on-ready`;
see [the API and recovery limits](docs/PUBLIC-API.md).

## Installation

Install directly from GitHub with Emacs 29.1 or later:

```elisp
(package-vc-install "https://github.com/wowhxj/emacs-pi")
```

Or clone the repository and add it to your load path:

```elisp
(add-to-list 'load-path "/path/to/emacs-pi")
(require 'emacs-pi)
```

Optionally bind a key and set the Pi executable path:

```elisp
(use-package emacs-pi
  :commands (emacs-pi-chat emacs-pi-resume)
  :bind ("<f6>" . emacs-pi-chat)
  :custom
  (emacs-pi-executable "pi"))
```

If Emacs cannot find `pi` on `PATH`, set `emacs-pi-executable` to its absolute path.

## Getting started

Run `M-x emacs-pi-chat`, choose a project directory, then select a saved session or start a new one. Type in the `You>` input area and press `RET` to send. Enter `/` or `@` and press `TAB` to complete commands and paths. Choose a directory with `RET` to insert it, then press `TAB` again to complete inside it. Use `@session` followed by `TAB` to pick a saved conversation; choosing one inserts its saved-dialogue reference.

`/compact [instructions]` compacts the current context through Pi RPC. The slash picker, completion, dispatch, and `/help` share the same client command registry and current RPC-discovered extensions/templates/skills. Pi CLI commands whose full interactive workflows are not available over RPC are intentionally not exposed in Emacs.

## Top status bar

The top line shows current context usage and percentage, user/assistant message counts (`prompts`/`calls`), full-session tokens, cache-read token share, and Pi's estimated USD cost. Model, provider, and thinking level sit on the right. Statistics refresh after runs settle and context changes, not on each streamed token.

Narrow windows hide optional metrics first; hover over the line for the full summary. Context usage warns at 80% and alerts at 95%. Cache percentage is `cacheRead / (input + cacheRead + cacheWrite)`, not a request hit rate. Missing data stays hidden or unknown; immediately after compaction, context usage can remain unknown until the next response.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Send prompt / insert newline | `RET` / `S-RET` |
| Steer a running conversation | `C-c C-s` |
| Stop and clear queued prompts / abort the current run | `C-c C-k` / `M-x emacs-pi-abort-current` |
| Show and edit the prompt queue | `C-c C-l` / `C-c C-u` |
| Resume a session / switch chat | `C-c C-r` / `C-c C-b` |
| Attach an image / open an image | `M-x emacs-pi-attach-image` / `C-c C-o` |
| Paste from the clipboard | `C-c C-p` (also `s-v` on macOS) |
| Browse prompt history | `M-p` / `M-n` |
| Enter copy mode / return to input (semi-char mode) | `C-c C-t` / `C-c C-j`; press `i` outside the composer to return, or type `i` inside it |
| Focus the input area | `C-c C-i` |
| Finish Pi and close UI / finish Pi but retain UI | `C-c C-q` / `M-x emacs-pi-shutdown` |

## Configuration

- `emacs-pi-executable` — Pi executable (default: `pi`)
- `emacs-pi-startup-timeout` — seconds to wait for Pi's initial RPC response (default: 90)
- `emacs-pi-extra-arguments` — additional Pi RPC process arguments
- `emacs-pi-session-directory` — optional Pi session directory
- `emacs-pi-history-cache-directory` — persistent summary indexes for asynchronous enumeration (default: `emacs-pi/history-cache/` under the Emacs configuration directory; nil disables disk caching). Private `0600` indexes contain paths, first/latest prompt previews and file signatures, and can be deleted to rebuild. Restarts only reparse changed files; the Hub can display cached rows before background verification
- `emacs-pi-show-thinking` — show thinking text in the conversation

Image clipboard paste on macOS requires `pngpaste`. For queue editing behavior and its protocol constraints, see [docs/QUEUE.md](docs/QUEUE.md).
