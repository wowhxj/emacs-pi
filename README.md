# emacs-pi

在 Emacs 中使用 [Pi Coding Agent](https://github.com/badlogic/pi-mono) 的原生单缓冲区聊天界面。每个聊天对应独立的 `pi --mode rpc` 进程；同一项目可以同时打开多个聊天。

**当前为可试用预览版（0.2.7）**：新建与恢复会话、流式消息、输入草稿、模型与 thinking 选择、发现 Pi 扩展命令、图片附件和基本队列操作可用。已有本机 Emacs 32 与 Pi 0.87.1 的自动化和离线握手验证；尚未完成真实模型长会话、Emacs 29.1、跨平台剪贴板和全部[验收矩阵](docs/ACCEPTANCE.md)，请按预览版使用。

## 立即试用

先安装 Pi，并在普通 `pi` 命令中完成模型与账号配置。Emacs 需要 29.1 或更新版本，以及 `markdown-mode` 包。

本地源码试用（在您的 Emacs 配置中）：

```elisp
(add-to-list 'load-path "/Users/randolph/sandbox/emacs-pi")
(require 'emacs-pi)
;; 如果 GUI Emacs 的 PATH 找不到 pi，设置绝对路径：
(setq emacs-pi-executable "/Users/randolph/.nvm/versions/node/v22.23.1/bin/pi")
(global-set-key (kbd "<f6>") #'emacs-pi-chat)
```

然后 `M-x emacs-pi-chat`（或 `F6`），选择项目目录，再从该目录的会话列表中选择已有会话或 `[New session]`。聊天会占满当前 frame 的编辑区。在底部有底色的 `You>` 输入区按 `RET` 发送。也可以通过 Emacs 29.1+ 的 `package-vc-install` 安装远端仓库，或使用如下 `use-package` 配置：

```elisp
(use-package emacs-pi
  :load-path "/Users/randolph/sandbox/emacs-pi"
  :commands (emacs-pi-chat emacs-pi-resume)
  :bind ("<f6>" . emacs-pi-chat)
  :custom
  (emacs-pi-executable "/Users/randolph/.nvm/versions/node/v22.23.1/bin/pi"))
```

## 常用操作

| 操作 | 按键或命令 |
| --- | --- |
| 发送 / 换行 | `RET` / `S-RET` |
| 运行中追加 follow-up / 转向 | `RET` / `C-c C-s` |
| 停止并清队列 / 仅中止当前运行 | `C-c C-k` / `M-x emacs-pi-abort-current` |
| 查看 steer / follow-up 队列 | `C-c C-l` 或 `/queue` |
| 恢复历史 / 切换活动聊天 | `C-c C-r` / `C-c C-b` |
| 关闭聊天（结束进程并移除 buffer） / 只关闭进程 | `C-c C-q` / `M-x emacs-pi-shutdown` |
| 历史输入 / minibuffer 补全 | `M-p`、`M-n` / `TAB` 或 `M-TAB` |
| 从历史跳至输入区 / 输入行行首 | `i` / `C-a` |
| 展开或收起过程与工具步骤 | 光标位于标题时 `RET`、`TAB` 或点击 |
| 粘贴图片或文字 / 添加图片文件 | `s-v`（macOS Command-V）或 `C-c C-p` / `M-x emacs-pi-attach-image` |
| 插入文件路径 | `M-x emacs-pi-insert-file` |
| 取回发送失败或停止后清除的文本 | `M-x emacs-pi-recover-input` |

在输入区键入 `/` 或 `@` 后按 `TAB`，会打开 Emacs 的 minibuffer 候选列表。安装了 Vertico、Orderless 等包时沿用现有补全配置；没有安装时也可以直接用 Emacs 原生补全，并支持按子串查找。`/` 列出客户端命令及 Pi 通过 `get_commands` 提供的扩展、skill 和模板命令；未发现的 `/xxx` 不会被误发给模型。`@` 列出项目文件、附近文件及已保存的 Pi session。候选中的 `[file]`、`[directory]`、`[session]` 用于区分类型。

顶部显示当前上下文用量与窗口上限、模型和 thinking 级别；普通 mode-line 显示运行状态和正在执行的工具。Pi 尚未报告有效上下文用量时显示 `context: —`。历史记录中的 `You:` 消息整行使用主题 `warning` 颜色高亮，底部 `You>` 输入区保持灰色。Pi 运行时当前回合的顶层 Process 自动展开，各工具和 thinking 步骤仍折叠；手动切换折叠状态后，流式重绘会保留选择。Pi 结束时整个 Process 与步骤自动收起，保留最终回答。步骤之间不留空行。`C-c C-r` 显示带时间、会话 ID、目录和提示词的全局会话列表。

mode-line 在队列非空时显示 `[S1 F2]` 一类提示，分别表示 steer 和 follow-up 数量。`C-c C-l` 打开会随 Pi 队列事件刷新的只读列表；本次 Emacs 会话中发送且仍能对应到队列文本的图片会显示缩略图或文件名。重复文本、Pi 输入扩展改写文本等情况无法可靠关联图片。`C-c C-k` 清队列后的草稿恢复会尽量带回已关联图片。当前 Pi 0.87.1 RPC 没有单条队列修改接口，不能安全实现编辑、排序、升降级或图片替换；所需协议和预期按键见 [队列设计](docs/QUEUE.md)。

`@path` 目前是给 Pi 的**路径提示**，不会把文件内容自动作为附件读取。选择 session 后，输入区会插入简短的 `@[标题](pi-session:ID)`；发送时客户端从该 session 的本地 JSONL 文件读取当前分支的用户与 Pi 对话，附加到发给 Pi 的消息中。历史界面仍只显示简短引用；附加内容会保存在 Pi 的会话历史里。默认最多附加约 32,000 字符，可通过 `emacs-pi-session-reference-max-chars` 调整。缺失或不可读的 session 会报错并保留草稿。PNG/JPEG 图片可通过 `emacs-pi-attach-image` 添加；macOS 剪贴板图片可用 `s-v` 或 `C-c C-p` 粘贴，需要本机安装 `pngpaste`。GUI Emacs 找不到它时可设置 `emacs-pi-pngpaste-executable` 为绝对路径。普通文字粘贴仍进入 `You>` 输入区。`/queue` 展示 Pi 最近一次队列快照；停止时清除的文本可用 `emacs-pi-recover-input` 取回，图片不能从 Pi 返回的文本快照重建。

## 验证和开发

```sh
emacs -Q --batch -L . -L /path/to/markdown-mode \
  -l test/emacs-pi-test.el -f ert-run-tests-batch-and-exit
EMACS_PI_TEST_EXECUTABLE=/path/to/pi emacs -Q --batch -L . \
  -L /path/to/markdown-mode -l test/smoke-real.el
```

详细设计与后续工作见 [设计文档](docs/DESIGN.md)、[任务卡](docs/IMPLEMENTATION.md)、[验收矩阵](docs/ACCEPTANCE.md)。
