# emacs-pi

[English](README.md) | 简体中文

开发中：[会话枚举与指定恢复接口](docs/PUBLIC-API.md)，含回调契约及当前未验证限制。

[emacs-pi](https://github.com/wowhxj/emacs-pi) 是 [Pi Coding Agent](https://github.com/badlogic/pi-mono) 的 Emacs 原生聊天界面。每个聊天使用独立的 Pi RPC 进程，因此可以同时打开多个项目会话。

## 功能

- 在单个 Emacs buffer 中流式显示回复、thinking 和工具活动。
- 新建、恢复和切换 Pi 会话。
- 选择可用模型与 thinking 级别，发现 Pi 扩展命令。
- 排队发送后续消息或 steer 正在运行的对话，并查看、编辑队列。
- 添加 PNG/JPEG 图片、粘贴剪贴板图片，并使用外部程序打开收到的图片。
- 在输入区补全 slash 命令、项目文件和已保存会话。`@` 补全文件与目录，`@session` 打开历史会话选择器，按列对齐显示「最后交互（本地时间）｜用户首句｜用户末句｜项目｜短 ID」，按最后一次用户发消息的时间倒序排列。窄窗口自动隐藏项目列；未知时间显示 `—`，不会拿助手回复或文件修改时间代替，也不再显示 `Untitled` 占位标题。

## 环境要求

- Emacs 29.1 或更新版本
- [Pi Coding Agent](https://github.com/badlogic/pi-mono)：命令 `pi` 位于 `PATH` 中，或通过 `emacs-pi-executable` 指定路径
- `markdown-mode` 2.3 或更新版本

## 安装

在 Emacs 29.1 或更新版本中从 GitHub 安装：

```elisp
(package-vc-install "https://github.com/wowhxj/emacs-pi")
```

也可以克隆仓库并加入 `load-path`：

```elisp
(add-to-list 'load-path "/path/to/emacs-pi")
(require 'emacs-pi)
```

可选配置快捷键和 Pi 可执行文件路径：

```elisp
(use-package emacs-pi
  :commands (emacs-pi-chat emacs-pi-resume)
  :bind ("<f6>" . emacs-pi-chat)
  :custom
  (emacs-pi-executable "pi"))
```

如果 Emacs 的 `PATH` 中找不到 `pi`，请将 `emacs-pi-executable` 设为其绝对路径。

## 开始使用

运行 `M-x emacs-pi-chat`，选择项目目录，再选择已有会话或新建会话。在底部 `You>` 输入区输入消息并按 `RET` 发送。输入 `/` 或 `@` 后按 `TAB`，可补全命令和路径；选中目录后按 `RET` 将其插入输入区，再按 `TAB` 可继续补全子目录。输入 `@session` 后按 `TAB`，可单独选择历史会话并插入对话引用。

`/compact [instructions]` 通过 Pi RPC 压缩当前上下文。slash 选择器、补全、派发和 `/help` 共用客户端命令注册表，并动态包含 RPC 发现的扩展、模板和 skills。RPC 无法提供完整交互流程的 Pi CLI 命令不会在 Emacs 中提供。

## 常用快捷键

| 操作 | 快捷键 |
| --- | --- |
| 发送消息 / 插入换行 | `RET` / `S-RET` |
| steer 正在运行的对话 | `C-c C-s` |
| 停止并清空排队消息 / 仅中止当前运行 | `C-c C-k` / `M-x emacs-pi-abort-current` |
| 查看和编辑消息队列 | `C-c C-l` / `C-c C-u` |
| 恢复会话 / 切换聊天 | `C-c C-r` / `C-c C-b` |
| 添加图片 / 打开图片 | `M-x emacs-pi-attach-image` / `C-c C-o` |
| 粘贴剪贴板内容 | `C-c C-p`（macOS 也可用 `s-v`） |
| 浏览输入历史 | `M-p` / `M-n` |
| 进入复制模式 / 返回输入区（semi-char mode） | `C-c C-t` / `C-c C-j` |
| 聚焦输入区 | `C-c C-i` |
| 关闭聊天 / 关闭其 Pi 进程 | `C-c C-q` / `M-x emacs-pi-shutdown` |

## 配置

- `emacs-pi-executable`：Pi 可执行文件路径，默认 `pi`
- `emacs-pi-startup-timeout`：等待 Pi 首次 RPC 回复的秒数，默认 90
- `emacs-pi-extra-arguments`：传给 Pi RPC 进程的额外参数
- `emacs-pi-session-directory`：可选的 Pi 会话目录
- `emacs-pi-show-thinking`：是否在对话中显示 thinking 文本

macOS 剪贴板图片粘贴需要安装 `pngpaste`。队列编辑行为及协议限制见[队列说明](docs/QUEUE.md)。
