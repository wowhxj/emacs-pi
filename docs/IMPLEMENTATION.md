# 实施任务与开工顺序

本文件中的任务全部处于未开始状态。不得把“设计过”勾选成“已实现”。
行为和接口以 [DESIGN](DESIGN.md) 为准；用例 ID 见 [ACCEPTANCE](ACCEPTANCE.md)。

## 1. 阶段与门槛

| 阶段 | 任务 | 阶段结束时能做什么 |
|---|---|---|
| A 最小闭环 | T01–T04 | 用假 RPC 和真实离线 RPC启动两聊天、发送、显示流式文本、停止；基础输入不损坏 |
| B 可读可恢复 | T05–T07 | DSH 风格过程显示、历史索引与恢复、模型和命令选择 |
| C 日常输入 | T08–T11 | 文件、图片、剪贴板、队列与失败恢复、扩展交互 |
| D 可靠交付 | T12–T14 | 生命周期和性能回归、跨版本验证、安装文档与人工验收 |

每阶段都留可加载状态。测试失败先修再进入依赖它的任务。
T04 的简化显示可在 T05 扩展；不是先造一个最终要丢弃的终端封装。
不要只完成阶段 A 就报告“插件开发完成”。

## 2. 预期目录

```text
emacs-pi/
  README.md                    最终更新为安装、使用、限制说明
  README.zh-CN.md               发布阶段可拆出详细中文使用指南
  HANDOFF.md
  emacs-pi.el
  emacs-pi-core.el
  emacs-pi-rpc.el
  emacs-pi-session.el
  emacs-pi-history.el
  emacs-pi-ui.el
  emacs-pi-input.el
  emacs-pi-extension.el
  Makefile
  LICENSE
  CHANGELOG.md
  .gitignore
  test/
    run-tests.el               加载路径和测试入口
    emacs-pi-core-test.el
    emacs-pi-rpc-test.el
    emacs-pi-session-test.el
    emacs-pi-history-test.el
    emacs-pi-ui-test.el
    emacs-pi-input-test.el
    emacs-pi-extension-test.el
    fake-pi.py                 仅测试依赖 Python 3，插件运行不依赖它
    fixtures/                 合成/去敏 JSONL 与 JSON 场景
  scripts/
    smoke-rpc.py               无模型的真实 RPC 验证
  docs/
    DESIGN.md
    IMPLEMENTATION.md
    ACCEPTANCE.md
    BASELINE.md
    PROGRESS.md                实施时建立
    TEST-RESULTS.md            实施时填入真实结果
```

文件按任务实际需要创建。不得先建一批全是 TODO 的实现文件冒充完成。
如仓库尚未初始化 Git，普通初始化是实施准备；不自动连接远端或发布。

## 3. 任务卡

### T01 — 包骨架与纯数据合同

前置：读完所有设计；检查工作树已有文件。

交付：core、入口最小包头、test/run-tests.el、Makefile、.gitignore。

步骤：
1. 确认最低 Emacs 29.1 API，避免直接使用只在 30/31/32 存在的宏。
2. 实现 DESIGN §3 的结构体、JSON 帮助函数和实例 ID。
3. 建立 buffer-local session 引用与 client-id 注册表；根目录只作属性。
4. 接口参数使用 cl-defun/普通 defun，写明 callback/error 合同。
5. 配置 `make test`、`make compile`；测试不加载用户 init。

验收：C01–C04；batch require 成功；source 与 bytecode 两种载入方式都能找到所有 feature。
不做：启动真实 Pi、复杂 UI、读取真实用户会话。

### T02 — 可控假 RPC 与通信模块

前置：T01。

交付：rpc 模块、fake-pi.py、transport fixtures 和 ERT。

步骤：
1. fake-pi 用 Python 标准库，支持由 fixture 控制分片、延迟、乱序响应、stderr、退出码。
2. 使用 binary stdout 按指定 bytes 分片，覆盖中文 UTF-8 字符内部断开。
3. 实现 make-process、独立 stderr、receive-buffer、LF 分帧和调度预算。
4. 实现 request 表、唯一 ID、注册后发送、结果结算、超时与清理。
5. 实现 generation 检查与幂等 close。
6. 为 fake-pi 设定有界运行时；测试 teardown 清理全部子进程和 timer。

验收：R01–R12。响应乱序、callback 抛错、超时晚响应不能污染其他请求。
不做：在 filter 内聊天排版、弹窗、同步 accept-process-output 等待模型。

### T03 — 会话状态与协议事件

前置：T02。

交付：session 模块、事件 fixtures、纯状态和回放测试。

步骤：
1. 实现 starting/syncing/ready/dead 的初始化和必要请求顺序。
   同时在 history 模块实现最小 active-branch 纯函数，供握手 get_entries 使用；T06 再加入索引/分页，不引入悬空 require。
2. 实现 DESIGN §5 事件映射；先支持文字、工具、queue、retry/compaction 状态。
3. 实现 contentIndex 块重建与最终 message 替换。
4. 实现 toolCallId 合并，避免 end 事件和 toolResult 双重显示。
5. 实现 prompt 接受和 run-active 分离，兼容无 disposition 的响应。
6. 加入 event-revision，使过时快照不覆盖新事件。
7. on-change 暂时由测试收集，验证 session 不依赖任何 UI buffer。

验收：S01–S10；ACCEPTANCE §3 的合成正常场景和重试场景。
不做：把 `agent_end.messages` 全部再追加、用时间戳当消息唯一 ID。

### T04 — 最小单 buffer 对话

前置：T03。

交付：基础 UI/input、chat/send/steer/stop/shutdown 命令、简单状态栏。

步骤：
1. 建历史只读区和 editable-field，初期纯文本显示即可。
2. 建用户动作回调，所有提交通过 session-submit。
3. 实现发送快照、清空后的 revision、明确失败恢复、未知结果 recovery。
4. 实现 normal idle/busy 的发送选择与两种停止语义。
5. 同目录启动两个实例，分别绑定 process、draft、message、callback。
6. 用 fake-pi 端到端测试；另用隔离配置跑真实 Pi get_state/get_entries，不调用模型。

验收：U01–U05、I01–I04、Q03–Q04、L01；A 阶段可演示最小闭环。
不做：替换用户 F6、修改真实配置、自动继续发送失败 prompt。

### T05 — DSH 风格排版与过程折叠

前置：T04。

交付：Markdown、工具卡片、thinking、分组折叠、顶部状态与流式合并刷新。

步骤：
1. 按 §4 复用地图迁移 DSH 的 faces、Markdown 和 folding 思路，去掉 DSH 协议字段。
2. 消息文字必须真实存在于 buffer；流式输出不只依赖 before-string。
3. 以 50ms 合并刷新，message_end 后进行 Markdown 排版。
4. 工具参数通用 JSON 格式化，null/false/未知类型不导致 format 异常。
5. 实现每消息、每工具稳定区域；刷新保存 point/mark/window-start。
6. 默认折叠过程，最后有正文的回复展开；所有用户消息可见。
7. tab-line、header-line 和 mode-line 分工，百分号安全。

验收：U06–U12、P01–P03；手动初看后再做样式调整，优先保证文字可复制和输入稳定。
不做：整 buffer 每 token 重绘、自制完整 Markdown parser、写死主题背景色。

### T06 — 历史索引、活动分支与恢复

前置：T03、T05。

交付：history 模块、resume/switch-chat/new-session/restart、历史分页。

步骤：
1. 实现 DESIGN §6.2 的存储目录解析，含有效子进程环境覆盖。
2. 分块解析 JSONL，完整行解码；前向找预览，后向找最新名称。
3. 构造索引缓存和可取消分批扫描；预算耗尽显示缺省标题，不显示 nil。
4. 实现 active-branch 纯函数，处理 null leaf、缺父、环和分叉。
5. 恢复时以 header cwd 启动 `--session ABSOLUTE-PATH`，已有相同活动文件则跳转。
6. 初次 get_entries 全量、UI 100 条分页；settled 后 since 增量，同步游标与 leaf 分开。
7. 重建 transcript 保存草稿、附件、阅读锚点、折叠状态。
8. 历史目录缺失显示空列表；会话 cwd 已不存在显示原因，不自动改到当前目录继续执行。

验收：H01–H12、L02–L04；用合成 session 文件，禁止拿真实历史作为公开 fixture。
不做：按 append 顺序显示全部分支、用 get_messages 冒充完整历史、自动删除空会话。

### T07 — 模型、thinking 与 slash 命令

前置：T04、T06。

交付：模型/级别选择、get_commands 缓存、客户端命令路由和帮助。

步骤：
1. `get_available_models` 取 provider/id，展示候选；set_model 发送 modelId，不发 label。
2. 模型改变后重新获取 get_state、thinking levels、stats；不能继续使用旧模型级别。
3. thinking 级别来自 get_available_thinking_levels，取消选择不改变任何状态。
4. 在输入首 token 识别客户端命令；`/reasoning` 作为 `/thinking` 别名。
5. 保留 get_commands 的 skill: 前缀与扩展名称；同名冲突用直接服务端命令选择器解决。
6. 命令失败、取消、附带附件均保护草稿；busy 禁止配置切换。

验收：M01–M06；`/settings` 等 TUI 命令不能误当作已支持命令。
不做：`/permission`、在代码里维护固定模型名单、读取或展示 provider secret。

### T08 — CAPF 与路径引用

前置：T07。

交付：@ 和 / 补全、insert-file、路径 token 编解码与发送引用说明。

步骤：
1. CAPF 的起止边界只覆盖当前 token；引用解析与生成共享编解码函数。
2. 支持裸路径、JSON quoted 路径、~/、绝对、相对、中文、空格、引号和反斜杠。
3. project-files 有缓存；无 project 时文件系统补全不中断。
4. 发送仅附规范化路径文本；不自动读文件全文；input history 保存原始草稿。
5. 忽略邮箱和 fenced code 内的 @；不吞掉无法识别的文本。
6. 独立 completion category，不修改用户全局补全设置。

验收：F01–F06；真实目录测试只在临时目录生成，包含空格/中文文件名。
不做：DSH 跨会话引用、把 @ 参数附到 RPC CLI、隐式转成图片附件。

### T09 — 图片与跨平台粘贴

前置：T08。

交付：attach-image、预览移除、发送图片、macOS/WSL helpers、普通文本回退。

步骤：
1. 附件 bytes 在 input 所有，发送生成无换行 base64；预览有独立 attachment-id。
2. 校验文件类型、单图/总量限制；终端不创建图形图片对象。
3. 将 DSH macOS/WSL helper 改为异步带超时；不复制同步 call-process 的阻塞流程。
4. 文件列表优先，其次位图，再回退开始时的文本快照。
5. helper 返回时检查 generation/revision，用户已继续输入则不突然改草稿。
6. 全部成功/失败/取消路径清理自建 temp 文件；不删除源文件。

验收：A01–A08；macOS/WSL mock 通过与实际系统验证分别记录。
不做：对未知二进制按 UTF-8 读写、用文件扩展名单独认定 MIME、图片丢失后默默发送纯文字。

### T10 — 队列与恢复内容交互

前置：T04、T09。

交付：queue buffer、clear-all、recovery buffer、停止后的草稿取回。

步骤：
1. 队列视图仅展示 Pi 快照，标题标明 steering/follow-up；没有详情时显示 pending count。
2. 提供复制文本、清空全部；禁止借用 DSH 单项 ID 编辑算法。
3. 显示 sending、accepted、uncertain 状态；recovery 中按 submission-id 关联附件。
4. 恢复内容到当前草稿时检测非空，允许追加或取消。
5. clear_queue 返回文本与本地快照分别保留，不承诺从字符串反推出附件关联。
6. clear + abort 串行；任何失败都保留可操作诊断，不虚报“全部停止”。

验收：Q01–Q06、I05–I08；高频发送、双击和停止期间输入不产生重复提交。
不做：文本相同即视为同一消息、无条件恢复到输入框、伪造服务端逐条编辑能力。

### T11 — 扩展问答与通知

前置：T04、T09。

交付：extension 模块、全局对话队列、多行 editor、状态/widget 映射。

步骤：
1. request key 使用实例/代次/id；filter 只入队，timer 驱动 UI。
2. select/confirm/input/editor 的结果按协议构造，不进入普通 pending 表。
3. 确认否定用 JSON false，C-g 用 cancelled=true，input 空字符串是有效结果。
4. 多会话问题串行，已有 minibuffer 时等待。
5. timeout 到期、取消、提交、进程死亡竞争时只完成一次。
6. notify/status/widget/title/set_editor_text 是非阻塞更新，保护用户已有草稿。

验收：E01–E08；用假 RPC 加模拟交互测试，再用自建无模型 demo extension 做真实 RPC 验证。
不做：TUI custom() 仿真、自动同意 confirm、未知问题返回允许值。

### T12 — 生命周期、边界和性能

前置：T05–T11。

交付：退出/restart 回归、长会话与吞吐基准、资源清理审计。

步骤：
1. 遍历全部 timer/process/overlay/listener 的所有者与清理入口。
2. 旧进程晚事件、过期选择器、buffer 已 kill 等路径不报未捕获错误。
3. 用户阅读历史时不抢滚动；输入 undo 与选区在持续输出下正常。
4. 模拟 1,000 条消息、10,000 个 delta 和大工具输出，记录耗时/刷新次数。
5. 检查 receive-buffer 和 debug buffer 有界；关闭实例后不残留活动 timer/process。
6. 核对 Emacs 29.1 API；在可用的最低版本环境运行测试，不以本机 32 代替。

验收：L01–L08、P01–P05；性能目标未达标则报告真实数据并修复，不能直接删测试。

### T13 — 真实 Pi 与 GUI 验收

前置：T12。

交付：scripts/smoke-rpc.py、TEST-RESULTS 记录、界面截图（若可用）。

步骤：
1. 离线 smoke 全程使用临时 PI_CODING_AGENT_DIR，关闭自动资源发现，不发送普通模型 prompt。
2. 验证 get_state/get_entries/get_commands/levels、EOF、两进程不同 session-id。
3. 自建测试 extension 提供不调用模型的 echo 和 confirm 命令，验证立即处理及问答恢复。
4. 在 GUI Emacs 中跑 ACCEPTANCE §5 的人工路径。
5. 有模型测试授权/可用环境时做小任务真实 smoke；使用临时项目，不改用户代码。
6. 平台不具备时标记未验证，不把 mock 结果写成该平台实际通过。

验收：O01–O04、人工清单；无真实模型验证只能称预览版。

### T14 — 文档、安装和交付

前置：T13 或明确记录尚未验证的预览版限制。

交付：使用 README、包元数据、LICENSE、CHANGELOG、最终验证记录。

步骤：
1. README 给 package-vc 与源码 load-path 安装；仓库 URL 未建立时只给真实可用的本地方式。
2. 展示 use-package 配置示例，但不代替用户修改配置。
3. 说明 quit 隐藏与 shutdown 的区别、@ 路径语义、队列限制、TUI 扩展限制。
4. 说明先在普通 Pi 配好模型/登录，GUI PATH 找不到 Pi 时如何配置绝对路径。
5. 更新兼容矩阵和测试结果，不写未运行的命令输出。
6. 核对复制代码来源和许可声明；删除临时 debug 产物，不删除用户数据。
7. 将 README 的“仅设计”状态改为实际阶段；PROGRESS 中所有勾选可追溯到测试结果。

目标包许可采用 GPL-3.0-or-later；复制外部代码时逐段核对来源与兼容性，保留原许可和版权声明。
无法确认来源的片段重新实现，不能删除原声明后当作原创代码。

验收：D01–D04；交付说明列出已实现功能、测试、限制，不使用“全平台可用”等无证据措辞。

## 4. emacs-dsh 复用地图

参考基线提交：`c4e93e0695b9d701a24d6ec291f8c532f620d071`。
路径：`/Users/randolph/sandbox/emacs-dsh/emacs-dsh.el`。
行号可能变化，应以函数名搜索。复制后去掉原前缀并改为 DESIGN 接口，不能只用全局文本替换。

| 原函数/区域 | 可带走的设计 | 必须调整的地方 |
|---|---|---|
| `--compose`、`--input-widget`、`--replace-draft` | widget、输入边界、背景 | 接入 draft revision；避免输出重建 widget |
| `--history-move` | 上下翻输入历史、恢复未发送内容 | 同时保护附件 |
| `--markdown-text`、`--linkify-markdown` | 原字符保留与字体化 | 新 faces；只允许已支持链接动作 |
| `--make-step`、`--make-tool-card`、`--fold-process` | 工具单行摘要与多层折叠 | 使用 Pi toolCallId；用户组与 turn 语义重新实现 |
| `--turn-rule` | GUI/终端分隔线 | 尺寸变化、窗口宽度回归 |
| `--header`、`--pinned-prompt`、`--state` | 三种状态行分工 | 去掉 permission/preset；使用 Pi stats |
| `--update-image-preview`、`--stage-image` | 图片缩略图与移除 | attachment-id，bytes 与编码分离 |
| `--macos-*`、`--wsl-*` | 剪贴板格式、路径转换经验 | 改异步与超时；不继承 Desktop Host 路径假设 |
| `--submit-prompt` | 发送前保留快照的思路 | 更严格的 uncertain、revision、恢复流程 |
| tests 的 Markdown/widget/tool/image 场景 | 可复用用户行为断言 | 测试新公开接口，不直接绑定旧实现 |

不迁移：HTTP cookie/token、managed web host、bridge、WebSocket、DSH inbox/control、跨会话引用、preset/permission。

## 5. 测试运行合同

T01 实现以下 Makefile 目标，之后每张任务卡沿用：

```sh
make test EMACS=/path/to/emacs MARKDOWN_MODE_DIR=/path/to/markdown-mode
make compile EMACS=/path/to/emacs MARKDOWN_MODE_DIR=/path/to/markdown-mode
make smoke PI=/path/to/pi
```

test 等价于：`emacs -Q --batch`，显式加入项目和 markdown-mode 的 load-path，载入 test/run-tests.el 后执行 ERT。
run-tests.el 只加载 test 目录以 `-test.el` 结尾的文件，不扫描用户配置。
compile 在明确顺序中编译各模块，启用 warnings-as-errors；不得以旧 .elc 隐藏新源码错误。
smoke 使用 Python 3 标准库，不需要 npm install；不把模型凭据打到输出。
开发编译缓存可以放仓库内临时目录；说明清理方式，确保源代码验证与 bytecode 验证可分别运行。

## 6. 发生差异时如何处理

- 协议响应不同：先保存去敏最小样例，更新 BASELINE，再修改 adapter 和回归。
- 版本较旧：报告最低要求，不用新命令失败后假装成功。
- 某工具无特定 renderer：使用通用 JSON/text 卡片，不阻塞整个任务。
- GUI 不可用：继续完成离线实现与测试，交付时明确剩余人工验收。
- 只有终端 Emacs：完成文字模式测试，不宣称图片/鼠标验收通过。
- 模型调用不可用：不伪造真实响应，用 fixtures 完成可做工作并标记 real-model 未验证。
