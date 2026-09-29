# 验收矩阵与测试样例

本文件是未来实现的验收合同，**不是已通过测试报告**。
当前完成的是设计审查和 BASELINE 中四项离线 RPC 探测。

## 1. 测试层次

| 层次 | 使用什么 | 证明什么 | 不能证明什么 |
|---|---|---|---|
| 纯数据 ERT | 合成 JSON、状态对象 | 分帧以外的解析、状态、分支逻辑 | 真正的进程 I/O |
| 假 RPC 集成 | test/fake-pi.py 子进程 | 分片、响应顺序、超时、生命周期 | 当前 Pi 服务端是否完全一致 |
| 真实离线 RPC | 临时配置下的 Pi | 启动、查询、扩展往返、EOF | 模型输出和真实工具执行 |
| GUI 人工 | 用户目标 Emacs | 输入、窗口、主题、图片、剪贴板 | 其他 OS、其他 Emacs 版本 |
| 真实模型 smoke | 临时项目与已配置模型 | 一次端到端任务、工具、恢复 | 长期稳定性和全模型兼容 |

以下用例均为 v0.1 P0，除非标注 P1。不同平台人工用例只约束相应平台的支持声明。
测试应验证用户可观察行为和模块合同，不只是检查某个私有函数被调用一次。

## 2. 自动化验收矩阵

### 2.1 核心数据 C

| ID | 输入/操作 | 必须观察到 |
|---|---|---|
| C01 | 解析并编码 true/false/null/[]/{} | 类型分别保留，false 不被当作成功 |
| C02 | 两次同 root/name 创建实例 | client-id 不同；注册表有两项 |
| C03 | 数字字段为 null、缺失、字符串 | UI/摘要不触发 `%d` 类型错误，显示缺省值 |
| C04 | 读取未知字段、未知 role | 原始数据可保留；缺省显示可诊断，不崩溃 |

### 2.2 RPC 通信 R

| ID | 输入/操作 | 必须观察到 |
|---|---|---|
| R01 | 一条 JSON 拆成 1-byte chunks，含中文 | 恢复一条完整记录，文字不乱码 |
| R02 | 一次输出 100 条 JSONL，加最后半行 | 消费完整 100 条，半行保留后续拼接 |
| R03 | CRLF、文本内 U+2028/U+2029 | 仅 LF 分帧，不错误拆分 Unicode 字符 |
| R04 | 两请求 A/B，服务端先 B 后 A | 各自 callback 收到正确结果 |
| R05 | timeout 后到达成功 response | callback 总共一次，pending/timer 清理 |
| R06 | 第一 callback 主动抛错 | 后续响应继续分发，诊断记录首个错误 |
| R07 | stderr 写普通日志，stdout 合法 | stderr 独立收集，通信不受影响 |
| R08 | stdout 非法 JSON | 仅该连接协议失败，错误可见，不跳过后宣称完整历史 |
| R09 | record/backlog 超过测试设定上限 | 明确资源限制错误并关闭，不无界积压 |
| R10 | 进程带 pending 意外退出 | 请求各结算一次，mutating 标为 uncertain，timer 清零 |
| R11 | generation 更新后旧 response/event 到达 | 当前实例状态完全不改变 |
| R12 | argv 含空格目录/路径；生命周期冲突参数 | 正常路径作为单参数传入；冲突明确拒绝 |

### 2.3 消息状态 S

| ID | 输入/操作 | 必须观察到 |
|---|---|---|
| S01 | §3.1 的完整文本场景 | 一条 user、一条 assistant，最终 idle |
| S02 | text_delta 为 A/B，text_end 为 AB! | 显示 AB! 而不是 ABAB! |
| S03 | 两个 contentIndex 交替 delta | 块顺序与内容正确，不混在一起 |
| S04 | 工具声明、start/update/end、toolResult | 同 toolCallId 一张卡片、一个最终结果 |
| S05 | tool partialResult 连续为 a、ab | 通用展示为 ab，不能拼成 aab |
| S06 | agent_end 后 auto_retry_start，再一轮结束 | 中途不显示任务已结束；settled 才收尾 |
| S07 | compaction/retry 后 snapshot 到达 | 新运行标志不被旧 snapshot 覆盖 |
| S08 | message_end 完整但缺 start | 可恢复显示一条消息，有降级诊断 |
| S09 | success 无 data，无 agent_start 的扩展命令 | sending 解除，不永远 waiting/running |
| S10 | 较新 response 带 handled/queued/started | 兼容识别，不以响应当最终完成 |

### 2.4 输入与 UI U/I

| ID | 输入/操作 | 必须观察到 |
|---|---|---|
| U01 | 历史区键入，输入区键入 | 历史不可编辑，输入可多行 |
| U02 | RET、S-RET、C-c C-c | 发送/换行/发送分工正确，不双发 |
| U03 | 流式输出同时输入“下一条” | 文字、point、mark、输入边界不变 |
| U04 | 输入一段→流式刷新→undo | 只撤销用户输入，不撤销模型历史 |
| U05 | history 区 i、输入区 i、s-a | 聚焦/普通文字/只选草稿正确 |
| U06 | 标题、代码块、强调、链接 | 有 Markdown 样式，buffer 仍保留原字符 |
| U07 | 流式正文尚未结束时复制/搜索 | 能取得已显示的实际正文 |
| U08 | user prompt 含 `%s`、换行、中文 | 状态行安全显示，不当 format 指令 |
| U09 | 折叠工具、thinking、整体过程 | 用户消息和最后正文保持可见，可独立展开 |
| U10 | 最后一条 assistant 是 error/无正文 | 错误可见，不隐藏唯一有用回复 |
| U11 | 用户滚到历史；两个窗口看同 buffer | 不强制回底，每个窗口保持适当位置 |
| U12 | 工具结果超预览限制 | 有截断提示和完整结果入口，raw 未丢失 |
| I01 | 空文本、无附件发送 | 不发请求，草稿不变化 |
| I02 | prompt 被明确拒绝，之后未输入 | 原文字和附件自动恢复一次 |
| I03 | prompt 被拒绝，但已输入下一条 | 新草稿保留；旧内容进入 recovery |
| I04 | prompt 写出后 timeout | uncertain 提示，无自动重发、无正式用户消息伪造 |
| I05 | 相同文字连续发两次 | 分配不同 submission-id，不擅自去重 |
| I06 | 上翻历史再回末尾 | 原草稿及附件回来，不丢附件 |
| I07 | 恢复失败内容时当前草稿非空 | 可追加或取消，不能静默覆盖 |
| I08 | 用户编辑前后 revision 不同 | 只按正确 restore-revision 判断可自动恢复 |

### 2.5 历史 H

| ID | 输入/操作 | 必须观察到 |
|---|---|---|
| H01 | 新会话只有模型/thinking entries | 被视为无用户聊天，而非异常 |
| H02 | 第一个 system JSON >100 KiB，user 在后 | 预算内取得 user preview，无半行解析错误 |
| H03 | user 在第 25 行或更后 | 不因“前20行”限制丢失 |
| H04 | 超扫描预算或没有 user | 显示 ID/目录和预览不可用；不显示 nil |
| H05 | 名称在文件末尾 session_info 修改 | 使用最新完整名称，不只读开头 |
| H06 | UTF-8 字符跨块，最后半写入 JSON | 中文正确，尾行跳过且可诊断 |
| H07 | §3.2 分叉样例 | 只显示 leaf 活动链，最后 prompt 来自该链 |
| H08 | leaf=null、缺父、环 | 空链/结构化错误正确，不猜最后 entry |
| H09 | since 不是当前 leaf；新分支产生 | cursor 与 leaf 分离，分支切换显示正确 |
| H10 | since 不存在 | 全量重取一次，无无限重试 |
| H11 | 200+ 消息分页、刷新后继续输入 | 100 条逐页显示，草稿/附件/锚点保持 |
| H12 | config/env/目录覆盖、缓存更新/文件删除 | 与 DESIGN 目录优先级一致；不显示失效缓存 |

### 2.6 队列 Q、模型命令 M

| ID | 输入/操作 | 必须观察到 |
|---|---|---|
| Q01 | 两次 queue_update 完整快照 | 后一次替换前一次，无重复追加 |
| Q02 | 初次 get_state 只有 pending count | 显示数量及详情未知，不伪造文本/ID |
| Q03 | stop 全部，假进程记录命令 | clear_queue 响应成功后才发 abort |
| Q04 | clear_queue 明确失败 | 不报告全部停止，保留失败信息 |
| Q05 | 同时双击 stop、stop 期间继续输入 | 只有一套停止流程，草稿不受影响 |
| Q06 | 队列含重复文本或本地未知附件 | 不错误映射单项附件，不提供伪造 Edit/Delete |
| M01 | 两 provider 模型 label 相同 | 使用 provider+id 精确提交 |
| M02 | 换模型后可用 thinking 不同 | 重读 levels，不保留无效旧候选 |
| M03 | 用户取消模型/级别选择 | 不改变模型、不清草稿、不移除附件 |
| M04 | get_commands 包含 skill:review | 实际发送 /skill:review，保留前缀 |
| M05 | /settings 未发现、扩展 /model 同名 | 未知命令保留草稿；同名扩展可通过专门入口运行 |
| M06 | busy 改模型、/compact 带附件 | 禁止忙碌变更；未消费内容仍可恢复 |

### 2.7 路径 F、附件 A

| ID | 输入/操作 | 必须观察到 |
|---|---|---|
| F01 | @~/、绝对、相对、无 project | 对应目录候选出现，输入首字后不突然消失 |
| F02 | 空格/中文/引号/反斜杠文件名 | token 编解码 round-trip，得到原绝对路径 |
| F03 | 光标处补全、后面已有文本 | 只替换目标 token，尾部文字不丢 |
| F04 | 邮箱、代码块、无法解码 token | 不误展开、不删除原文字 |
| F05 | @文件与 @目录发送 | 只附路径说明，不读取全文、不走 CLI @参数 |
| F06 | 启用插件前后 completion-styles | 用户全局设置不改变 |
| A01 | PNG/JPEG、无文字仅图片 | images 正确，base64 无换行，允许提交 |
| A02 | 错误魔数、超单图/总量限制 | 提交前可见错误，附件不被默默丢弃 |
| A03 | 两张同名图片，点击一张 | 仅移除指定 attachment-id |
| A04 | 终端 Emacs 展示图片 | 文本占位，无 create-image 错误 |
| A05 | 文件列表和位图同时可读 | 文件列表优先，输出 @ 引用 |
| A06 | helper 超时/无图/转换失败 | 回退当时文本或明确错误，Emacs 可继续输入 |
| A07 | helper 完成前用户继续输入/kill buffer | 不插入过时结果，不报失效 buffer 错误 |
| A08 | WSL 路径转换、temp cleanup | 发送 Linux 路径，自建临时文件清理，源文件保留 |

### 2.8 扩展 E、生命周期 L

| ID | 输入/操作 | 必须观察到 |
|---|---|---|
| E01 | select 合法选项、input 空字符串 | 按原 request id 返回正确 value |
| E02 | confirm 是/否/C-g | true/false/cancelled 三者不同且正确 |
| E03 | editor 多行提交/取消 | 文本保留换行；取消只发 cancelled |
| E04 | 两实例同 request-id 同时提问 | 不串会话，只同时显示一个问题 |
| E05 | 排队问题超时、提交与超时竞态 | 过期不再展示/回复，最多一个完成路径 |
| E06 | 正在其他 minibuffer 时收到问题 | 不抢占递归提问，状态显示等待 |
| E07 | setStatus/widget 更新与清除 | key 定位正确，其他扩展状态不被清空 |
| E08 | set_editor_text 遇新草稿；进程退出 | 草稿保护；退出后旧请求不能回复新进程 |
| L01 | 同目录两会话交错输出和提问 | 各自历史、草稿、状态、进程完全隔离 |
| L02 | resume 同一已活动 session-file | 跳到原实例，不再启动写同文件进程 |
| L03 | restart，旧进程晚返回，用户已打草稿 | 新代次正确、草稿保留、没有自动重发 |
| L04 | 未落盘空会话 restart，cwd 被删除 | 清楚提示新建/不可恢复，不假装恢复成功 |
| L05 | kill buffer、shutdown、quit | 分别清资源/关进程留 buffer/只隐藏继续运行 |
| L06 | 启动程序不存在/非零退出/握手超时 | 可诊断状态，不留永远 loading |
| L07 | UI callback/hook 抛异常 | 其他会话继续运行；错误可见 |
| L08 | 全部聊天关闭后检查 timers/processes | 无本包活跃资源遗留，无持有死 buffer 的请求 |

### 2.9 性能 P、真实离线 O、文档 D

| ID | 输入/操作 | 必须观察到 |
|---|---|---|
| P01 | 1 秒内收到 1,000 小 delta | 正常流式刷新约不超过 20 次加边界强制刷新，不每 delta 重排 |
| P02 | 10,000 delta 中插入终结事件 | 全部正确消费；最终文本与 fixture 精确相同 |
| P03 | 输出时注入输入命令/timer | 参考机器目标输入延迟 <100ms；记录实测，不以 batch 测试冒充 GUI延迟 |
| P04 | 1,000 条历史、巨大工具输出 | 分页/截断可用，完整数据可访问，记录首屏耗时 |
| P05 | record/backlog 限制与退出重复 20 次 | 峰值有界；进程与 timer 数回到基线 |
| O01 | 真实 Pi 隔离配置查询四个接口 | 均成功，结果结构匹配本机协议 |
| O02 | 两离线 Pi 进程、stdin EOF | session-id 不同，正常退出，无孤儿进程 |
| O03 | 显式测试 extension echo，不调模型 | prompt 成功可无 run，不挂住 |
| O04 | 显式测试 extension confirm/input | UI request/response 往返正确，无模型调用 |
| D01 | 干净 Emacs -Q 按 README 源码安装 | 不需要用户 init、pimacs 或 DSH |
| D02 | 同时安装 pimacs/DSH 后加载本包 | 不改变其 keymap、全局配置或私有函数 |
| D03 | doctor/debug 输出检查 | 有版本/路径/状态，无 API key、图片 base64 或默认全文 prompt |
| D04 | TEST-RESULTS 对照宣称的平台/版本 | 每项有实际命令/人工记录；未验证明确标记 |

## 3. 必须实现的合成 fixtures

这些是测试数据约定，**不是从用户真实聊天录制的事件**。
测试文件需用完整可解析 JSON；下方 text 场景已给出最小完整记录。
假 RPC 按 fixture 请求 ID 映射实际客户端 ID，不把固定 r1 写死进实现。

### 3.1 正常文字场景

客户端发送：

```json
{"id":"r1","type":"prompt","message":"你好"}
```

服务端按顺序返回：

```jsonl
{"id":"r1","type":"response","command":"prompt","success":true}
{"type":"agent_start"}
{"type":"turn_start"}
{"type":"message_start","message":{"role":"user","content":"你好","timestamp":1000}}
{"type":"message_end","message":{"role":"user","content":"你好","timestamp":1000}}
{"type":"message_start","message":{"role":"assistant","content":[],"api":"test","provider":"test","model":"test","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"pending","timestamp":1001}}
{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}
{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"你"}}
{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"好！"}}
{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"你好！"}}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"你好！"}],"api":"test","provider":"test","model":"test","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":1001}}
{"type":"turn_end","message":{"role":"assistant","content":[{"type":"text","text":"你好！"}],"api":"test","provider":"test","model":"test","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":1001},"toolResults":[]}
{"type":"agent_end","messages":[],"willRetry":false}
{"type":"agent_settled"}
```

断言：仅一条“你好”用户消息、仅一条“你好！”助手消息；pending 为空；run-active=nil；草稿仍可编辑。
将 response 移到 agent_start 之后再跑一遍，结果仍相同；协议不保证响应一定先于事件。

### 3.2 分支历史场景

entries 依次包含以下有效节点（测试中补齐 timestamp/message 字段）：

| id | parentId | 内容 |
|---|---|---|
| a | null | user: 第一个问题 |
| b | a | assistant: 第一份答案 |
| c | b | user: 放弃的问题 |
| d | c | assistant: 放弃的答案 |
| e | b | user: 当前问题 |
| f | e | assistant: 当前答案 |

leaf=f 时可见 a,b,e,f，最后 prompt 为“当前问题”。leaf=d 时可见 a,b,c,d。
leaf=null 时可见空链，不能选 f。把 b.parentId 改成 f 时应报环，不能无限循环。
增量 cursor=d 后返回 e,f：append cursor 更新 f，同时按服务端 leaf 选择可见链。

### 3.3 重试场景

顺序：agent_start → assistant(error) → agent_end(willRetry=true) → auto_retry_start →
agent_start → assistant(success) → auto_retry_end(success=true) → agent_end → agent_settled。
断言：中途显示 retry，不提前 idle；失败内容作为可读过程保留，最终成功回复展开。
所有重复出现在结束事件的消息不重复插入。

### 3.4 未知发送结果场景

fake-pi 读到 prompt 后不响应，在 timeout 之后发 user/assistant 事件。
断言：timeout 时客户端显示 uncertain、没有第二次 prompt；晚事件仍作为权威消息处理。
随后用户通过 recovery 查看旧输入，必须能知道“可能已发送”，不能默认一键自动重发。

### 3.5 长历史索引场景

合成 header + 大于 100 KiB 的 system 行 + 25 条 metadata + user + session_info old +
大量正文 + session_info new + 半条 JSON 尾行。
断言：预览来自 user，名称为 new，尾部写入状态可见，扫描预算行为可预测。
不要从用户真实会话复制 system prompt、工具定义或聊天文字作为 fixture。

## 4. 测试工程要求

- 纯数据断言不需要启动进程；通信测试必须至少一部分经过真实 make-process/filter/sentinel。
- 定时器测试优先可控时钟/条件等待，避免依赖“sleep 0.1 大概够了”。
- 所有等待有 deadline，失败输出请求 ID、事件类型和必要状态，不输出秘密。
- 每个 fixture 的来源标记 synthetic 或去敏录制版本，不能混淆。
- 每条 ERT 都负责 teardown；测试异常后同样清理临时目录、进程和 timer。
- 运行测试时固定 `default-directory`、`process-environment`，真实 PI_CODING_AGENT_DIR 不可泄漏进入集成测试。
- 至少一次从无 .elc 的源码加载验证，至少一次运行编译产物；不能只测其中一种。
- 文档中性能数值是目标，实际报告须给机器/Emacs 版本和输入规模。

## 5. 人工验收清单

### 5.1 macOS GUI 必测

1. 用浅色、深色主题各启动一个聊天，确认状态行、输入框、代码块可读。
2. 同目录开两个聊天，分别发送不同任务；来回切换，输出与草稿不串。
3. 连续输出时输入中文、换行、选区、undo；滚到历史阅读，不被拉回。
4. 展开/收起 thinking、工具和整体过程；最终回复可复制、搜索。
5. Finder 复制中文带空格文件，粘贴为可读 @ 引用；截图粘贴为缩略图。
6. 删除一张待发图片，另一张仍在；失败后可恢复；终端模式有占位。
7. 忙碌时 follow-up/steer，观察队列变化；停止全部后不继续执行旧待办。
8. 触发 extension 选择/确认/多行编辑，C-g 可取消，其他会话不丢输出。
9. kill/restart 后恢复同一会话；历史分支正确，未发送草稿按设计保存于当前活 buffer。
10. 退出 Emacs 后重新启动，通过 resume 恢复持久聊天；不承诺恢复未落盘草稿。

### 5.2 WSL GUI 必测

复用基础聊天路径，额外验证 Windows 文件列表、截图、中文路径、wslpath、PowerShell 超时。
确认 Emacs 启动的是 WSL Linux Pi，发送的路径是 Pi 可访问的 Linux 路径。
本机没有该环境时标未验证，继续交付其他已验证平台。

### 5.3 真实模型最小任务

在临时 Git/普通目录创建一份无敏感内容的测试文本，要求 Pi 读取并总结，然后修改一处指定内容。
验证 read/write/edit 或实际模型选择的工具事件、最终回复、停止、恢复后历史。
模型测试单独记录所用 provider/model 和 Pi 版本；不保存 key，不把费用/权限行为泛化到所有模型。
不得在用户现有仓库发“随便修改代码”作为 smoke。

## 6. 交付报告模板

```text
插件版本/提交：
Emacs 版本：
Pi 版本与路径：
操作系统：
编译：命令、退出码、警告数
ERT：命令、通过数、失败数、跳过数及原因
真实离线 RPC：命令与四项/扩展检查结果
GUI：执行的编号与结果
真实模型：执行/未执行及结果
WSL：实测/mock/未验证
性能：输入规模、耗时、刷新次数、资源清理
仍存在的限制：
```
