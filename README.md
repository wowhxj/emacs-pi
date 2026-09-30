# emacs-pi

[简体中文](README.zh-CN.md)

A native Emacs chat interface for [Pi Coding Agent](https://github.com/badlogic/pi-mono). Each chat runs in its own Pi RPC process, so you can keep multiple project conversations open at once.

## Features

- Stream responses, thinking, and tool activity in a single Emacs buffer.
- Start, resume, and switch between Pi sessions.
- Choose available models and thinking levels; discover Pi extension commands.
- Queue follow-up prompts or steer a running conversation, and review or edit the queue.
- Attach PNG/JPEG images, paste clipboard images, and open received images externally.
- Complete slash commands, project files, and saved sessions from the input area.

## Requirements

- Emacs 29.1 or later
- [Pi Coding Agent](https://github.com/badlogic/pi-mono), available as `pi` on `PATH` or configured with `emacs-pi-executable`
- `markdown-mode` 2.3 or later

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

Run `M-x emacs-pi-chat`, choose a project directory, then select a saved session or start a new one. Type in the `You>` input area and press `RET` to send. Enter `/` or `@` and press `TAB` to complete commands, files, and sessions.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Send prompt / insert newline | `RET` / `S-RET` |
| Steer a running conversation | `C-c C-s` |
| Stop and clear queued prompts / abort the current run | `C-c C-k` / `M-x emacs-pi-abort-current` |
| Show and edit the prompt queue | `C-c C-l` |
| Resume a session / switch chat | `C-c C-r` / `C-c C-b` |
| Attach an image / open an image | `M-x emacs-pi-attach-image` / `C-c C-o` |
| Paste from the clipboard | `C-c C-p` (also `s-v` on macOS) |
| Browse prompt history | `M-p` / `M-n` |
| Focus the input area | `i` or `C-c C-i` |
| Close the chat / shut down its Pi process | `C-c C-q` / `M-x emacs-pi-shutdown` |

## Configuration

- `emacs-pi-executable` — Pi executable (default: `pi`)
- `emacs-pi-extra-arguments` — additional Pi RPC process arguments
- `emacs-pi-session-directory` — optional Pi session directory
- `emacs-pi-show-thinking` — show thinking text in the conversation

Image clipboard paste on macOS requires `pngpaste`. For queue editing behavior and its protocol constraints, see [docs/QUEUE.md](docs/QUEUE.md).
