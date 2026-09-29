# emacs-pi

在 Emacs 中使用 [Pi Coding Agent](https://github.com/badlogic/pi-mono) 的原生单缓冲区聊天界面。每个聊天对应独立的 `pi --mode rpc` 进程；同一项目可以同时打开多个聊天。

**当前为可试用预览版（0.2.0）**：新建与恢复会话、流式消息、输入草稿、模型与 thinking 选择、发现 Pi 扩展命令、图片附件和基本队列操作可用。已有本机 Emacs 32 与 Pi 0.87.1 的自动化和离线握手验证；尚未完成真实模型长会话、Emacs 29.1、跨平台剪贴板和全部[验收矩阵](docs/ACCEPTANCE.md)，请按预览版使用。

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

然后 `M-x emacs-pi-chat`（或 `F6`），选择项目目录，再从该目录的会话列表中选择已有会话或 `[New session]`。在底部有底色的 `You>` 输入区按 `RET` 发送。也可以通过 Emacs 29.1+ 的 `package-vc-install` 安装远端仓库，或使用如下 `use-package` 配置：

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
| 恢复历史 / 切换活动聊天 | `C-c C-r` / `C-c C-b` |
| 隐藏聊天（进程仍运行） / 关闭进程 | `C-c C-q` / `M-x emacs-pi-shutdown` |
| 历史输入 / 补全 | `M-p`、`M-n` / `TAB` |
| 从历史跳至输入区 / 输入行行首 | `i` / `C-a` |
| 展开或收起过程与工具步骤 | 光标位于标题时 `RET`、`TAB` 或点击 |
| 添加图片 / 插入文件路径 | `M-x emacs-pi-attach-image` / `M-x emacs-pi-insert-file` |
| 取回发送失败或停止后清除的文本 | `M-x emacs-pi-recover-input` |

输入 `/help` 可查看客户端命令；`/model`、`/thinking`、`/queue`、`/new`、`/resume` 等也可直接在输入框使用。Pi 扩展、skill 和模板命令通过 `get_commands` 发现，按 `TAB` 补全；未发现的 `/xxx` 不会被误发给模型。

顶部显示当前上下文用量与窗口上限、模型和 thinking 级别；普通 mode-line 显示运行状态和正在执行的工具。Pi 尚未报告有效上下文用量时显示 `context: —`。完成的回合会把中间过程收起，保留最终回答；展开过程后可继续展开各个工具或 thinking 步骤。`C-c C-r` 显示带时间、会话 ID、目录和提示词的全局会话列表。

`@path` 目前是给 Pi 的**路径提示**，不会把文件内容自动作为附件读取。PNG/JPEG 图片需通过 `emacs-pi-attach-image` 添加。`/queue` 展示 Pi 最近一次队列快照；停止时清除的文本可用 `emacs-pi-recover-input` 取回，图片不能从 Pi 返回的文本快照重建。

## 验证和开发

```sh
emacs -Q --batch -L . -L /path/to/markdown-mode \
  -l test/emacs-pi-test.el -f ert-run-tests-batch-and-exit
EMACS_PI_TEST_EXECUTABLE=/path/to/pi emacs -Q --batch -L . \
  -L /path/to/markdown-mode -l test/smoke-real.el
```

详细设计与后续工作见 [设计文档](docs/DESIGN.md)、[任务卡](docs/IMPLEMENTATION.md)、[验收矩阵](docs/ACCEPTANCE.md)。
