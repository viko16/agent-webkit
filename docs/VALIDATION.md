# 实际验收记录

## P1 / #3：待决 JS 对话框与显式响应（2026-10-28）

新增按 Space/Tab 的 `dialog list/respond`，直接持有公开 WKUIDelegate completion，不激活窗口、不自动接受确认。宿主记录 ID、类型、文本/默认值、frame origin、期限；查询和响应在常规 Space 锁之前处理，仍校验归属。prompt 区分显式输入、空字符串、默认值和取消 null；alert 仅能结束通知并继续脚本，两个响应动作不等于业务成功。容量与展示有界、最近结束 ID 保留有限原因；原 JSON/退出码、默认目标及所有既有入口保留。

`python3 tests/reliability.py --dialogs-only` [真实通过](../.artifacts/reliability-20261028-134435/report.json)：8 组 alert/confirm 接受/取消和 prompt 中文/多行/引号、空值、默认值、取消；每次确认原 click 尚未完成、busy 为 true、同 Space 普通动作拒绝，但对话框仍可查询回应，另一 Space 仍能操作。双 Space 同时待决分别回应，错误归属、重复/过期 ID、非法响应/文本拒绝；核对页面结果及调用次数，未重放动作。命令超时安全取消 confirm 为 false，不把单纯 modal 等待误判为内容进程卡死；固定默认 Tab、GUI 观察目标及前台不变。

补全机器可读 schema/响应约束后，Debug `reliability.py --forms` [完整通过](../.artifacts/reliability-20261028-134730/report.json)，包含对话框、原 pending-only Store 恢复、CLI/IPC、bridge、弹窗、frame/shadow、wait、默认/详细诊断、Inspector、六次框架提交、恢复/删除及16项计时。26 命令离线、11项既有守卫、构建签名、语法/diff通过，仍有既有CLT搜索目录警告。此提交先交付基础接口及安全期限；自主事件、导航/关闭/重启的深入生命周期和最终Release代理回归由下一功能记录，不提前计作本轮通过。

## 详细诊断审查修复：XHR 延后发送关联（2026-10-28）

Standards 与 Spec 两轴均确认 P2：XHR 仅在 open 时捕获代号，send 要求代号仍匹配，因此启用前 open 或两次启用之间已 open 的新请求会只有摘要、没有关联 ID。`.artifacts/reliability-20261028-112047/` 使用真实 HTTP 请求稳定复现 status 201 事件缺少 detail，而非仅凭脚本替身推测。

最小修复在每次启用期间的 send 分配当前代号/请求 ID；缺少当前代号下的路径时仅使用既有摘要 origin，并标记 `resourcePathUnavailable: true`，宿主也强制只保留 origin，不回采旧 URL 或扩大默认采集。永久回归覆盖启用前 open、代号切换后的 send、同代号 open/send 三种实际请求，核对状态、唯一 ID、代号与路径降级；保存 `diagnostics-xhr-delayed.json`。旧代号关停断言继续使用当前有效代号，未放宽原验证。

最终 Debug `python3 tests/reliability.py --forms` [完整通过](../.artifacts/reliability-20261028-112152/report.json)，包含三种 XHR 场景、上一修复的四个脱敏边界、原默认/详细诊断及 Inspector、bridge、frame/shadow、弹窗、wait、React/Vue 六次提交、挂起恢复/删除和 16 项计时。最终 Release 的[真实诊断窄复核通过](../.artifacts/reliability-20261028-112326/report.json)，明确记录 `delayedXHRs: 3` 和边界检查；同样使用现有 helper 的 `verify_expiry: false`，没有替换 WebKit 或页面。

24 命令离线及 CLI/IPC、11 项既有守卫、Debug/Release 构建签名、语法/diff 均通过；仍有既有 CLT 搜索目录警告。[本轮清理核查](../.artifacts/review-issue4-20261028/cleanup-check.json)覆盖两次复现与修复后五轮的全部启动，注册表为空、Socket 无服务。本次没有更改期限或 Inspector 控制，未重复等待 5 分钟或运行 Safari 面板、完整 Whistle/HMR/TLS/公网 GUI；这些证据保留在原功能版本，不倒填为修复后重跑。

两轴结论分别保留：Standards 1 项，最高 P2（XHR 关联），无额外 smell 重构；Spec 2 项，最高 P1（截断凭据）及 P2（XHR 关联）。两项均已最小修复并验证，未发现其他已确认的既有验收退化。

## 详细诊断审查修复：截断凭据边界（2026-10-28）

对 `4313f0d...4800cdd` 的 Spec 审查发现 P1：页面先截断正文/栈行，宿主带引号凭据正则原先要求闭引号，截断后会退到无引号分支，只删除第一词。真实 WebKit 在 `.artifacts/reliability-20261028-111714/` 稳定复现：正文与栈行仍含 `[redacted] beta...`，未将这个已识别字段的错误归为任意秘密识别率限制。

最小修复只修改凭据正则，使单/双引号字段延伸至闭引号或剩余文本末尾；长度限制、默认摘要、临时开关、容量、来源和其他接口不变。永久回归新增 512 字符正文、256 字符栈行各自的单/双引号四项边界，要求保留安全标记而不残留任何测试凭据词，保存 `diagnostics-boundary-redaction.json`。

修复后真实诊断窄跑[通过](../.artifacts/reliability-20261028-111829/report.json)，包括原摘要及全部既有详细诊断/Inspector 行为。调用现有真实应用与 helper，仅将既有 `verify_expiry` 参数设为 false，不替换页面或 WebKit；报告明确 `expiryVerified: false`，未改期限逻辑或重复等待 5 分钟。Debug 构建签名、Python 语法及 diff 检查通过；最终完整可靠性和推送随下一项独立修复记录。

## P1 / #4：可选 Safari Inspector 与最终回归（2026-10-28）

新增 `diagnostics --inspectable on|off`，直接读写公开 `WKWebView.isInspectable`，默认 false，不持久化、不自动启动 Safari 或激活窗口。按 Tab 独立，popup 不继承；普通导航保持当前 WebView 的开关，关闭/替换或重启复位。与详细捕获独立，每次仅允许修改其中一个开关，避免部分配置生效后返回错误；CLI/IPC 校验和机器可读契约同步。

最终 Debug 的 `reliability.py --forms` [完整通过](../.artifacts/reliability-20261028-091017/report.json)，新增真实属性默认值、Space/popup 隔离、忙碌关闭、卡死启用、异常恢复与重启复位、导航保持、hook 缺失时详细模式失败回滚；原有详细模式、诊断摘要、六次框架提交、16 项计时及其他可靠性断言保留。24 命令离线专项（含新选项）、CLI/IPC 对照、11 项既有守卫、Python 语法/diff 均通过。

最终 Release 的 `acceptance.py --vite --direct-conflicts --out .artifacts/issue4-full-20261028` [完整通过](../.artifacts/issue4-full-20261028/report.json)：代理参数、Direct 冲突、弹窗、A/B/C/D、fetch/WSS、TLS、双代理和 Vite/Whistle HMR 均保留。Debug/Release 构建及应用签名通过，仍有既有 CLT 搜索目录警告。没有为验证改动系统代理、安装 CA 或修改已有 Whistle。公网 SPA/登录和观察窗口 GUI 沿用已有证据，没有把本次 Inspector 实查计作它们的重跑。

Release 独立本地页面的 [Safari 原生面板实查通过](../.artifacts/issue4-inspector-manual-20261028/report.json)，明确 `requiresForeground: true`。经 Safari 开发菜单选择本机 Agent WebKit 页面，实际出现 Inspector 控制台；CLI 向唯一目标发出 `Inspector attached 615BC267`，原生 AX 在面板中确认该标记，CLI 同时返回匹配标题、Space/Tab ID。随后 CLI 设置 off，测试 daemon 仍在运行时面板关闭，Safari 回到原起始页；宿主观察目标未变。保留[可见记录](../.artifacts/issue4-inspector-manual-20261028/inspector-visible.txt)、[关闭记录](../.artifacts/issue4-inspector-manual-20261028/inspector-disabled.txt)、上下文和逐条命令。没有修改 Safari 设置或用户标签页；首次原生 app 查询长时间未返回，恢复原 ChatGPT/Codex 前台窗口又被界面工具禁止，这些是实查工具限制，未绕过限制或混入普通 CLI 的不抢前台结论。

[清理复核](../.artifacts/issue4-full-20261028/cleanup-check.json)覆盖本批失败/成功诊断、完整验收和手动 Inspector 的注册表/Socket：网站数据记录为空、Socket 无服务。详细日志的自然到期证据来自上一独立功能提交的真实 5 分钟专项；本功能没有修改其期限逻辑，也没有重复等待。详情仍只覆盖显式启用后的当前文档，不承诺初始导航、跨源 frame/worker、完整网络追踪或任意敏感文本的绝对脱敏。

## P1 / #4：按 Tab 临时详细诊断（2026-10-28）

新增 `diagnostics --detail on|off`，默认摘要、200 条容量、native/page-script 来源、原 JSON 字段与退出码保留。详情只面向指定 Tab 当前文档的新事件，含有限正文、8 行堆栈、受限资源路径、宿主导航 ID 和每次 fetch/XHR 的请求 ID；不采集 header/body、不序列化 console 对象。表单值在页面就地替换，宿主再次白名单过滤、限长及 URL/凭据/Token 脱敏；自由文本不能保证消除一切敏感信息，保持显式启用和尽力处理的边界。关闭、导航、恢复、重启会抹除详情，popup 不继承；最长 5 分钟，接收/输出前用绝对和单调期限兜底。

`python3 tests/reliability.py --diagnostics-only` [真实通过](../.artifacts/reliability-20261028-090352/report.json)，保留原摘要专项，新增异常/拒绝堆栈、失败资源、7 个唯一 fetch/XHR 请求 ID、表单及带标签凭据/Token/URL 脱敏、伪造字段/动态路径过滤、长度限制、Space/popup 隔离、关闭后的旧代号批次拒绝、忙碌/卡死读取与关闭、导航/恢复/重启复位。实际等待 5 分钟后，模式关闭且已有详情全部移除，保留[到期快照](../.artifacts/reliability-20261028-090352/diagnostics-expired.json)，不是缩短期限或修改系统时钟的测试。

`reliability.py --forms` [完整通过](../.artifacts/reliability-20261028-090354/report.json)，包括新增详细模式、原有 pending-only Store 恢复、CLI/IPC 契约、bridge、弹窗、frame/shadow、wait、诊断摘要、React/Vue 六次提交、失联恢复/删除重建及 16 项计时。Debug 构建签名、24 命令离线、11 项既有守卫、Python 语法和 diff 检查通过。完整模式不重复等待自然到期，报告明确 `expiryVerified: false`；专项为 true。

保留两轮开发失败：`.artifacts/reliability-20261028-085514/` 在卡死超时的详细正文断言处失败，原 native 回调传空正文，现用已有原因码补足，不改超时行为；其自有待删除 Store 经正常恢复[完成清理](../.artifacts/reliability-20261028-085514/cleanup-check.json)。`.artifacts/reliability-20261028-085621/` 的其余路径通过，但等待至 310 秒后原后台任务仍未清除详情；现于接收/生成快照前强制检查期限并先擦除，再复制事件。修复后上述两套真实回归通过，没有放宽断言。当前文档模式不补录启用前或下一次完整导航的初始错误；Inspector 与最终 Release 代理验收由下一独立功能记录。

## P1 双轴审查修复：Skill 测试失败清理（2026-10-28）

审查范围为 `git diff 15e6b77...8d3021b`，即 `91386dd`、`8d3021b` 两个提交，依据 Issue #2/#7、用户约束及仓库运行/验收约定。Standards 与 Spec 各报告 1 项 P2，指向同一缺陷：原 `finally` 中列举、删除 Space 或 shutdown 任一步失败，会跳过其余清理并掩盖原测试异常。未发现命令校验语义、原生页面执行、JSON/退出码或既有验收入口/断言退化；没有为启发式代码气味另做重构。

修复仅涉及可选 Skill 测试：逐项尝试删除，优先正常退出 daemon，超时后有界 terminate/kill 自有进程；HTTP 关闭独立执行。启动失败也能释放已启动的 fixture。原测试异常优先，清理错误单独保存；仅清理失败也不能生成成功报告。清理失败可能留下未删数据，文档明确不以停止进程冒充数据删除。

`python3 -m unittest discover -s tests -p test_skill_cleanup.py -v` 的 5 项通过，覆盖 IPC 断连、删除失败后继续处理其他 Space、shutdown 失败/超时、terminate/kill 有界回收、保留原始异常、清理失败阻止成功报告，以及启动/HTTP 关闭失败。使用标准库故障注入，不调用模型或操作用户服务。

修复后 `python3 tests/skill_workflow.py` [真实通过](../.artifacts/skill-codex-20261028-012641/report.json)：旧引用失效与重新快照、非默认 Tab 保存计数 1、真实 150 ms 超时及随后观察、另一 Space/默认 Tab/GUI/前台不变、注册表为空和 Socket 无服务均通过。24 命令离线专项、原有 6 项 workflow guard、Python 语法与 diff 检查通过。原生源码未改，本轮未重复运行完整可靠性/Whistle/HMR/TLS 或公网/原生 GUI，保留此前实际通过证据的版本归属。Pi 仍未实测，#7 整项不勾选。

## P1 / #7：仓库 Skill 与真实 Codex 调用（2026-10-28）

新增 `skills/agent-webkit/SKILL.md`，对应 CLI 0.2.0 / 契约 v1，直接调用现有 CLI。覆盖 daemon 连接、Space/Tab 归属、snapshot→action→wait/业务验证、旧引用、超时不重放、弹窗、文件/对话框限制、人工接管、代理与共享服务清理。README/DEVELOPMENT 提供显式安装或单次路径调用说明；没有写入用户技能目录或 Agent 配置，没有新增应用依赖。

`python3 tests/skill_workflow.py` 最终[真实通过](../.artifacts/skill-codex-20261028-011833/report.json)：已登录 Codex CLI 在临时工作目录通过显式路径读取 Skill，操作独立 Direct fixture 的非默认 Tab。真实 `stale_ref` 后重新 snapshot，填写并保存一次；等待不存在标记 150 ms 返回真实 `timeout`，随后观察页面而未重复保存。宿主独立核对 `saves: 1`、结果 `P1-skill`、另一 Space 未变、固定默认 Tab/GUI/前台不变；退出后的注册表为空，测试 Socket 不再接受连接。报告生成在清理核查之后，原始 Agent 事件与宿主命令均保留。

首轮[真实调用](../.artifacts/skill-codex-20261028-011412/report.json)完成业务场景，但 Agent 起初把 `--version` 与 Socket 选项混用、把 `space info` 的位置参数写成选项，均返回 `invalid_arguments`，读契约后自行纠正。据此只明确 Skill 的 `version --socket PATH` 和 `space info NAME_OR_ID` 写法。第二轮功能及错误恢复通过，随后新增的清理断言误把残留 Socket 路径当作仍有服务，整轮[保持失败记录](../.artifacts/skill-codex-20261028-011628/agent-events.jsonl)，未生成成功报告；核查确认注册表为空且连接被拒绝。测试改为检查真实连接，最终完整专项通过，没有修改原生退出或 Socket 行为。

Skill 格式校验通过；本机 Python 缺少 PyYAML，使用 `uv run --no-project --with pyyaml` 的隔离环境运行 skill-creator 验证器，未加入产品依赖。Python 语法与 diff 检查通过。本项只新增文档/Skill/可选集成测试，原生代码与已有验收入口保持上一提交版本；完整可靠性和 Whistle/HMR/TLS 结果见下节，不重复计作本次执行。

本机没有 Pi，未安装或代替它运行，因此 Issue #7 的 Pi 实际调用仍待验证。Codex 此次只验证显式路径调用，不宣称安装后自动发现、所有任务的 Skill 路由或第三方 OAuth 兼容性；#7 整项继续保持未完成。

## P1 / #7：离线帮助与 CLI 契约（2026-10-28）

新增 `help COMMAND [SUBCOMMAND]` 和 `capabilities`，CLI 离线可用，原始 Socket 返回相同内容。24 个命令的参数范围/允许选项共用既有校验定义，另列必需项、单位、组合约束、错误码、结果外层 schema、可用范围与能力限制；没有更改页面执行、响应字段或退出码，也没有引入依赖或新的客户端。

`python3 tests/contract_cases.py` 通过：全部命令及两组帮助、未知主题/参数拒绝、schema 引用、超时单位、退出码、无 IPC 计时；不存在的 Socket/注册表目录始终未创建。`reliability.py --forms` [通过](../.artifacts/reliability-20261028-010843/report.json)：新增真实 CLI/IPC 对照、实际 status/Space/Tab/snapshot/diagnostics 结果字段、字面 `--help` 填写及 GUI/默认目标不变；保留 bridge、frame/shadow、弹窗、等待、诊断、六次框架提交、挂起恢复/清理和 16 项计时。

最终 Release 的 `acceptance.py --vite --direct-conflicts --out .artifacts/issue2-p1-contract-full-20261028` [完整通过](../.artifacts/issue2-p1-contract-full-20261028/report.json)：原有代理参数、Vite/Whistle 域名与 WSS/HMR、Direct 冲突、弹窗、A/B/C/D、fetch/WSS、TLS 和双独立代理均保留。Debug/Release 构建与签名、离线专项、既有 6 项 workflow guard 及 diff 检查通过。构建仍有既有 CLT 搜索目录警告。

完整可靠性运行后，仅修正契约中 `diagnostics --clear` 的说明（先清空再返回）；随后重新构建最终 Debug/Release、复跑离线专项，并在最终 Release 执行上述完整验收。schema 限定稳定外层，不宣称穷举页面任意 JSON。此功能尚不等同 #7 全部完成；Skill 和实际 Codex/Pi 集成另行验证，公网/原生 GUI 沿用此前证据，不计作本次重跑。

## 审查修复：共用 GUI 检查辅助逻辑（2026-10-28）

将真实 SPA 与登录专项重复的 `checkpoint` / `observer` 提取为同一个 `site_gui_checks`，每个流程仍独立绑定其回调、动态 Space 映射和报告。原有检查点、Space/Tab/可见性断言、`observerChecks` 内容、前台与截图步骤保留；没有改变原生代码、CLI 接口或新增测试框架。

`python3 -m unittest discover -s tests -p test_workflow_guards.py -v` 的 6 项测试全部通过：保留两项 HMR 守卫测试，新增四项 GUI 辅助逻辑验证，覆盖两流程上下文隔离、默认可见/显式隐藏、错误 Space/Tab/可见性拒绝且不记录成功、无 GUI 回调不查询/记录、操作者拒绝时异常继续上抛。Python 语法及 diff 检查通过。这些检查使用受控宿主返回值验证抽取后的 Python 逻辑，本轮未重新执行公网/原生 GUI 或完整验收；此前真实 GUI 证据保持其原版本归属。

## 审查修复：HMR 回执文档归属（2026-10-28）

修复原先仅按版本统计“两条回执”的守卫：现在逐版本同时检查数量和两个实际页面的 `documentId` 集合；重启后在修改版本文件前重新采集 ID，报告保留 `hmrExpectedDocumentIds`。原有页面状态、Whistle 路由/WSS、Direct 对照、隔离、超时、引用失效与恢复断言保留，未修改原生代码或增加应用依赖。

`python3 -m unittest discover -s tests -p test_workflow_guards.py -v` 的 2 项针对性测试通过，包括正常双文档/重启及 6 类负例：重复、缺失、其他文档、重启前 ID、额外回执、缺少有效 ID。`python3 tests/acceptance.py --vite-only --out .artifacts/review-hmr-documents-20261028` [真实专项通过](../.artifacts/review-hmr-documents-20261028/vite-workflow/report.json)：三次热更新与重启后更新的四组实际 ID 均匹配。另核对重启前后 ID 不重合、注册表为空、Socket 与测试 Vite/Whistle 端口释放，[复核记录](../.artifacts/review-hmr-documents-20261028/evidence-check.json)通过。Python 检查及 diff 检查通过；本次只修改测试守卫，未重跑完整代理或原生 GUI 套件。

## 真实站点回归发现的独立修复：仅剩 tombstone 时的恢复（2026-10-28）

一轮主动取消的 GUI 验收正常删除了网站数据，但 WebKit 仍占用空容器，注册表保留 `deleting: true`。单独重启重试时，系统在 `com.apple.WebKit.WebsiteDataStoreIO` 队列的 `removeDataStoreWithIdentifierImpl → WTF::RunLoop::dispatch → os_unfair_lock_lock` 崩溃（SIGSEGV / 0x48）。保留[原生崩溃摘要](../.artifacts/reliability-20261028-003359/crash-evidence.json)，没有改写删除标记来隐藏问题。

新增真实 WebKit 回归 `python3 tests/reliability.py --cleanup-only`：创建实际 Store、写入 LocalStorage、正常退出，再只改该轮自产注册表，模拟中断在删除标记持久化之后、实际 purge 之前。新进程只有一个待删除记录、没有存活 Space，因此没有其他 Store 提前初始化 WebKit。修复前[专项稳定复现启动崩溃](../.artifacts/reliability-20261028-003359/daemon-1.log)，和原 GUI 遗留状态相符；它不是 Mock 删除，也不宣称真实强杀或断电。

修复限定在有删除标记的启动恢复：先创建临时非持久 Store，持有至恢复完成，再沿用原来的删除 API、错误与 tombstone 流程。没有使用默认 Store、私有 API、额外 WebView 或导航，也没有删除用户数据。修复后 Debug 的[同一专项通过](../.artifacts/reliability-20261028-003501/report.json)：ready 为 true、pendingStoreCleanup 为 0、注册表清空；同名重建分配新 UUID 且读取不到旧 LocalStorage。

修复后的最终 Release 上，`python3 tests/reliability.py --forms` [通过](../.artifacts/reliability-20261028-003658/report.json)，包含新增 pending-only 用例，以及原有 bridge、弹窗、frame/shadow、wait、诊断、React/Vue 六次提交、死循环/Promise 恢复、删除重建和 16 项计时。Debug/Release 构建、签名、Python 语法及 diff 检查通过。此五行启动初始化修复后复跑了受影响恢复路径和整套可靠性；完整 Whistle/TLS/A/B/C/D 套件的通过记录来自修复前的最终 Release，未将其倒填为修复后重跑。

[最终清理核查](../.artifacts/issue2-existing-full-20261028/cleanup-check.json)覆盖本批 16 轮站点/代理/可靠性测试，包括失败和主动取消的轮次：测试 daemon、Whistle PID 均退出，注册表均为空，Socket 无服务，记录的 Whistle/Vite 端口均释放。两个遗留删除标记分别通过修复后的正常启动恢复移除，其中 GUI 数据使用相同测试 Bundle ID 的更新副本；没有直接删除系统 WebKit 目录或手工抹掉 tombstone。没有修改用户系统代理、钥匙串或已有 Whistle。强杀 WebContent、真实断电、长期资源、旧版 macOS 实机和真实 OS 代理开关仍保持待验收。

## Issue #2 阶段 0：公网登录／弹窗站点（2026-10-28）

目标为 [The Internet](https://the-internet.herokuapp.com/login) 的 `/login`、`/secure`、`/windows` 与 `/windows/new`，通过公网 Direct + 系统证书校验访问。仅使用该站公开演示账号；没有用户凭据、真实个人账号或本地 HTML 替代。新增 `--real-site-case spa|login|all`，`--real-sites` / `--real-sites-only` 默认包含两个站点；原有基础验收入口与断言保留。

`python3 tests/acceptance.py --real-sites-only --real-site-case login --real-sites-gui --out .artifacts/issue2-login-gui-final-20261028` [通过](../.artifacts/issue2-login-gui-final-20261028/login-report.json)，测试使用当前源码构建的 Debug 应用。实际检查：

- A 成功登录、B 错误密码，并验证 B 访问受保护页仍由服务器重定向回登录页；输入密码字段在 snapshot 中为 `[redacted]`。成功判断来自完整导航后的 URL 和服务器页面内容，动作仍标记 DOM / 非原生 / 未验证业务结果。
- `/windows` 的实际 `_blank` 链接创建 A 的新 Tab，继承系统 TLS 和登录会话；子 Tab 访问 `/secure` 成功，固定 CLI 默认 Tab 不变。B 仍处于登录页，未被 A 会话影响。
- GUI 实查先观察 B，再选择 A 的认证子 Tab，并核对实际 Secure Area。关闭原生观察窗口后，宿主状态确认为 `visible: false`；后台并发执行 A 子 Tab 退出与 B 成功登录。A 的父 Tab 重载后也被服务器拒绝，B 保持已登录；后台 PNG、有界等待超时及前台不变检查通过，结束时窗口仍隐藏。[GUI 检查点](../.artifacts/issue2-login-gui-final-20261028/gui-checkpoints.jsonl)、[逐条命令](../.artifacts/issue2-login-gui-final-20261028/commands.jsonl)及报告中的四次宿主状态可核对。
- 再反向执行 A 登录/B 退出，关闭 A 子 Tab 后查询返回 `tab_not_found`，默认 Tab 仍保留。重启后 Space/DataStore/Tab ID、Tab 集合、代理/TLS 均一致；该站 A 实际回到 `/login`，已退出的 B 也保持 `/login`。这是当前站点登录状态的实测边界，未单独归因于 Cookie 生命周期或服务端策略，不是“所有登录状态跨重启保留”的证据。

**站点／引擎语义**：该链接没有 `rel="opener"`，WebKit 实测子页 `window.opener === null`；按 [HTML 的 opener 规则](https://html.spec.whatwg.org/multipage/links.html#link-type-opener)属于隐式 noopener。测试核对该行为，没有修改站点属性或强开 opener；宿主 `openerTabId` 只是创建关系。原有本地显式 opener/postMessage/回调仍由完整弹窗回归覆盖。此处是同站登录与新窗口流程，没有第三方 OAuth 提供商、MFA、跨源登录回调或可信原生输入验收。

**保留的失败**：[首轮](../.artifacts/issue2-login-probe-20261028/report.json)把服务器 flash 提示误限定在 `#content`（实际位于独立区域）；[第二轮](../.artifacts/issue2-login-20261028-v2/report.json)的 `_blank` 选择器同时命中两个页脚链接，按既有唯一匹配规则返回 `selector_count`，随后限定实际 `.example` 链接。[首轮 GUI](../.artifacts/issue2-login-gui-20261028/report.json)误要求网站提供 JS opener，实际按上述标准返回 null；修正站点预期后完整 GUI 专项通过。三项均是新验收对实际站点结构/规则的错误假设，没有更改应用的 DOM 合成、选择器唯一性或 opener 行为来凑通过。

最终 Release 上，`python3 tests/acceptance.py --vite --direct-conflicts --out .artifacts/issue2-existing-full-20261028` [完整通过](../.artifacts/issue2-existing-full-20261028/report.json)：代理参数、Vite/HMR、五类 Direct 冲突、弹窗、A/B/C/D、fetch/WSS、TLS、双独立代理均通过。此前 `--real-sites --vite --direct-conflicts` 的 [Release 组合运行](../.artifacts/issue2-real-sites-full-final-20261028/report.json)已通过真实 SPA、真实登录、HMR 和 Direct 冲突，随后因外部前台从 1241 切到 1245 在原有弹窗焦点断言停止；没有将整轮记为通过。更早的[组合首轮](../.artifacts/issue2-real-sites-full-20261028/report.json)同样因外部前台 1245 → 1241 停止，均非当时测试 daemon。完整套件单独重跑保留所有断言并通过，启动前后前台保持 1245。

本轮 macOS 27.2（26B123）。完整套件 RSS 合计：空 Space 阶段 171.22 MiB，五 Space 424.08 MiB，重启后 329.83 MiB，删除后 147.77 MiB，退出后 0；这是先运行 HMR 后的短时资源样本，含共享页重复计算，不是冷启动或长期上限。Debug/Release 构建、签名、Python 语法和 diff 检查通过；Release 构建另提示迁移前路径的旧中间产物及既有 CLT 搜索目录警告，未为此清理仓库外文件。GUI 实查使用 Debug，Release 组合及完整套件没有原生 GUI 交互。

资源核查发现的仅 tombstone 启动崩溃已作为上面的独立修复处理；上列站点验收记录保留其实际测试版本，不把后续恢复修复的结果倒填为原运行结果。

## Issue #2 阶段 0：真实 SPA 与观察窗口（2026-10-28）

使用真实公网 [Vue 官方文档](https://vuejs.org/guide/introduction.html)，Direct + 系统证书校验，不通过本地映射或替换 HTML。新增 `acceptance.py --real-sites-only` 专项和 `--real-sites` 完整套件扩展，现有验收入口与断言保留。宿主仅新增只读 `status.observer`，返回窗口可见性、GUI Space/Tab ID；未引入 GUI 控制接口或全局 Agent 活动目标。

`python3 tests/acceptance.py --real-sites-only --real-sites-gui --out .artifacts/issue2-spa-observer-20261028` [实际通过](../.artifacts/issue2-spa-observer-20261028/spa-report.json)。两个 Space 的计数分别达到 1/2，随后各自完成 Introduction → Reactivity/Computed → Computed/Reactivity → Introduction 的客户端路由，文档 UUID 各自保持不变；回到首页后再次点击达到 1。URL、可见标题、缺失元素的有界超时、固定默认 Tab、后台 PNG 和各阶段前台 PID 均核对通过。

通过原生 GUI 工具实际选择 A 的非默认 Reactivity Tab，再对两个默认 Tab 操作，GUI 未切走；切换到 B 后并发路由，仍观察 B。原生关窗后读取宿主确认 `visible: false`，随后继续双 Space 路由、点击和截图；结束时仍为 false，Space/Tab ID 不变。六次宿主观察状态在报告中保留，[检查点](../.artifacts/issue2-spa-observer-20261028/gui-checkpoints.jsonl)与[逐条命令](../.artifacts/issue2-spa-observer-20261028/commands.jsonl)可交叉核对。GUI 操作明确要求前台，未把手动切换前后的前台变化误当成 CLI 抢焦点；普通运行不会据此自动声明 GUI 通过。

首次纯 CLI [运行通过](../.artifacts/issue2-spa-probe-20261028/report.json)，随后 [GUI 首轮失败](../.artifacts/issue2-spa-gui-20261028/report.json)：同一 bridge 引用后缀保持不变时，`performance.timeOrigin` 读数变化 1 ms，精确相等断言不适合作文档身份。改用不触碰业务状态的 UUID 标记，时间读数仍保留。另一轮在关窗状态不明确时主动拒绝检查点，[保持失败](../.artifacts/issue2-spa-gui-final-20261028/report.json)；补充宿主真实可见性后完成最终回归。检查过程中，GUI 工具在关窗后的 AX 查询会重新激活观察窗口；最终用原生关窗动作加 CLI 的 `visible` 前后断言验证，没有绕过这一差异。

`python3 tests/reliability.py --forms` [通过](../.artifacts/reliability-20261028-001317/report.json)，原有 bridge、弹窗、frame/shadow、wait、诊断、六次框架提交、恢复/清理及 16 项计时全部保留。前一次 `.artifacts/reliability-20261028-001203/` 在既有前台断言处停止：前台从 6540 变为 1241，均不是测试 daemon（当时 PID 8019/8280）；保留失败命令记录与断言，未把那次运行记为通过。

Debug 构建、应用签名、Python 语法与 diff 检查通过；构建仍有既有 CLT 链接目录警告。登录/弹窗公网测试站、第三方 OAuth、重启后的真实站点会话、真实 OS 代理开关和长期资源测试不由这项 SPA 回归宣称完成。

## Issue #2 阶段 0 / #1 P1：Vite + 真实 Whistle HMR（2026-10-27）

完成 `acceptance.py --vite-only` 专项及 `--vite` 完整套件扩展。运行时仍为原有 Swift/AppKit/WKWebView + CLI/Unix Socket，本次只增加测试和文档；复用已安装、锁定的 Vite 8.3.5，不向应用增加依赖。测试修改输出目录里的项目副本，仓库源文件和用户项目不参与热更新。

- `python3 tests/acceptance.py --vite --direct-conflicts --out .artifacts/issue2-vite-full-20261027` [完整报告](../.artifacts/issue2-vite-full-20261027/report.json)通过：新增 Vite 专项，以及原有代理参数、Direct 冲突、弹窗、A/B/C/D、fetch/WSS、TLS、双独立代理全部通过。此前的 `reliability.py --forms` 已通过；本次没有改动原生源码，也没有移除或放宽原有断言。
- 最终补充规则 matcher 断言及“资源清理成功后才标为通过”，再运行 `python3 tests/acceptance.py --vite-only --out .artifacts/issue2-vite-final-20261027` [专项通过](../.artifacts/issue2-vite-final-20261027/vite-workflow/report.json)。Python/Node 语法检查、`git diff --check` 通过。未额外构建 Release；测试与此前 P0 复核使用同一 Debug 应用。

最终专项使用来源 HTTP 端口 50581、Whistle 50583，代理 Space 打开同一 `https://example.com/?vite_workflow=...`。实际文档、`/@vite/client`、主模块、版本模块、fetch 均返回 200；五条 WSS 会话为 101，`realUrl=ws://127.0.0.1:50581/...`、响应端口及实际命中规则相符。[抓包](../.artifacts/issue2-vite-final-20261027/vite-workflow/whistle-sessions.json)与[来源日志](../.artifacts/issue2-vite-final-20261027/vite-workflow/origin.jsonl)共同证明路径；首两条 WSS ID 为 `1793116566685-014`、`1793116566687-015`。Direct 对相同公网 URL 读到 Example Domain，本地来源和 Whistle 请求增量均为 0。

两个 Space 连续三次真实文件热更新保留不同文档 UUID、计数 1/2 和各自 Cookie/LocalStorage；来源收到每版本各两条 HMR 回执。切换 CLI 默认 Tab 至空白页仍显式操作原 Tab，空白页不串用；跨 Space Tab 返回 `tab_not_found`，等待不存在版本返回 `timeout` 且计数不变。重新导航更换文档 UUID 并拒绝旧引用，后台[截图](../.artifacts/issue2-vite-final-20261027/vite-workflow/after-hmr.png)成功。重启保留 Space/DataStore/默认 Tab ID、代理、TLS、Cookie/LocalStorage，随后两个新文档再次各收到一次真实 HMR；总计八条版本回执。前台 PID 始终 1245。

首轮已完成热更新，但验收误把 Whistle WebSocket 的字符串 `"101"` 当作整数，并把来源协议预期为 HTTP；[失败报告](../.artifacts/issue2-vite-20261027/report.json)保留，修正抓包断言后专项及完整套件通过。Vite 日志在旧引用负例期间还记录了 `Script error`；CLI 按预期返回 `stale_ref`，后续重连/HMR 通过，不把日志缺少错误当作验收条件。

[清理核查](../.artifacts/issue2-vite-final-20261027/cleanup-check.json)确认包含失败尝试在内的五轮代理验收注册表为空、Socket 无服务、自有 Whistle PID 已退出，记录的 Whistle/Vite 端口均释放；完整套件退出后的相关进程 RSS 为 0。没有停止或修改已有代理、系统代理或钥匙串。

本项使用显式忽略证书错误的受控开发 Space，不代表严格 CA 信任验收；loopback 目标代理限制不变。未验证第三方 Vite 插件、React/Vue 专用 HMR、懒加载/Service Worker 的全部路径。本专项不切换 GUI，也不替代真实 SPA/登录站点回归、真实 OS 代理开关和长期资源测试；这些 checklist 保持未完成。

## Issue #2：既有 P0 逐项复核（2026-10-27）

本批先核对 #1 的实现和未完成验收，再在当前源码构建的 Debug 应用上串行运行：

- `python3 tests/reliability.py --forms` [通过](../.artifacts/reliability-20261027-235003/report.json)：P0-1 的 page world 覆写/删除、独立 bridge、evaluate/Promise、引用失效、刷新/重启和后台截图通过；P0-3 的 Direct 弹窗、回调/关闭、默认 Tab、Space 隔离与前台不变通过。原有 frame/shadow、wait、诊断、React/Vue 六次真实提交、死循环恢复、清理及 16 项计时均通过。
- `python3 tests/acceptance.py --direct-conflicts --out .artifacts/issue2-p0-20261027` [通过](../.artifacts/issue2-p0-20261027/report.json)：P0-2 的 HTTP/HTTPS/SOCKS/PAC/自动发现五类**进程内 CFNetwork 注入**下，daemon 重启、Whistle 可用、Direct 拒绝及保留 Cookie/LocalStorage/Tab ID 恢复通过；P0-3 的真实 Whistle 弹窗及 TLS 正反用例通过。原有 A/B/C/D、fetch/WSS、双独立代理并发/重启/单路断连均通过。
- `zsh scripts/build.sh` 与 `codesign --verify --deep --strict '.build/Agent WebKit.app'` 通过，保留既有 CLT 两个链接搜索目录警告。首次沙箱构建无法写入编译缓存，授权使用正常缓存后构建成功。

本轮系统为 macOS 27.2（26B123），启动前后前台 PID 都为 1245。RSS 合计：空应用 118.38 MiB，五 Space 423.84 MiB，重启后 331.50 MiB，删除后 148.91 MiB，退出后测试进程全部回收；短时采样含共享页重复计算，不能作为长期资源上限。

**P0-2 尚未完成真实 OS 代理开关的独立环境验证**，#1 对应两项验收继续未勾选；没有修改用户系统代理、钥匙串或已有 Whistle。此前 GUI 实查证据保留，本次未重做手动 GUI 验收。P0 的实现及已有自动化回归均保留，不将进程内注入表述为系统级通过。

## Space 独立 Whistle 端口（2026-10-26）

`Space.init` 现在接受 `http://127.0.0.1:<PORT>`（1–65535），用实际端口创建 HTTP CONNECT 配置。代理仍写在各 Space 的 WKWebsiteDataStore 上，`allowFailover = false`、网站数据隔离和证书策略保持原行为；注册表继续保存完整代理地址，恢复不引入默认端口或全局覆盖。CLI 帮助、README、开发说明和验收入口同步更新。

已检查仓库全部 8899：运行时的两处限制已移除，验收及 Direct 冲突用例改用实例地址；README 的兼容示例、复用已有 Whistle 的默认端口、旧 CONNECT / loopback 诊断工具、仅展示代理配置的 UI fixture 和历史验收记录保留其原用途。

### 两路实际网络证据

使用本机已有 Whistle 2.10.12 和真实 WKWebView；未安装依赖。专项命令：

```sh
python3 tests/acceptance.py --independent-proxies-only --out .artifacts/proxy-isolation-20261026-v2
```

[专项总报告](../.artifacts/proxy-isolation-20261026-v2/report.json)和[双代理详细报告](../.artifacts/proxy-isolation-20261026-v2/independent-proxies/report.json)均通过。两个 Whistle 的 `WHISTLE_PATH`、baseDir、storage 所在根目录、证书目录和 CA 各自独立，绑定 127.0.0.1 的空闲端口；独立 rcPath、禁用全局插件和 prod 模式隔离已有配置。启动记录见 [A](../.artifacts/proxy-isolation-20261026-v2/whistle-instance.json) / [B](../.artifacts/proxy-isolation-20261026-v2/independent-proxies/whistle-instance.json)。

| Space | HTTP Whistle 端口 | 规则指向的来源端口 | 页面和 fetch 返回的来源 nonce | 首次导航抓包 ID |
| --- | --- | --- | --- | --- |
| proxy-a | 60493 | 60492 | `a91a341c39024374b60cfd29f83c4a94` | `1793005986342-002` |
| proxy-b | 60516 | 60515 | `948cb419351645b7a75620aa056eb4e2` | `1793005986404-001` |

两路并发访问完全相同的 URL：`https://example.com/?independent=bc5d3cffa54c4b92b8c9f2ce6894f382&phase=concurrent&delay=0.8`。各自输入并点击保存后页面分别显示 proxy-a / proxy-b；同 URL 的 fetch 分别返回本来源 nonce。Whistle 的实际 GET、命中规则、realUrl、目标端口、200 状态及 endTime 均与对应来源日志一致，两路延迟导航到达时间差 0.067 秒，未出现规则串用。

证据：[A 抓包](../.artifacts/proxy-isolation-20261026-v2/whistle-sessions.json)、[B 抓包](../.artifacts/proxy-isolation-20261026-v2/independent-proxies/whistle-sessions.json)、[A 来源日志](../.artifacts/proxy-isolation-20261026-v2/origin.jsonl)、[B 来源日志](../.artifacts/proxy-isolation-20261026-v2/independent-proxies/origin-b.jsonl)、[A 截图](../.artifacts/proxy-isolation-20261026-v2/independent-proxies/concurrent-proxy-a.png)、[B 截图](../.artifacts/proxy-isolation-20261026-v2/independent-proxies/concurrent-proxy-b.png)。来源页面由真实 HTTP 服务生成，经 Whistle 转发，未用 Mock 代理或 DOM 注入代替路由验证。

保存 Cookie / LocalStorage 后正常关闭并重新启动 daemon：Space UUID、DataStore UUID、默认 Tab UUID、代理原地址及 TLS 策略保持一致，各自恢复 route=proxy-a / proxy-b。自动恢复页面的 nonce 正确；随后再次并发导航和 fetch，仍分别命中原来源，到达时间差 0.011 秒。重启后两路导航抓包 ID 分别为 `1793005991489-006`、`1793005991501-006`。

只停止 A 并确认其端口释放后，两路同时访问带 `phase=offline` 的相同 URL：A 返回 `operation_failed: Could not connect to the server.`，原生诊断为 `NSURLErrorDomain -1004 / connection_failed`，来源 A 新增请求数为 0；B 仍返回本来源 nonce，抓包 `1793005994039-008` 为 200、目标端口 60515。故障前 Direct 对照已成功读取同一公网 URL 的 Example Domain，排除了目标不可达造成假阳性；A 未回退直连或 8899。

代理参数检查覆盖 direct、1、1234、8899、65535 的接受，以及缺失端口、0、65536、负数、非数字、其他协议、远程地址、localhost、IPv6、认证、路径、query、fragment 的拒绝。端口接受检查不发起导航；8899 原有服务未被用作测试代理。

### 现有检查与清理

运行环境为 macOS 26.6.2（25G83）。以下真实 WebKit 测试使用 Debug 应用：

- `python3 tests/acceptance.py --out .artifacts/proxy-full-20261026-v2` [全部通过](../.artifacts/proxy-full-20261026-v2/report.json)：代理参数、弹窗、A/B/C/D、fetch/WSS、TLS，以及双独立代理专项。此轮另用 62812、63592 两个代理端口，重复验证了动态端口行为。
- `python3 tests/acceptance.py --direct-conflicts --out .artifacts/proxy-full-20261026` 中 [Direct 冲突专项通过](../.artifacts/proxy-full-20261026/report.json)，覆盖 HTTP、HTTPS、SOCKS、PAC、自动发现的恢复处理；只在测试 daemon 中注入设置，没有切换操作系统代理。该轮随后因前台应用从 Helium（35319）变为 Typora（69937）在 C 的焦点不变断言处停止，不能算整套通过；上面的标准套件重跑已完成 C/D，未放宽或删除断言。
- `python3 tests/reliability.py` [通过](../.artifacts/reliability-20261026-171541/report.json)，包含死循环与 Promise 超时恢复、CLI / IPC 校验、DOM 边界、诊断、持久化隔离、删除恢复及原有计时回归。未加 `--forms`，没有安装或运行 React / Vue 专项依赖。
- Debug、Release 编译、`codesign --verify --deep --strict '.build/Agent WebKit.app'`、改动 Python 文件的语法检查及 `git diff --check` 通过。最终应用包为 Release；上列完整 WebKit 套件运行于 Debug，下述双代理复验使用 Release。构建仍有既有 CLT 两个链接搜索目录警告。

[清理核查](../.artifacts/proxy-cleanup-20261026.json)：包括失败尝试在内，本次记录的 daemon / Whistle 进程均已退出，22 个测试 TCP 端口均无监听；四次验收的 Space 注册表为空。临时目录保留配置、证书和日志，遗留 Unix socket 路径连接返回 ECONNREFUSED，没有运行中的浏览器服务。用户原有 Whistle PID 95274 / 95278 仍监听 8899 / 40003（及原有 43901），未停止或重配。未修改系统代理或钥匙串；核查时系统代理各启用项均为 0。

审查后补充的异常清理回归 `python3 tests/independent_proxy_cleanup.py` 通过：注入浏览器 IPC 失联，确认代理 B（54080）与来源服务（54079）均释放端口，异常仍向调用方报告，验收报告保存为失败且 `proxyBStopped=true`。清理使用 ExitStack 保证各资源的释放不依赖 Space 清理成功，故障验证使用真实 Whistle，未用 Mock 替代进程。

`python3 tests/acceptance.py --independent-proxies-only --out .artifacts/proxy-review-20261026` 在 Release 应用上[再次通过](../.artifacts/proxy-review-20261026/report.json)，包含参数、双路并发、重启恢复和 A 停机/B 正常。[本轮清理核查及故障报告](../.artifacts/proxy-review-20261026/cleanup-check.json)确认测试端口释放、Whistle 进程退出、验收 Space 注册表为空。此轮仅修改测试清理及相关文档，Python 语法检查和 `git diff --check` 通过；未重复运行此前已通过的完整套件。

### 范围与限制

两路专项使用显式 `--ignore-certificate-errors`，没有把忽略校验表述为严格 CA 信任成功。未执行 verify-web-via-proxy 的业务页面、登录或预发验收，也未修改该技能。loopback 目标绕过 WebKit 代理的既有限制保持可见；本次路由验证使用 example.com 域名。远程代理、认证、SOCKS、运行中切换、媒体和 Service Worker 的双路行为不在本次覆盖范围。

## Issue #1：审查修复——XHR 复用诊断（2026-10-25）

修复前，新增真实 WebKit 用例稳定复现：503 响应的 onload 回调重新 open 同一 XHR 后，诊断误记下一地址的 origin 和状态 0。现在每次 send 固定请求 origin，捕获阶段保存完成结果并解除该次监听；状态 0 仍按 load/error/abort/timeout 区分结果。

`python3 tests/reliability.py --diagnostics-only` 在修复后的 Debug 应用上[通过](../.artifacts/reliability-20261025-132619/report.json)。新增用例覆盖 onload / onreadystatechange 中只重新 open，以及 onload 中连续 open/send；前两种均保留原始 503 与 origin，后一种恰好记录 503、201 两次响应（[记录](../.artifacts/reliability-20261025-132619/diagnostics-xhr-reuse.json)，完整命令见同目录 commands.jsonl）。原有诊断专项的异常、fetch/XHR 断连/取消/超时、脱敏、容量、隔离、卡死查询与恢复、重启及前台检查也通过。

Debug / Release 构建、应用签名检查和 `git diff --check` 通过，最终应用包为 Release。本次只复跑受影响的诊断专项，未重跑完整 A/B/C/D 或框架表单验收；原有用例和入口均保留。没有改系统代理或停止用户 daemon。

## Issue #1：P1 Console / 网络诊断（2026-10-24）

本批完成 `diagnostics --space NAME [--tab ID] [--clear]`。按 Tab 保留最近 200 条内存摘要，页面队列最多 100 条；原生 WebKit 与 page-script 明确分开，默认不采集 console 正文、请求头/体、响应体、表单值或 URL 路径/query/hash，保留 origin、有限类型、状态码、行列与时间信息。查询不执行 JS，页面忙碌、卡住或 Direct 暂停时仍可读取。

- Debug、Release 构建及 `codesign --verify --deep --strict '.build/Agent WebKit.app'` 通过。最终包为 Release；既有 CLT 两个搜索目录警告仍在。
- 专项 `python3 tests/reliability.py --diagnostics-only` [报告](../.artifacts/reliability-20261024-210926/report.json)通过。最终 Release 的 `python3 tests/reliability.py --forms` [报告](../.artifacts/reliability-20261024-211524/report.json)通过，保留并通过原有 DOM world、弹窗、frame/shadow、复杂表单、持久化、死循环/Promise 恢复、清理与 16 项计时检查。
- 最终 Release 的 `python3 tests/acceptance.py --direct-conflicts` [报告](../.artifacts/20261024-211552/report.json)通过：A/B/C/D、Whistle/Direct、fetch/WSS、TLS、弹窗和进程内代理设置冲突均保留。新增核对 Direct 暂停时的诊断查询，以及 TLS 拒绝原因和失败请求的正确 origin。两套测试串行运行，没有改用户系统代理或停止已有 Whistle。

[页面观测记录](../.artifacts/reliability-20261024-211524/diagnostics-page.json)包含实际 console.warn/error、TypeError、未处理 RangeError、图片资源失败、fetch 200/503/拒绝和 XHR 404/断连/取消/超时；返回内容和 Promise 拒绝仍由页面正常消费。另验证 opaque fetch 的状态 0 为 response，未误标失败。[原生记录](../.artifacts/reliability-20261024-211524/diagnostics-native.json)包含主文档 HTTP 503、连接拒绝、导航超时、取消及 JS 卡死期限，均有来源和时间字段。原始逐条命令见同目录 `commands.jsonl`。

同一调用突发 1000 条 console 警告时，页面批次上限和丢弃计数生效；继续发送后宿主只保留 200 条。测试还验证清空、伪造消息字段/来源过滤、敏感值不出现在整个诊断响应、popup/Space 隔离、子 frame 消息拒绝、忙碌查询、卡死恢复保留历史、重启清空历史及前台不变。

本轮资源样本：空应用 102.08 MiB，5 Space 406.19 MiB，重启后 321.86 MiB，删除后 155.36 MiB，退出后测试进程全部回收；启动前后前台 PID 均为 169。RSS 含共享页重复计算，仍只是短时 fixture 观察；本轮系统为 macOS 27.0.1。

早期用例未通过的原因分别是 fixture 缺少函数结束括号，以及 macOS 对“bind 但不 listen”的端口保持连接等待；修正 fixture 并改用已关闭端口后，真实错误用例通过。首轮完整验收后复核记录，还发现 TLS 失败会把 WebKit 仍显示的旧文档 origin 当作目标；现取原始失败请求 URL、保留底层 error domain/code，并把证书拒绝作为原因标注，已用不同 TLS 端口断言和最终完整回归验证。

范围仍是主 frame 摘要，console 正文和完整资源追踪不提供；页面 hook 可被覆盖或伪造，不证明真实代理路径。内容进程终止记录已接入原有公开回调，但本轮没有注入系统进程杀死；真实 OS 代理切换、worker/子 frame、Vite+Whistle HMR 和真实站点回归均不由此宣称完成。

## Issue #1：P1 复杂表单完成与完整回归（2026-10-24）

本批完成复杂表单及操作结果校验。应用仍为 Swift/AppKit/WKWebView + CLI/Unix Socket；React/Vue/Vite 只作为可选测试依赖，不进入应用包。

- `npm ci --prefix tests/forms`、Debug/Release 构建、`codesign --verify --deep --strict '.build/Agent WebKit.app'` 通过。最终应用包为 Release；仍有既有的两个 CLT 链接搜索目录警告。
- `python3 tests/reliability.py --forms` 在 Debug 上通过（[报告](../.artifacts/reliability-20261024-192527/report.json)），最终 Release 上再次通过（[报告](../.artifacts/reliability-20261024-192740/report.json)、[逐条命令](../.artifacts/reliability-20261024-192740/commands.jsonl)、[表单截图](../.artifacts/reliability-20261024-192740/forms.png)）。原有桥接隔离、弹窗、frame/shadow、超时恢复、持久化、清理及 16 项计时均保留并通过。
- `python3 tests/acceptance.py --direct-conflicts` 在最终 Release 上通过（[报告](../.artifacts/20261024-192644/report.json)）。原有 A/B/C/D、真实 Whistle/Direct、fetch/WSS、TLS 正反用例、弹窗和五类进程内代理设置冲突均通过。与可靠性套件串行运行；没有修改用户系统代理，未把进程注入当作 OS 代理开关实测。

React 19.3.1 和 Vue 3.5.44 各完成两次成功提交、一次服务端拒绝。[服务端记录](../.artifacts/reliability-20261024-192740/submissions.jsonl)恰好 6 条，包含本轮随机 nonce 和框架实际提交的文本、textarea、select、checkbox 状态；等待超时没有重复请求。覆盖中文、多行、空值、keyed 重渲染后值保留及旧引用失效、disabled/readOnly/aria 限制、contenteditable 纯文本替换。合成 click 即使触发 422 拒绝也只返回 DOM 操作完成，随后通过文本条件确认拒绝，不冒充业务成功。

前两次扩展测试未通过：第一次 fixture 的 output 样式折叠换行，改为按实际多行文本显示；第二次错误地要求 checkbox 派生 input 也必须非可信，现分别核对原始 click 和填写事件。WebKit 实测 checkbox 的 click 为 false、派生 input 为 true；fill 的 InputEvent 为 false，类型为 insertReplacementText（[事件记录](../.artifacts/reliability-20261024-192740/form-events.json)）。这不代表原生输入或可信用户激活。

资源样本：空应用 96.42 MiB，5 Space 399.62 MiB，重启后 313.75 MiB，删除后 148.86 MiB，退出后测试进程全部回收；启动前后前台 PID 均为 56420。RSS 仍包含共享页重复计算，是 fixture 短时观察。只实测 macOS 27.0.1；复杂第三方编辑器、输入法/选区、Console/网络诊断、Vite+Whistle 的 HMR 与真实站点回归仍未完成，本次本地框架测试不替代这些验收。

## Issue #1：P1 操作结果等待（2026-10-24）

`zsh scripts/build.sh` 和 `python3 tests/reliability.py` 通过：[报告](../.artifacts/reliability-20261024-191126/report.json)。新增 URL 精确匹配、文本子串、六类 DOM 状态等待，覆盖延迟完成、SPA/完整导航、缺失/隐藏/多匹配/过期引用、frame/shadow 作用域和参数冲突。原有 bridge、弹窗、作用域、死循环与 Promise 恢复、持久化、清理和 16 项计时均通过。

等待只验证指定页面条件，不证明业务成功；URL 匹配不等于文档加载完成。该提交时尚未完成 React/Vue 表单实测，后续完成情况见上节。

## Issue #1：P1 首批与最终回归（2026-10-24）

本轮在原有 Swift/AppKit/WKWebView、CLI + Unix Socket 架构内完成三项 P0 的实现，并推进 P1 的开放 Shadow DOM / 同源 iframe 支持；真实 OS 代理切换仍保留为未完成验收。以下为最终源码的运行记录，旧章节的能力限制以本节及 P0 各节更新为准。

- `zsh scripts/build.sh`、`zsh scripts/build.sh release` 和 `codesign --verify --deep --strict '.build/Agent WebKit.app'` 均通过，最终应用包为 Release。本机 CLT 链接器仍提示两个不存在的搜索目录，未出现源码编译警告。最低声明仍为 macOS 14+，此次只实测 macOS 27.0.1，签名仍为本机 ad-hoc。
- `python3 tests/reliability.py`：[最终报告](../.artifacts/reliability-20261024-190158/report.json)，原有死循环/Promise 超时恢复、DOM/CLI 边界、持久化、删除清理、16 项计时和新增 bridge/弹窗/作用域测试全部通过。
- `python3 tests/acceptance.py --direct-conflicts`：[最终报告](../.artifacts/20261024-190215/report.json)、[逐条命令](../.artifacts/20261024-190215/commands.jsonl)、[Whistle 会话](../.artifacts/20261024-190215/whistle-sessions.json)、[来源日志](../.artifacts/20261024-190215/origin.jsonl)。串行运行，原有 A/B/C/D、TLS、fetch/WSS，以及五类进程内代理冲突和真实 Whistle 弹窗全部通过；空应用资源采样在新增用例之前进行。

P1 新增实测：普通 DOM、嵌套开放 Shadow Root、同源 frame 及 frame 内 Shadow Root 的 snapshot/click/fill/wait；同名 ID 不串用、frame 原型 setter 和非可信 input 事件、select 填写、隐藏宿主/frame、display:contents 宿主；frame 同源及跨源导航、宿主替换和刷新后旧引用均返回 `stale_ref`。跨源 frame 与显式进入 closed root 均返回 `unsupported_context`。closed root 无法枚举，snapshot 明示限制；文本仍仅主 frame，子 frame 坐标仍是其自身视口。未宣称支持原生输入或全部富文本组件。

最终资源样本：空应用 RSS 合计 96.42 MiB，5 个 Space 400.11 MiB，重启后 315.67 MiB，删除后 149.75 MiB，退出后测试进程全部回收。启动前后前台 PID 均为 56420。RSS 含共享页重复计算，这仍是 fixture 短时观察，不是复杂网站长期性能结论。

最终复跑曾再次触发重复 TLS 失败导航误报（[失败报告](../.artifacts/20261024-185944/report.json)），说明 P0-2 阶段只检查已追踪导航序列仍不足。现增加无导航对象时的 pending 状态及直接证书错误检查，并在 TLS 测试中对错误主机名、过期证书各追加三次失败导航；上述最终两套测试均通过。

本批停止在 P1 第一项。React/Vue 复杂表单、Console/网络诊断、Vite HMR 和真实站点登录回归，以及 P2 的长期资源、真实进程崩溃、旧系统实机验证等继续由 Issue #1 跟踪；不把本地 fixture 当作这些场景的验收。

## Issue #1：P0-3 与 GUI 补验（2026-10-24）

`python3 tests/reliability.py` [报告](../.artifacts/reliability-20261024-184946/report.json)通过 Direct 弹窗回归与原有可靠性/16 项计时检查。随后独立运行 `python3 tests/acceptance.py --direct-conflicts` [报告](../.artifacts/20261024-185037/report.json)，五类冲突、真实 Whistle 弹窗和原有 A/B/C/D、fetch/WSS、TLS 全部通过；该次未与其他测试并行，可用于资源观察。

弹窗覆盖 target blank、window.open、302 重定向、opener 的 postMessage 和父页 hash 回调、window.close、命名窗口复用、关闭父页后最后一个子窗口的清理、显式 Tab 控制、双 Space Cookie/LocalStorage 隔离、CLI 默认 Tab 不变、重启后的 ID/URL、前台 PID 不变。Whistle 会话中有弹窗和重定向真实请求；custom-ca 弹窗接受合规证书，拒绝错误主机名及过期证书。要求可信点击的 fixture 对 DOM click 返回 `popup_not_opened`，不支持的 scheme 返回 `unsupported_navigation`。

`python3 tests/ui_fixture.py --conflict` 创建了[独立 GUI 测试应用](../.artifacts/ui-20261024-185154/fixture.json)。原生 UI 实查：侧栏和横幅显示 Direct 暂停、原因和恢复方法；解除进程内设置后点重新加载恢复原 URL；点击 Require trusted click 实际读到 `isTrusted=true` 并出现同 Space 新 Tab，GUI 仍停留父页，CLI 默认也不变；手动切换子页并点击回调关闭，父页显示 `manual-result`，子 Tab 消失。外部 scheme 的拒绝横幅可见。关闭观察窗口后，CLI 仍可打开弹窗并生成[后台截图](../.artifacts/ui-20261024-185154/background.png)。测试 Space 已删除、测试应用已退出，用户原有应用未被关闭。

这些是受控本地登录回调流程，不是实际第三方 OAuth 服务验收；重启不恢复内存中的 opener/回调关系。真实 OS 代理切换、跨源登录站点和 WebKit 自身的弹窗抑制分支仍未单独覆盖（已覆盖网站依据 isTrusted 拒绝的确定性分支）。

## Issue #1：P0-2（2026-10-24）

`python3 tests/acceptance.py --direct-conflicts` [报告](../.artifacts/20261024-184539/report.json)通过：HTTP、HTTPS、SOCKS（嵌套接口）、PAC、自动发现五类冲突下，真实 daemon 均可重启；状态查询和 Whistle 域名请求继续工作，Direct 明确拒绝加载。解除冲突后 reload 保留 Cookie、LocalStorage、Tab ID 和 URL；页面自行发起的导航也会被拒绝。原有 A/B/C/D、TLS、fetch/WSS 全部通过。`python3 tests/reliability.py` [报告](../.artifacts/reliability-20261024-184553/report.json)及 16 项计时检查通过。

设置来自仅测试进程可见的 CFNetwork 返回值注入；没有修改用户的系统代理，没有关闭已有 Whistle。**尚未在独立 macOS 系统环境切换真实代理设置**，此项不标为实际系统切换验收通过。GUI 已增加 Space 暂停标记及恢复提示，本阶段尚未完成独立测试窗口的手动检查。两套测试曾同时运行，资源数字可能包含另一个测试的 WebKit 进程；最终资源结论以独立运行的完整验收为准。

首轮完整验收暴露了 TLS 拒绝时旧文档 readyState 被当作导航成功的竞态（[失败报告](../.artifacts/20261024-184433/report.json)）。等待现在要求已追踪导航完成并复核错误；保留 URL 也避免在导航未结束时被旧文档覆盖，随后上述完整验收通过。

## Issue #1：P0-1（2026-10-24）

Debug 应用实测通过 `python3 tests/reliability.py`（[报告](../.artifacts/reliability-20261024-184222/report.json)）和 `python3 tests/acceptance.py`（[报告](../.artifacts/20261024-184233/report.json)）。A/B/C/D、真实 Whistle 域名分流、fetch/WSS、TLS 正反用例、并发、资源回收及原有 16 项计时检查均保留并通过。

新增用例在页面 world 中覆盖、删除、伪造 `__agentWebKit`，隔离 world 的 snapshot/click/fill/wait 仍读写真实 DOM；页面变量及 Promise 仍可通过 evaluate 访问。SPA 保留连接节点引用，移除节点、刷新和重启使旧引用失效；恢复后的页面重新注入，后台 PNG 与前台 PID 不变检查通过。测试曾暴露启动恢复期间 bridge 尚未注入时的 wait 异常，已改为等待初始化，并完整复测通过。原有死循环和 Promise 超时恢复仍通过。

这不防止页面修改 DOM 或伪造业务内容；未增加跨源 frame、原生输入或其他能力声明。

## 0.2.0：2026-10-24

在同一台 macOS 27.0.1 / Apple Silicon 机器上完成 Debug 与 Release 构建。最终应用包为 Release，`codesign --verify --deep --strict` 通过。下面两套测试均以最终应用包运行并退出 0：

- `python3 tests/acceptance.py`：[完整报告](../.artifacts/20261024-014112/report.json)、[逐条命令](../.artifacts/20261024-014112/commands.jsonl)、[Whistle 会话](../.artifacts/20261024-014112/whistle-sessions.json)、[来源站点日志](../.artifacts/20261024-014112/origin.jsonl)。
- `python3 tests/reliability.py`：[恢复与边界测试报告](../.artifacts/reliability-20261024-014208/report.json)、[逐条命令](../.artifacts/reliability-20261024-014208/commands.jsonl)、[恢复后的真实截图](../.artifacts/reliability-20261024-014208/recovered.png)。该脚本还运行了原有的 16 项计时检查。

| 项目 | 本轮结果 |
| --- | --- |
| 原有 A / B / C / D 与 TLS | 全部通过：Cookie / LocalStorage 隔离及重启持久化、真实域名分流、证书正反用例、并发、截图与资源回收 |
| fetch 与 WSS | 代理 Space 收到本地服务的随机 nonce 与 WebSocket echo；Whistle 与来源日志均有对应请求。direct 未新增代理会话、未命中本地服务。公网上的 example.com 不提供测试 echo，direct WSS 超时，不将其当成可用性证明 |
| 真正卡住的 JavaScript | `while(true) {}` 和永不完成的 Promise 均按期限返回；Space 锁释放；另一个 Space 仍可操作。显式 reload / open 恢复后保留 Tab ID 和 LocalStorage |
| 查询与标签页 | 忙碌时 state / tab list 可读；tab default 持久化；关闭默认页后选择剩余页；SPA URL 及元素引用失效行为通过 |
| DOM 与参数 | 禁用字段、不可用 select 选项、密码隐藏、元素可见性、无效／多重选择器、字面值参数、CLI 与原始 IPC 选项校验通过 |
| 删除与恢复 | 故障恢复后立即删除可清除并核对网站数据；若空容器仍被 WebKit 占用，则准确返回 cleanupPending。同名重建不读取旧数据；重启后 pendingStoreCleanup 归零、旧记录清除 |
| 前台 | 启动前后及两 Agent 并发操作前后，前台 PID 均保持 56420 |

原生窗口用 UI 自动化实查了 Space 搜索与切换、标签页切换、快捷键、选择恢复、信息弹层、空白页引导和错误提示。窗口选中第二个 Tab 时，CLI 在固定默认 Tab 完成填写和点击，GUI 未被切走；切回后能看到结果。另将页面置于真实死循环，通过窗口的“重新加载”按钮恢复，再用 CLI 读回正常标题。初版紧凑尺寸和最终 1220 × 800 布局均检查过；最终版本的最小尺寸、深色外观和不同显示缩放还未逐项实测。

本轮资源样本：空应用 RSS 合计 97.52 MiB；5 个 Space 393.14 MiB；重启恢复后 314.64 MiB；删除全部 Space 后 151.75 MiB；退出后测试进程全部回收。RSS 含共享页重复计算，短时采样不代表长期运行上限。

仍有边界：Snapshot 仅主 frame 普通 DOM，截图仅视口，输入为 DOM 合成事件；loopback 代理、原生输入、MCP 等仍按原约定暂缓。WebContent 终止回调与恢复路径已实现，但尚未单独注入系统进程崩溃测试；媒体、Service Worker、旧版 macOS、长期运行和断电恢复未全面验证。应用仍使用本机 ad-hoc 签名，未做分发签名与公证。

## 0.1.0 历史记录

以下保留上一版测试证据。其“未实现”和后续建议反映当时状态，当前能力以上面的 0.2.0 记录为准。

2026-10-23，在本机 macOS 27.0.1（26A434、Apple Silicon）、Swift 6.4、macOS 27 SDK 上构建并运行。未安装完整 Xcode，使用 Command Line Tools 完成构建和应用包 ad-hoc 签名校验。

**结论：A、B、C、D 和新增 TLS 测试通过。B 按用户调整后的范围，验证真实域名经 Whistle 映射到本地服务；loopback 代理路由暂不纳入验收。**

最终自动验收命令为 `python3 tests/acceptance.py`，进程退出码 **0**。使用本机已安装的 Whistle **2.10.2**，不使用模拟代理替代 B。最终源码测试产物：

- [完整 JSON 报告](../.artifacts/20261023-203422/report.json)
- [逐条 CLI 请求与响应](../.artifacts/20261023-203422/commands.jsonl)
- [来源站点实际请求](../.artifacts/20261023-203422/origin.jsonl)
- [Whistle 实际会话](../.artifacts/20261023-203422/whistle-sessions.json)
- [B 代理页面截图](../.artifacts/20261023-203422/b-proxied.png)、[B 直连页面截图](../.artifacts/20261023-203422/b-direct.png)
- [并发 admin 截图](../.artifacts/20261023-203422/admin.png)、[并发 user 截图](../.artifacts/20261023-203422/user.png)

`.artifacts` 为本次本机证据，已加入 gitignore；重新运行会生成新的时间目录，不会覆盖旧结果。

| 验收 | 结果 | 实际观察 |
| --- | --- | --- |
| A：会话隔离与重启 | 通过 | 两个 UUID Store 分别保存 `shared=A/B` Cookie 和 LocalStorage；互相读取不到对方值；应用退出、重启后值不变。第二个 Tab 共享自己 Space 的数据，Tab / Space ID 均恢复 |
| B：真实域名 HTTPS 经 Whistle / direct | 通过 | 同一 URL，代理 Space 显示本地 Fixture 与随机 nonce，direct 显示公网 Example Domain；direct 没有增加 Whistle GET 会话，也没有到达本地站点 |
| TLS：按 Space 的 CA / 忽略策略 | 通过 | 正确 CA 与合规证书成功；无关 CA、错误域名、过期证书被拒绝；显式忽略后可加载，但没有让其他 Space 的严格校验失效；新 Tab 与重启保持策略，CA 源文件移走后仍恢复 |
| C：两独立 CLI 进程并发 | 通过 | 两个 Agent 同时导航到故意延迟 0.8 秒的站点，来源站点收到请求的时间差小于 1 ms；分别填写 Alpha / Beta、点击并截图。整个并发流程约 1.298 秒；没有串台 |
| D：5 Space、销毁和重启 | 通过，含资源观察 | 5 Space 各有一个页面，全部重启恢复；公开删除 API 返回成功，同名重建分配新 UUID 且读不到旧数据；资源变化见下表 |

## B 与 HTTPS 的实际证据

两个 Space 同时使用 `https://example.com/?agent_webkit=9ac318c3dbbe4fbb9a56a8b32681673c`。Whistle 规则将 example.com 转到 `http://127.0.0.1:54522`，浏览器地址不变。

- 代理页标题为 Agent WebKit Fixture，返回的 nonce 为 `9ac318c3dbbe4fbb9a56a8b32681673c`；本地站点记录该请求，TCP 来源端口为 **54541**。
- Whistle 记录实际 HTTPS GET，会话 ID 为 **1792758866250-006**。direct 操作前后的同 URL 会话 ID 集合不变。
- direct 页标题为 Example Domain，nonce 为空；本地站点没有新增同 nonce 请求。
- 关闭测试 Whistle 的进程组，并确认 8899 不再监听后，再次代理导航返回 Could not connect to the server，没有通过直连加载成功。

本次使用临时规则、独立数据目录和测试专用 CA，不改已有 Whistle 规则、系统代理或钥匙串。Whistle CLI 的 `run` 会生成服务子进程；测试为其建立单独进程组，结束时只关闭自己的进程组，避免误把 CLI 退出当作代理已停止。

本机原有 Whistle CA 已受系统信任，默认策略可以访问它，因此不能单凭该环境证明 `--ca-cert` 生效。使用临时 CA 后，默认策略拒绝代理证书；添加 CA 后又发现 Whistle 2.10.2 动态证书缺少 `serverAuth` EKU，严格评估报告 **ServerAuthEKU** / certificate is not permitted for this usage。没有删除这项校验来凑通过。

所以 B 显式使用 `--ignore-certificate-errors` 的开发 Space；结果中的 `tls.policy=insecure`、`certificateErrorsIgnored=true` 与警告均可见，默认策略 Space 在它成功前后仍拒绝该证书。另用带正确 SAN / EKU 的本地 HTTPS 服务验证 `--ca-cert` 真正成功，以及错误域名、过期证书、无关 CA 的拒绝。原 CA PEM 文件移走、浏览器重启后仍可验证成功，证明保存的是 CA 数据。

前一次基于 loopback 的失败记录保留在 [.artifacts/20261023-193643](../.artifacts/20261023-193643/report.json)，不把域名分流通过解释为 loopback 也通过。

## 前台与 GUI

本轮自动测试通过 NSWorkspace 读取前台进程：启动前后及两 Agent 操作前后均为 PID **56420**，没有变成浏览器进程。后台截图分别显示 Alpha / Beta，页面 click 的 `isTrusted` 实际为 false，与 CLI 报告的 DOM 合成语义一致。

另用原生 UI 自动化实际检查窗口和切换 Space：GUI 显示 `observer-b` 时，CLI 对 `observer-a` 填写并点击 `background-A`；B 仍显示 Ready，标签选择没有被切走。切回 A 后显示 background-A。CLI 操作前后的前台 PID 保持 57509。该补验创建的 Space 和服务均已清理。

同时验证了：缺少 Space、跨 Space Tab ID、无效代理、互斥证书参数、等待超时、旧元素引用、重复 daemon 均返回错误；重复 daemon 没有覆盖运行中的 Socket。

## 资源实测

以下是 `ps` 的 RSS 合计和约 2.06 秒 CPU 时间差采样，100% 表示一颗 CPU 核心。RSS 包含共享页重复计算，不是独占物理内存；WebKit XPC 的 PPID 为 1，测试根据启动前后新增的 WebKit PID 归属，其他应用活动可能影响该归属。简单站点、短采样，不能代表复杂网站或长期稳定性。

| 状态 | 相关进程 | RSS 合计 MiB | 采样 CPU |
| --- | --- | ---: | ---: |
| 空应用 | 1 个应用进程 | 80.69 | 0.48% |
| 5 个 Space，各一页 | 应用 + 7 WebContent + 1 Networking + 1 GPU | 380.61 | 0.97% |
| 重启恢复 5 页 | 应用 + 5 WebContent + 1 Networking + 1 GPU | 299.11 | 2.41% |
| 删除全部 Space 后 | 应用 + 1 GPU | 135.20 | 0.48% |
| 关闭应用后 | 本轮相关进程全部退出 | 0.00 | 0.00% |

首次 5 页采样前已经运行证书和多页面测试，因此还有两个额外 WebContent 进程；仅重启恢复 5 页后为 5 个 WebContent。删除后仍保留的 GPU 进程及应用内存属于本次观察到的 WebKit / AppKit 常驻开销，没有声称内存完全回到初始值。退出应用后这些进程已退出。没有进行额外性能优化或长期压力测试。

## 已实现且验证

- 原生应用包、AppKit 观察窗口、Space 切换、CLI + 本机 Unix Socket JSON 服务。
- Space 创建 / 查询 / 删除，持久化 UUID DataStore、多 Tab、重启恢复 URL 和数据。
- DOM Snapshot 稳定引用、旧引用拒绝、CSS selector、click / fill、Evaluate、视口 PNG、页面加载 / 元素等待。
- 不同 Space 并发、隐藏 Space 的 DOM 与截图、命令不依赖 GUI 选择、不抢前台。
- 真实 Whistle 的 HTTPS 域名分流、代理断开后失败、按 Space 的证书策略与持久化。

## 已实现但尚未完整验证

- 复用带 UI 认证的已有 Whistle 实例；当前自动脚本未提供认证参数。
- WebSocket、媒体、Service Worker 和全部子资源的网络与证书路径。
- 系统代理已启用时的拒绝分支；未为测试改动用户系统配置。当前系统代理状态均为关闭。
- macOS 14–26 实机兼容性、长期运行、异常断电 / 强制结束时的持久化耐久性。待删除 tombstone 的重启重试已实现，未故意注入删除失败验证该恢复分支。

## 当前失败与限制

- loopback 代理路径此前未通过，当前暂不纳入验收，不能保证经过 Whistle。
- Whistle 2.10.2 动态证书缺少 EKU 时，`--ca-cert` 仍会拒绝；可使用符合要求的站点证书，或为受控开发 Space 显式忽略证书错误。忽略模式也接受主机名和过期错误，不应用于需要 TLS 真实性保证的 Space。
- `direct` 没有公开的强制绕过系统代理开关；遇到已启用系统代理会拒绝运行 direct Space。不能绕过 VPN、透明代理和内容过滤器，不能保证命令之间系统代理改变时的页面自主请求路径。
- Snapshot 仅主 frame 普通 DOM；无 iframe / Shadow DOM 深入遍历。截图仅视口。DOM 事件不等于真实输入。
- WebKit 会节流隐藏页面；无限 JS 的可靠取消、进程崩溃后恢复、弹窗新标签、完整后退历史均未实现。

## 下一阶段

继续验证 WebSocket / 子资源路径、JS 超时取消和 WebContent 崩溃恢复；需要时再决定是否恢复 loopback 代理实验。原生输入与剪贴板仍是后续独立能力，不能以 DOM 合成事件替代。
