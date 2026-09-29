# 2026-09-29 预览版验证记录

环境：macOS；GNU Emacs 32.0.50；Pi 0.87.1；`markdown-mode` 20260827.909。

已通过：

- 5 个 ERT 用例：JSON false/null、活动分支、异常 JSONL 关闭、斜杠命令补全与拦截、同目录双会话及流式输出时保留草稿。
- 所有包源码使用 Emacs 批量编译并开启 `byte-compile-error-on-warn`，无警告。
- `test/smoke-real.el` 使用临时 Pi 数据目录完成真实 Pi 的 `get_state`/`get_entries` 离线握手，得到有效 session ID 与文件路径。该测试不调用模型。
- 隔离 GUI Emacs 进程中打开本仓库聊天，RPC 状态为 `ready`，显示当前 Pi 配置的模型与 thinking 级别。

尚未验证：真实模型回答和工具执行的完整 GUI 体验、长会话性能、Emacs 29.1、WSL、图片粘贴、扩展多行 editor、全部 113 项设计验收用例。当前发布应标为预览版。

`elisp-checker.sh` 的括号检查和编译阶段通过；其 `elisp-lint` 阶段仍报告大量仓库风格差异（缩进制表符、70 列、checkdoc），且该脚本在 lint 失败时仍打印 `OK`。因此没有把该脚本整体记为通过。

## 0.2.0 交互改进

- 11 个 ERT 用例通过，新增输入区导航和底色、过程与工具步骤折叠及重绘保留、mode-line 与 context 栏、F6 新建/恢复选择、历史元数据和工具结果解析。
- 所有插件源码在 `byte-compile-error-on-warn` 下编译通过；`git diff --check` 通过。
- 真实 Pi 离线握手及 `get_session_stats` 请求通过；未通过该 smoke 发送模型提示词。
- 独立 GUI Emacs 恢复本机真实 Pi 会话：43 条消息，35 个默认收起的过程/步骤；顶部读到 `70.6k/1.0M`，mode-line 显示 `Pi idle`，输入底色存在。此项只验证恢复与界面呈现，未在该窗口发送新模型请求。
- `elisp-checker.sh` 的结构与编译阶段通过；lint 仍有现有风格规则差异，未记作整体通过。
