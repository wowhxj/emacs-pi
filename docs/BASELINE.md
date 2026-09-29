# 证据、协议基线与验证边界

核对日期：2026-09-29。这里记录设计依据，不代表插件测试报告。

## 1. 本机基线

| 项目 | 实际读取/运行结果 |
|---|---|
| 仓库 | `/Users/randolph/sandbox/emacs-pi`，本轮开始时为空目录 |
| Emacs | `/opt/homebrew/bin/emacs`，GNU Emacs 32.0.50 |
| Pi | 0.87.1，包名 `@earendil-works/pi-coding-agent` |
| Pi 命令 | `/Users/randolph/.nvm/versions/node/v22.23.1/bin/pi` |
| Pi 安装包 | `/Users/randolph/.nvm/versions/node/v22.23.1/lib/node_modules/@earendil-works/pi-coding-agent` |
| emacs-dsh | `/Users/randolph/sandbox/emacs-dsh` |
| DSH 提交 | `c4e93e0695b9d701a24d6ec291f8c532f620d071` |
| DSH 规模 | 主文件 3,318 行；tests.el 2,142 行；97 个 ert-deftest 定义，未在本轮执行 |
| pimacs 安装 | `~/.emacs.d.default/elpa/pimacs-20260927.400` |
| pimacs 包提交 | 包元数据记录 `4daf8db7bc0e1a879f5d516eab649a489822eff9` |
| 用户配置 | `/Users/randolph/.emacs.d.default/emacs-config.org` 的 pimacs 段约 13516–14012 行 |

路径是本次取证位置，不得复制到插件默认值。其他环境需从实际 Pi 可执行程序定位安装文档。
本轮没有读取用户真实聊天历史或模型凭据来生成 fixtures。

## 2. 实际探测

在 Python TemporaryDirectory 中设置临时 `PI_CODING_AGENT_DIR`，关闭网络启动操作和资源发现：

```text
PI_OFFLINE=1
PI_TELEMETRY=0
pi --mode rpc --no-session --offline --no-extensions --no-skills
   --no-prompt-templates --no-themes --no-context-files --no-tools
```

通过 stdin 发四个带独立 id 的请求并解析 stdout，未发送普通 prompt、未调用模型：

| command | success | 观察到的 data keys |
|---|---|---|
| get_state | true | model, thinkingLevel, isStreaming, isCompacting, steeringMode, followUpMode, sessionId, autoCompactionEnabled, messageCount, pendingMessageCount |
| get_entries | true | entries, leafId |
| get_commands | true | commands |
| get_available_thinking_levels | true | levels |

额外观察：

- 使用 no-session 时 get_state 没有 sessionFile，客户端必须允许缺失。
- 尚未聊天的 get_entries 已非空，leafId 非 null；不要以 entries 空否判断有没有用户消息。
- 关闭 stdin 后进程 exit code=0，stderr 为 0 bytes。
- 以上证明基础查询和正常 EOF 可用；没有证明流式、模型、GUI、剪贴板或停止时序已经通过。

另执行 `pi --help` 核对参数时，普通用户配置发现路径产生过一条扩展诊断：
`[pi-web-access] Dynamic tool activation requires Pi 0.86.1 or newer; web tools remain eagerly available.`
该提示与 pi --version 的 0.87.1 并存；没有诊断其原因，不能据此声称版本过旧。
它说明版本/帮助探测也可能出现扩展日志，应分离 stdout/stderr 并保留必要诊断。

## 3. 从安装包源码确认的事实

优先级：实际安装包源码/类型与实际响应 → 同版本文档 → 上游 main（可能更新）。

| 事实 | 本机文件/定位 |
|---|---|
| 0.87.1 prompt/steer/follow_up 成功不要求 disposition | `dist/modes/rpc/rpc-types.d.ts` 的 RpcResponse；`rpc-mode.js` prompt 分支 |
| queue_update 是两组 string[] | `dist/core/agent-session.d.ts`，queue_update 类型 |
| get_state 不提供完整队列或 cwd | `dist/modes/rpc/rpc-mode.js` get_state 分支 |
| get_entries 返回全 append entries 和 leafId，可传 since | 同文件 get_entries 分支 |
| get_messages 返回 session.messages | 同文件 get_messages 分支；区别于全部 persisted entries |
| 自定义目录优先级为 CLI、env、settings | `dist/main.js` 约 520–540 行 |
| 初始 settings 合并项目覆盖全局 | `dist/core/settings-manager.js` create/fromStorageWithPaths/deepMergeSettings |
| settings 路径是 agent-dir/settings.json 和 cwd/.pi/settings.json | 同文件 FileSettingsStorage 构造函数 |
| 相对路径最终基于 process cwd；支持 ~/ 和 file URL | `dist/utils/paths.js` normalizePath/resolvePath；session-manager 使用处 |
| Pi 会持久化系统消息、元数据和分叉 | `docs/session-format.md` 与 `dist/core/session-manager.js` |

截至核对时，上游 main 的 prompt 响应文档已经包含 disposition；它不能作为 0.87.1 的必填字段。
设计兼容该新增字段，但没有把 main 的全部行为宣称为本机实测。

## 4. 用户现有实现带来的需求

| 来源 | 事实 | 设计决定 |
|---|---|---|
| org 的 unique-chat-key advice | 通过临时替换 md5 改变同目录实例复用 | client-id 独立于 root/name |
| org 的 null 参数修复 | 工具参数 null 曾导致数字格式化失败 | JSON null/false 明确定义，格式化前判类型 |
| org 的旧历史读取 override | 针对 pimacs--read-session-choice | 本包拥有独立只读索引，不依赖私有 reader |
| 当前磁盘 pimacs-session.el | 已使用 pimacs-session-read-record | 升级能改变私有函数，advice 不宜作为新包基础 |
| org 的 macOS/WSL 粘贴 | 文件优先、位图附件、文本回退 | 保留语义，改为异步 helper |
| org 的 @ 补全 | 需要 ~/、绝对路径、无项目回退 | 独立 CAPF category 与路径编解码 |
| DSH compose/markdown/fold | 已有用户喜欢的界面交互 | 按功能迁移，无运行时 DSH 依赖 |
| DSH inbox/control | 后端支持单项队列编辑 | 不向 Pi 虚构同等能力 |

这里确认的是磁盘代码；没有检查当前运行的用户 Emacs 是否还加载旧版 pimacs 定义。

## 5. 外部原始资料

- [Pi 官方仓库](https://github.com/earendil-works/pi)
- [RPC 模式](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md)
- [RPC 命令](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-commands.md)
- [事件流](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)
- [扩展 UI 协议](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-extension-ui.md)
- [消息类型](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/message-types.md)
- [会话文件格式](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md)
- [CLI 参数](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md)
- [RPC 类型源码](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/modes/rpc/rpc-types.ts)
- [pimacs](https://github.com/ananthakumaran/pimacs.el)
- [emacs-dsh](https://github.com/wowhxj/emacs-dsh)

这些是可变化的 main 链接。实施时将实际测试的包版本/提交写入 TEST-RESULTS，不能仅留一个 main URL。

## 6. 设计判断与事实的分界

下面属于本项目设计选择，并非 Pi 官方要求：

- 每活动聊天一个进程；新建总是新实例；resume 同文件跳到已活动实例。
- 使用 DSH 风格单 buffer；50ms 合并刷新；100 条 UI 历史分页。
- 8 个 Elisp 模块及其函数名、结构体和 callback 合同。
- @ 引用默认只附路径说明，图片用独立 images 字段。
- 发送超时保留 uncertain，不自动重发；停止全部串行 clear_queue/abort。
- 资源上限、索引扫描预算、性能目标和开发阶段。

## 7. 当前未验证

- emacs-pi 尚无实现，所有插件自动化/GUI/真实模型测试尚未执行。
- Emacs 29.1 兼容性尚未执行验证；本机仅观察到 32.0.50。
- macOS/WSL 实际剪贴板、输入法、图片显示尚未验证。
- 真实 provider 流式、工具、扩展问答、压缩/重试尚未作为本插件端到端运行。
- 超长会话和高频 delta 的性能数值是验收目标，尚无本插件实测数据。
