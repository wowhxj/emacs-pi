# 2026-09-29 预览版验证记录

环境：macOS；GNU Emacs 32.0.50；Pi 0.87.1；`markdown-mode` 20260827.909。

已通过：

- 5 个 ERT 用例：JSON false/null、活动分支、异常 JSONL 关闭、斜杠命令补全与拦截、同目录双会话及流式输出时保留草稿。
- 所有包源码使用 Emacs 批量编译并开启 `byte-compile-error-on-warn`，无警告。
- `test/smoke-real.el` 使用临时 Pi 数据目录完成真实 Pi 的 `get_state`/`get_entries` 离线握手，得到有效 session ID 与文件路径。该测试不调用模型。
- 隔离 GUI Emacs 进程中打开本仓库聊天，RPC 状态为 `ready`，显示当前 Pi 配置的模型与 thinking 级别。

尚未验证：真实模型回答和工具执行的完整 GUI 体验、长会话性能、Emacs 29.1、WSL、图片粘贴、扩展多行 editor、全部 113 项设计验收用例。当前发布应标为预览版。

`elisp-checker.sh` 的括号检查和编译阶段通过；其 `elisp-lint` 阶段仍报告大量仓库风格差异（缩进制表符、70 列、checkdoc），且该脚本在 lint 失败时仍打印 `OK`。因此没有把该脚本整体记为通过。
