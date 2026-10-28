# 开发与测试

```sh
zsh scripts/build.sh          # debug + 本地 ad-hoc 签名 .app
zsh scripts/build.sh release  # release + .app
python3 tests/acceptance.py --out .artifacts/acceptance
python3 tests/reliability.py  # 独立应用、本地页面、超时恢复和计时回归
```

Swift Package 无第三方包。`scripts/build.sh` 生成 `.build/Agent WebKit.app`，包含固定 Bundle ID、原生绘制的图标和允许 Web 内容联网的 ATS 配置。签名仅供本机开发，不包含公证或分发证书。测试使用 `.build/debug/browser` 作客户端，使用应用包中的 `browser daemon` 启动服务；测试前至少构建一次 debug，并确保客户端与应用包来自相同源码。`scripts/make_icon.swift` 以 AppKit 绘制各尺寸图标，再由系统 iconutil 打包，不需要图片生成服务或外部依赖。

## 离线帮助与机器可读契约

```sh
browser help                    # 保留 result.usage
browser help space              # 命令组
browser help space create       # 或 browser help open
browser capabilities
python3 tests/contract_cases.py  # 不存在的 Socket / 数据目录，验证纯离线查询
python3 tests/reliability.py --forms  # 含真实 CLI / IPC 对照和原有可靠性回归
```

`help`、`capabilities`、`version` 在 CLI 本地返回，也可通过原有 Socket 查询。帮助使用 `help COMMAND [SUBCOMMAND]`，不是给任意操作追加 `--help`；`--` 后的表单值仍按字面处理。命令数量、位置参数范围和允许选项共用 `Request` 校验定义；必需项、互斥项及条件约束由元数据补充，服务端继续执行原有语义校验。

`capabilities` 的 `result.schemaVersion` 为 1，与产品 `version` 分开。`commands` 列出命令、参数名称/数量、选项类型/必需性、超时单位/范围/默认值、CLI/IPC 可用范围和离线属性。IPC 的选项值始终为字符串，无值 CLI 开关对应 `"true"`。`constraints` 保存 click/TLS/wait 的组合限制；`errors` 是已知结构化错误码，底层未分类错误使用 `operation_failed`，不能据错误码自动重放有副作用的操作。

`schemas.$defs` 是 JSON Schema 2020-12 的请求、响应及结果外层定义；`commands[].resultSchema` 指向其中一个定义。它描述必有字段和集合形状，允许新增字段；网页 `value` 为任意 JSON，不把页面数据当作可信指令。位置参数数量、允许选项与条件限制仍需结合命令元数据，不能只用通用 request schema 代替服务端校验。`daemon` 只可由 CLI 启动长期进程，没有单条成功结果；原始 IPC 不支持启动 daemon。

既有 `ok/result`、`ok/error.code/error.message`、退出码 0/1 与可选 timing 保持兼容。离线成功响应不伪造 IPC 或 WebKit 耗时。`scope` 明确固定目标、同 Space 串行、DOM 合成、快照/截图、超时恢复及代理限制；声明可用不等于真实站点兼容、代理路径或业务结果已验证。

## Codex / Pi Skill

`skills/agent-webkit/SKILL.md` 是对应 CLI 0.2.0 / 契约 v1 的单文件 Skill，直接调用现有 CLI；无安装脚本、MCP 或另一套浏览器客户端。参数和返回结构查当前二进制的 `capabilities` / `help`，Skill 只保留目标归属、动作与业务验证、失败恢复、弹窗/人工接管和共享服务清理约定。

用户确认安装后，可将整个 `skills/agent-webkit` 目录复制或链接到 `~/.agents/skills/agent-webkit`（个人范围）或使用项目的 `.agents/skills/agent-webkit`（项目范围）。这两种位置由 [Codex 官方文档](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills)和 [Pi 官方文档](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md#add-it-to-pi)说明；同一位置可能被两个 Agent 发现。已有同名目录时先核对，不覆盖既有内容。仓库中的 `skills/` 只是发布源，构建/测试不会自动安装到发现目录或改动用户配置。

Codex 可显式调用 `$agent-webkit`，Pi 使用 `/skill:agent-webkit`；也可在单次任务里提供本仓库 SKILL.md 的绝对路径，让 Agent 读取后执行，不做持久安装。先把打包应用的 `browser` 加入 PATH，或在任务里提供绝对可执行文件路径与既有 Socket；Skill 不擅自安装 CLI 或启动/停止共享 daemon。

```sh
python3 tests/skill_workflow.py
```

这是可选的真实 Codex CLI 集成测试，需要已有 Codex 登录和正常模型访问，可能消耗账户额度。它使用临时工作目录、独立注册表/Socket、Direct 本地 fixture、两个 Space 与非默认目标 Tab，通过 `codex --no-daemon ... exec --ephemeral` 显式读取仓库 Skill。仅对这次进程开启 sandbox 的网络访问以连接本机服务，不写配置文件；不安装 Skill、Pi 或修改系统代理。场景要求处理已失效按钮引用、保存一次、等待永不出现的确认标记，宿主独立核对保存计数/值、另一 Space、固定默认 Tab、GUI 与前台。逐条 Agent 事件、最终回答、宿主命令和报告保存在 `.artifacts/skill-codex-*/`，退出删除自有 Space 并停止测试服务。

失败清理逐项尝试删除自有 Space，IPC 或删除错误不会跳过后续清理；daemon 优先正常退出，有界等待失败后仅终止自己的进程，HTTP 服务始终独立关闭。清理错误保存为 `cleanup-errors.json`，原测试异常继续上抛；若只有清理失败，整轮仍失败，不生成成功报告。此时数据删除可能未完成，不能把停止进程当作删除 Space。`python3 -m unittest discover -s tests -p test_skill_cleanup.py -v` 注入断连、删除/退出失败、有界终止及 HTTP 关闭错误，不调用模型或操作已有服务。

显式路径调用不等于安装后的自动发现验证；Pi 不可用时不跳过后记作通过，继续在 Issue #7 保留其实际调用待办。普通可靠性、代理与公网回归不依赖 Codex 或 Pi。

## 操作结果等待

`wait` 的 `--url`、`--text`、`--state` 互斥，CLI 和原始 IPC 均校验。URL 精确匹配 `location.href`，包括 SPA history/hash；它不保证文档已加载，也不代表服务器完成业务。文本为可见目标的 `innerText` 子串，不带选择器时只查主 frame 的 body。元素状态沿用唯一选择器、`>>>` 和引用作用域：hidden 包含节点不存在，attached/detached 只判断是否存在；enabled/disabled 要求元素可见，并检查原生禁用及 `aria-disabled`，readOnly 不算 disabled。过期引用始终报 `stale_ref`，要等节点被删除应使用选择器。

所有等待都在原有命令期限内轮询，不重复 click/fill；输入和点击仍返回 `businessOutcomeVerified: false`。用业务结果文本或 URL 独立核对结果，不能把 DOM 操作成功当成提交成功。`tests/wait_cases.py` 随可靠性套件验证延迟状态变化、SPA/完整导航、作用域、失败与超时。

## React / Vue 表单回归

```sh
npm ci --prefix tests/forms
python3 tests/reliability.py --forms
```

测试使用锁文件固定的 React 19.3.1、Vue 3.5.44 和 Vite 8.3.5，需 Node.js 20.19+ 或 22.12+。这些依赖仅用于测试页面，不进入 Swift 应用或普通可靠性套件。临时 Vite 服务绑定 loopback 随机端口，只写该次 `.artifacts/reliability-*/submissions.jsonl`，退出时停止自己的进程；不改变系统代理，也不占用用户的 5173。

React fixture 使用 value/onChange，Vue 使用 v-model，分别验证 input/textarea/select/checkbox、中文/多行/空值、key 改变后的状态保留及旧引用失效、disabled/readOnly、服务端拒绝提交。成功必须同时满足框架渲染状态、真实 POST 数据和服务端随机 nonce；完整运行应只有 6 次提交，超时等待不能重放请求。该页还验证 contenteditable 整段纯文本替换、非可信 InputEvent 和 aria-readonly，并保存后台截图、核对前台 PID。表单写入沿用目标 realm 的原生 setter，文本 input 事件带 `inputType=insertReplacementText`，select 保持普通 input/change 事件；不模拟 beforeinput、输入法组合、选区或第三方富文本编辑器私有状态。

表单模式只通过 Direct 加载本地 Vite 页面，**不是** Vite + Whistle 的域名/WSS/HMR 验收；后者使用下面的独立入口，真实第三方站点回归仍由 Issue #1 跟踪。框架用法依据 [React 受控输入](https://react.dev/reference/react-dom/components/input)与 [Vue 表单绑定](https://vuejs.org/guide/essentials/forms.html)，兼容性结论仅来自本仓库实际运行的这些用例。

WebKit 在 DOM click 切换 checkbox 后，可能把派生的 input 事件标为 `isTrusted=true`；发起它的 click 仍是 false，也不证明有原生用户激活。测试分别记录 checkbox 的 click 与 input，以及 fill 主动派发的非可信 InputEvent，避免把这些事件混为一谈。

## Vite + Whistle 域名与 HMR 回归

```sh
npm ci --prefix tests/forms
python3 tests/acceptance.py --vite-only
python3 tests/acceptance.py --vite --direct-conflicts  # 同时保留完整 A/B/C/D 等验收
```

复用表单测试锁定的 Vite 8.3.5，不增加应用依赖。`tests/forms/vite-workflow.mjs` 启动随机端口的 HTTP Vite 服务，使用每次输出目录里的 `tests/vite` 副本；只修改副本的 revision 模块。单独的测试 Whistle 将 `example.com` 映射到该端口，开启 HTTPS capture。两个代理 Space 均显式使用测试用 `--ignore-certificate-errors`，不代表严格 CA 信任通过。

实际项目可以沿用这两条 Whistle 规则（把端口换成自己的 Vite 端口）：

```text
example.com http://127.0.0.1:5173
example.com enable://capture
```

Vite 8 的服务配置使用 `allowedHosts: ['example.com']` 和 `ws: { protocol: 'wss', host: 'example.com', clientPort: 443 }`，然后在代理 Space 打开 `https://example.com`。客户端 WSS 仍访问该域名的 443，经 Whistle 转成 Vite 的本地 WS；不依赖 HMR 客户端回退到 loopback。应用不修改系统代理；localhost/127.0.0.1 目标的 WebKit 代理限制仍保留。

验收并发打开两个隔离 Space，核对页面、fetch nonce、Cookie/LocalStorage 隔离，三次真实文件修改后文档实例 ID 与各自计数不变。切换 CLI 默认 Tab 到空白页后仍显式操作原 Tab；跨 Space Tab ID 和旧引用被拒绝，等待不存在的版本超时而不重放动作。随后重新导航并重启 daemon，核对 ID、代理、TLS、持久数据及新一轮 HMR。Direct 访问相同公网 URL 必须显示 Example Domain，不能新增 Whistle 会话或 Vite 来源请求。所有 Agent 操作检查前台 PID 不变；本专项不操作 GUI 选择。

`vite-workflow/` 保存复制后的项目、Vite 日志、HTTP/upgrade/HMR 回执来源日志、Whistle 会话、页面截图和详细报告。必须同时看到实际 HTTPS 模块/fetch 请求、WSS `101` 及本地端口/规则匹配、每版本来自两个文档的 HMR 回执，不能只凭页面脚本或截图认定代理成功。退出或失败时删除测试 Space、停止自有 Whistle/Vite；原有服务与源码不变。`--vite-only` 不与其他专项或复用代理模式混用，`--vite` 的完整验收仍可使用原有参数。

每版本必须恰有两条回执，且 `documentId` 集合与该阶段两个页面实际采集的 ID 一致；重启后在发布新版本前重新采集，不能复用重启前 ID。报告的 `hmrExpectedDocumentIds` 保存对应关系。`python3 -m unittest discover -s tests -p test_workflow_guards.py -v` 可独立验证重复、缺失、错误及重启前文档 ID 的拒绝，不需要启动服务。

## 公网真实站点回归

```sh
python3 tests/acceptance.py --real-sites-only
python3 tests/acceptance.py --real-sites-only --real-sites-gui
python3 tests/acceptance.py --real-sites-only --real-site-case login  # spa / login / all
python3 tests/acceptance.py --real-sites --vite --direct-conflicts
```

默认套件不依赖这些外部站点；`--real-sites` 在完整验收前追加，`--real-sites-only` 单独运行。网络、站点布局或脚本加载发生变化时保存失败，不跳过断言，也不替换成本地页面。使用 Direct、默认系统证书校验和新建的独立 Space，不读取用户已有会话。

SPA 目标是 [Vue 官方文档](https://vuejs.org/guide/introduction.html)。等待真实应用 hydration 后，用 snapshot 引用操作页面计数按钮和侧栏路由；两个独立 CLI 工作流并发切换 Introduction、Reactivity Fundamentals、Computed Properties，核对 URL、标题和文档标记。标记仅用于观察文档是否重载，不改 DOM、应用状态或路由；`performance.timeOrigin` 仅作诊断，因为本机同文档读数曾有 1 ms 浮动。随后再次交互、验证缺失元素等待超时，并分别后台截图。CLI 始终显式绑定 Space/Tab，第二个 Tab 不改变默认目标。

登录/弹窗目标是 [The Internet](https://the-internet.herokuapp.com/login)，仅使用网页公开的演示账号，不读取用户凭据。两个 Space 同时验证成功登录和错误密码，未登录 Space 访问 `/secure` 必须被服务器重定向；由 `/windows` 的实际链接打开子 Tab 后，在其中访问 `/secure`，核对继承会话及系统 TLS 策略。从子 Tab 退出，父 Tab 重载后也必须失去会话；另一 Space 的登录独立有效，再反向验证登录/退出。覆盖有界等待、后台截图、关闭子 Tab、重启后的 ID/URL 与未登录 Space 不凭空获得会话。登录、退出只在明确测试步骤执行一次，失败/超时不自动重放。

该站 `_blank` 链接没有 `rel="opener"`，按 [HTML 规则](https://html.spec.whatwg.org/multipage/links.html#link-type-opener)使用隐式 noopener；专项核对子页 `window.opener === null`，不改网站属性来强行开启它。宿主 `openerTabId` 记录创建关系，不代表网页一定能访问 opener。原有本地显式 opener/postMessage/回调用例继续保留。这个站点分别提供登录和新窗口页面，没有真实第三方 OAuth 提供商交互，不代表 OAuth 全自动兼容。

重启后的登录状态按实际页面记录为 `authenticated` 或已回到登录页，可能受 Cookie 生命周期和服务端策略影响；不承诺会话 Cookie 等同带有效期的持久 Cookie，已退出的 Space 则必须仍未登录。测试不读取或保存服务端 Cookie/token 的值，只有网站公开的演示密码会出现在测试参数和该站帮助文字中。测试失败时保存主 Tab snapshot 和错误，便于区分站点变动、环境不可达与实现问题。

GUI 模式复制一个独立 Bundle ID 的测试应用，打印原生操作检查点；操作者实际完成界面选择或关窗后，输入 `confirmed` 继续。它会激活测试窗口，检查点明确标记 `requiresForeground: true`，普通 CLI 操作仍检查前台 PID 不变。选中 A 的非默认 Tab 后操作默认 Tab，随后切换到 B；程序用 `status.observer` 断言观察目标未被 CLI 切走，并在关窗后继续并发操作、截图，确认窗口保持隐藏。GUI 工具若查询隐藏应用可能重新激活窗口，关窗后应直接读取 CLI 状态。拒绝检查点或状态不符均失败，不能仅凭输入确认认定通过。没有 GUI 实查的普通运行返回 `guiVerified: false`。

登录 GUI 检查先观察未登录的 B，A 的登录和弹窗不应切走 GUI 或改变 CLI 默认 Tab；随后选择 A 的认证子 Tab、核对 Secure Area 并关窗，继续在后台完成跨 Tab 退出和 B 登录。普通 GUI 检查点需要人工或原生 UI 工具实际执行；脚本不会自动代替操作者确认。

两组流程通过同一个 `site_gui_checks` 绑定各自的回调、Space 映射和报告，沿用相同的目标/可见性断言及成功记录逻辑。操作者拒绝确认或宿主状态不符时仍直接失败；没有 GUI 回调时检查点不查询或写入 GUI 状态。上述 `test_workflow_guards.py` 同时覆盖这些辅助逻辑，不能据此声称完成新的原生 GUI 实查。

`status.observer` 是只读宿主快照：`visible` 为原生观察窗口可见性，`spaceId`、`tabId` 为 GUI 正在观察的目标（空选择为 null）。它不执行网页脚本、不激活窗口、不改变 CLI 默认目标，也不持久化新状态。测试报告、逐条命令、GUI 检查点和截图写入该次输出目录；退出时删除自有测试 Space 并停止测试 daemon。

## 临时详细诊断

后台清理定时任务之外，宿主也会在接收事件及生成快照前检查绝对/单调期限，先抹除过期详情，再接受或输出数据，不依赖后台定时器准时唤醒。

```sh
browser diagnostics --space work --tab TAB_ID --detail on
browser diagnostics --space work --tab TAB_ID
browser diagnostics --space work --tab TAB_ID --detail off
python3 tests/reliability.py --diagnostics-only  # 含真实 5 分钟自然到期检查
```

默认摘要与 200 条容量不变。显式启用后，仅指定 Tab 当前文档的新事件可包含 `detail`：错误/console 正文最多 512 字符、堆栈最多 8 行且每行 256 字符、有限 `resource`，以及宿主 `navigationId`、fetch/XHR 的 `requestId`。每次启用生成新代号，迟到的旧代号详情不接受；页面仍能伪造自己这一来源的数据，ID 不能作为可信审计或代理证据。请求 ID 对应每次 fetch/send 的终态，包含 HTTP 错误、拒绝、取消和超时，不读取响应体、header 或上传内容；这是有限定位信息，不是 DevTools 请求追踪。

详细模式最长 300000 ms，导航、关闭 Tab、显式恢复或重启会关闭；popup 不继承。它不补回启用前的错误，也不捕获下一次完整文档导航的初始详情；SPA 同文档更新不关闭。开启需等待该 Space 空闲，以现有有界 WebKit 调用确认 hook（最长 2 秒）；hook 不可用返回 `diagnostics_unavailable`，超时沿用现有恢复规则。普通读取仍不执行 JS，忙碌、暂停或卡死页面可用；关闭会立即在宿主拒绝/抹除所有已保留详情，并向页面尽力发送停止信号，不等待失联页面。`--clear` 仅清除记录，不关闭模式。

详情只保留在 Tab 的内存环形缓冲，不写 Space 注册表或其他磁盘日志；CLI 输出及调用方自行保存的内容不在此保证内。页面仅在启用期间读取最多 100 个表单控件的当前值用于本地字符串替换，不把这些值单独传出；超出数量或读取失败时省略对应自由文本。宿主再过滤字段、限长，删除 URL 凭据/query/hash，将数字、长串等动态路径片段替换为 `[redacted]`，并过滤带标签凭据、Bearer/Basic 和长 Token。只保留有限路径，不保证完整资源 URL；脱敏是尽力处理，任意页面文本仍可能包含未识别的敏感信息，不能当成绝对安全的导出或可信日志。关闭、到期、导航也会抹除已存详情，保留原摘要与事件 ID。

`--diagnostics-only` 同时回归原摘要及详细模式，包括实际异常/拒绝/失败资源/fetch/XHR、正文/堆栈/资源与关联 ID、脱敏、跨 Space/popup、关闭后的迟到批次、忙碌/卡死关闭、导航/重启及自然到期；普通 `--forms` 包含这些行为检查，但不重复等待 5 分钟。

## Console 与网络诊断

```sh
browser diagnostics --space work [--tab ID]
browser diagnostics --space work --clear
python3 tests/reliability.py --diagnostics-only
python3 tests/reliability.py --forms  # 含诊断、原有可靠性和框架回归
```

`diagnostics` 在宿主读取 Tab 的内存记录，不执行 JS，不占用 Space 操作锁，因此忙碌、Direct 暂停、页面失联时仍可查询。不返回含 URL/title/错误正文的 `page.state`；响应含 `spaceId`、`tabId`、`busy`、`networkBlocked`、`networkErrorCode` 与 `value`。`--clear` 清除已接收记录；仍在网页中排队的事件可能随后出现。每 Tab 保留最近 200 条，`droppedEvents` 合计环形缓冲淘汰数和页面队列报告的丢弃数。普通导航与显式卡死恢复保留历史，关闭/删除 Tab 或重启释放历史；记录不写注册表或其他磁盘文件。

每条事件有递增 `id`、宿主接收时间 `receivedAtMs` 和 `source`：

| 来源 | 记录内容 | 边界 |
| --- | --- | --- |
| `webkit` | 主 frame HTTP response、导航完成/失败/超时、条件等待超时、WebKit 调用超时、导航拒绝和内容进程终止回调 | 失败保存系统 domain/code 和有限原因分类，不保存 NSError.userInfo 或错误正文；HTTP 4xx/5xx 本身仍可能是正常完成的文档导航 |
| `page-script` | console.warn/error 的等级与参数数量、异常类型/行列、未处理拒绝、元素资源错误、fetch/XHR 状态/耗时 | 页面可伪造、覆盖或停用；异常也可能由 Agent evaluate/DOM 调用触发，缺失记录不代表没有错误 |

页面 hook 在 documentStart 注入 page world，通过公开 WKScriptMessageHandler 发送摘要；内部 DOM bridge 仍留在原有隔离 world。console 包装调用原方法且不遍历参数，fetch 保留响应和拒绝。XHR 每次 send 固定请求 origin，在捕获阶段观察 DONE 状态及 load/error/abort/timeout，先保存结果并解绑该次监听，再由普通页面回调处理，避免 onload/onreadystatechange 复用对象时串用状态；不读写 body/header。页面队列最多 100 条，约每 100 ms 批量发送，导航卸载尝试 flush；后台调度、导航和进程退出可能延迟或丢失批次。宿主再次按字段/枚举/数值范围过滤，不接收任意消息键；共享 popup controller 按 WKScriptMessage.webView 路由，不接受网页提供的 Tab/Space ID，并拒绝子 frame 消息。

默认摘要只保留 http(s) origin（含端口），删除用户名、密码、路径、query 和 hash；自由文本消息、栈、Cookie、Authorization、表单值和请求/响应内容不采集。显式开启的有界详情见上节。`pageTimeMs` 是网页相对时间，`durationMs` 是对应调用/导航耗时，`receivedAtMs` 可能晚于实际发生时间。Request/URL 对象在失败前无法安全读取目标时、opaque 响应等场景 origin 为 `opaque`。fetch 拒绝无法单独区分网络/CORS/策略问题；状态码 0 不能当成网络失败。

本期不覆盖子 frame、worker、WebSocket 消息或所有 CSS/媒体/缓存/Service Worker 请求，不是 DevTools 的完整网络追踪；没有私有 WebKit delegate 或代理路径验证。`routeVerified` 始终 false，实际代理证据仍来自独立 Whistle 与来源日志。测试主动制造真实异常、HTTP 错误、断连、XHR 超时/取消、opaque 响应，并核对保留响应内容、容量、字段过滤、popup/Space/frame 归属、忙碌/卡死查询、恢复/重启和前台不变；完整验收另验证 TLS 拒绝及 Direct 暂停诊断。

接口依据本机 SDK 的 WKNavigationDelegate、WKScriptMessage、WKUserContentController 公开声明，以及 [error](https://developer.mozilla.org/en-US/docs/Web/API/Window/error_event)、[unhandledrejection](https://developer.mozilla.org/en-US/docs/Web/API/Window/unhandledrejection_event)、[XHR loadend](https://developer.mozilla.org/en-US/docs/Web/API/XMLHttpRequestEventTarget/loadend_event) 文档。包装函数会改变函数身份，页面仍可重新替换它们；保持该限制可见，不将观测结果视为可信审计。

## 复现域名代理路径

默认的 `python3 tests/acceptance.py` 会使用本机已安装的 `whistle` / `w2`，选择空闲端口启动前台测试实例；可用 `--whistle-port PORT` 显式指定测试端口，占用时会报错而不停止已有服务。规则通过 `--shadowRules` 传入，每个实例使用独立系统临时目录，`WHISTLE_PATH` 隔离 CA、缓存等文件，`--baseDir` / `--storage` 隔离测试数据，`--certDir` 指向各自生成的临时 CA。指定独立 `--rcPath`，配合 `--no-global-plugins` 与 `capture|prod` 模式避免继承用户配置或加载插件。不运行 `w2 proxy`、`w2 ca` 或 `--init`，不安装工具或证书。

若要复用已经运行的 Whistle，在其中准备以下规则：

```sh
example.com http://127.0.0.1:5173
example.com enable://capture
```

然后运行：

```sh
python3 tests/acceptance.py --whistle-existing --origin-port 5173
```

测试自己启动 5173 HTML 服务，通过 `/cgi-bin/rootca?type=pem` 读取 CA，并通过 `/cgi-bin/get-data` 读取 Whistle 会话。复用实例的代理端口默认 8899，可用 `--whistle-port PORT` 指定。该模式不设置规则、不切换 HTTPS 开关、不停止现有 Whistle；要求本机可读这两个 API。如现有实例有 UI 认证，当前测试不会自动提供凭据。

### 两路独立代理

`python3 tests/acceptance.py --independent-proxies-only` 使用两个独立 Whistle、两个返回不同随机 nonce 的来源服务，以及两个 Space。对同一个 `https://example.com` URL 并发导航和 fetch，核对页面 nonce、输入与点击结果、Whistle 的实际 GET / realUrl / 目标端口 / 状态 / 完成记录，以及来源服务日志。两次延迟导航的来源时间差用于验证并发。随后保存 Cookie / LocalStorage 并重启 daemon，核对 Space、DataStore、Tab ID、代理地址、证书策略和网站数据，再执行一轮真实路由检查。

单路故障用例先通过 Direct Space 确认相同公网 URL 可访问，再只停止测试代理 A：A 必须明确失败且不新增来源请求，B 必须继续经自己的代理访问来源 B。报告、两路抓包和截图位于输出目录的 `independent-proxies/`，代理 A 抓包及来源日志位于输出目录根部；`whistle-instance.json` 记录进程、临时目录、端口和规则。清理删除测试 Space 并停止测试服务，临时配置和日志保留便于检查。

默认完整套件包含此专项；`--whistle-existing` 跳过它，以免停止用户代理。参数检查同时覆盖 direct、8899、其他端口、端口边界及非法地址；接受端口的检查不导航，不要求这些端口运行服务。此测试验证本机 HTTP Whistle 的独立绑定，不覆盖远程代理、认证、SOCKS、运行中切换或业务页面验收。

`python3 tests/independent_proxy_cleanup.py` 使用真实 Whistle 和来源服务，注入浏览器 IPC 失联，确认即使 Space 清理失败，代理 B 与来源服务仍释放端口，失败报告仍写入临时目录。这个故障用例只检查资源清理，不能替代上述真实 WebKit 路由验收。

B 的两个 Space 访问同一个含随机 nonce 的 HTTPS URL。代理端必须显示本地站点生成的 nonce，并且 Whistle 记录实际 GET；direct 必须显示公网 Example Domain、没有本地 nonce，不增加同 URL 的 Whistle 会话或本地来源请求。截图、JSON 状态和配置成功均不能单独作为网络路径证据。这个测试需要访问公网 example.com；断网会失败，不回退到假站点。

`network_cases.py` 在两个 Space 内分别执行同 URL 的 fetch 与 WSS。代理 Space 必须收到本地服务返回的随机 nonce 和 WebSocket echo，Whistle 必须有对应会话；direct 不能新增这些 Whistle 会话或命中本地服务。example.com 不提供测试用 WebSocket，因此 direct 的 WSS 超时只用于排除错误代理路径，不代表公网上存在可用的 WebSocket 服务。媒体、Service Worker 和其他资源类型尚未全面测试。

`tests/fixtures.py proxy` 与 `tests/proxy_probe.py` 保留为此前的 CONNECT / loopback 诊断工具，不再参与 B。localhost / 127.0.0.1 代理路径暂不纳入验收。

## Direct 冲突回归

`python3 tests/acceptance.py --direct-conflicts` 在原有 A/B/C/D、TLS、fetch/WSS 验收前追加冲突恢复测试。测试用 clang 构建 `tests/proxy_settings.m`，仅通过独立 daemon 的 `DYLD_INSERT_LIBRARIES` 替换 `CFNetworkCopySystemProxySettings` 返回值，不写 SystemConfiguration、系统代理或钥匙串，不改变 WebKit 网络进程的代理配置。

HTTP、HTTPS、SOCKS（含嵌套接口）、PAC、自动发现各自经历已有 Direct + Whistle Space 的重启、查询、拒绝导航、真实 Whistle 请求、关闭冲突、原 Cookie/LocalStorage/Tab ID/URL 恢复，以及页面自主导航拒绝。它验证真实应用对设置变化的处理，但**不等于真实操作系统代理切换或动态子资源路由实测**；后者需要独立 macOS 测试环境，不能在用户机器上自动切换代理来凑验收。

Direct 冲突不在 `Space.init` 抛出；恢复跳过受阻导航，数据容器仍保留。只读查询、修改默认标签页、关闭标签页及删除 Space 仍可用。关闭系统代理后显式 reload/open 恢复，避免自动重放页面操作。

## Space 证书策略

默认策略为 `system`，完全交给平台处理。`--ca-cert PATH` 将单张 PEM / DER 导入为 `custom-ca`；保存 DER 数据及 SHA-256 指纹，文件随后被移动也不影响重启恢复。新 Tab 继承同一个策略。旧注册表缺少 `tls` 字段时仍使用系统策略。

实现通过 WKNavigationDelegate 的 server-trust challenge，仅对当前 `SecTrust` 加入 Anchor，并保留原有 SSL / hostname 策略，允许系统 Anchor。异步评估在主队列发起并回到主队列，符合 Security API 的队列要求；仅在评估成功时使用 credential。错误域名、过期证书、无关 CA 和缺少用途的证书仍会拒绝。

`--ignore-certificate-errors` 对应显式 `insecure` 策略，直接接受该 WebView 收到的 server-trust challenge。它会接受证书链、主机名、有效期及用途错误，适合受控开发 Space；不会修改系统设置或其他 Space。此选项与 `--ca-cert` 互斥，不能附加在 `open` 等页面命令上。CLI 始终返回策略与警告，避免把忽略校验伪装成信任校验成功。

Whistle 2.10.2 动态证书的 SAN 存在，但缺少 EKU `serverAuth`。本机系统已信任的默认 Whistle CA 可走系统策略；换成测试 CA 后，`custom-ca` 严格评估出现 `ServerAuthEKU` 错误。这与 [Apple 的服务端证书要求](https://support.apple.com/en-lb/103769)一致。B 使用显式 insecure Space 来验证该版本 Whistle，另用带正确 SAN / EKU 的本地 HTTPS 服务验证 custom-ca 的正反用例。

测试证书均由 OpenSSL 临时生成，不安装到钥匙串。错误域名与过期证书先在 custom-ca Space 中验证拒绝，再在显式 insecure Space 中验证接受，最后重新检查 custom-ca 仍拒绝，以检测策略是否串到别的 Space。

## 运行模型与协议

单进程负责 AppKit、Space 注册表和 Unix Socket。WKWebView 操作在主 Actor 上执行，网络等待异步让出执行权；WebKit 自己管理 WebContent / Networking / GPU 进程。每个 Space 同时执行一条页面命令，不同 Space 可以并发。没有全局 activeSpace 供 RPC 隐式使用。

Socket 建立后，`status.ready` 表示元数据恢复与待删除存储的清理尝试是否完成。恢复期间只有 status/help/version 可用，其他命令返回 `not_ready`，避免 Agent 与恢复任务同时修改会话。ready 不表示全部网页加载完成；页面仍用 `wait` 等待。

注册表保存 Space UUID、名称、代理、固定默认 Tab UUID、各 Tab UUID/URL 和待删除标记。Cookie、LocalStorage 等由命名 WKWebsiteDataStore 持久化，不手工导入导出。重启恢复的是标签页 URL，不是 DOM、JavaScript 堆、表单草稿或完整后退历史。Cookie 是否跨重启仍服从过期 / 会话属性；验收使用带 Max-Age 的 Cookie。

GUI 的 selectedSpace / selectedTabs 只决定观察哪一个 WebView，并按数据目录记住选择。窗口采用 NSSplitViewController、原生 sidebar、NSToolbar 和系统语义颜色。关闭观察窗口不终止服务。后台 Tab 使用隐藏 NSPanel 持有视图；DOM、Evaluate 和截图不调用 activate / makeKey。GUI 新建、地址栏导航和重新加载都走同一条命令处理路径，遵守 Space 锁及代理检查。没有 Space 时，首次新建显式使用 direct 创建 personal；其余新建沿用当前 Space。分享按钮复制带 Space UUID 和 Tab UUID 的 snapshot 命令，既不新建页面，也不修改默认标签页。地址栏编辑期间，后台刷新不会覆盖输入。

本地 RPC 为每连接一条换行分隔的 JSON Request / Response，请求结构：

```json
{"command":"fill","args":["#message","hello"],"options":{"space":"admin"}}
```

复合命令为 `space.create` / `tab.new` 等，与 CLI 一一对应。Socket 默认位于 0700 的数据目录中，权限 0600，服务用 `getpeereid` 拒绝其他 UID。注册表和 Socket 各有 flock，重复 daemon 不覆盖活跃 Socket。单条消息上限 8 MiB，Socket 读写超时 75 秒，页面等待 1–60000 ms。不要把自定义 Socket 放在他人可替换的目录；同一 UID 内的进程具有相同控制权限。

Snapshot 覆盖主 frame、同源 frame 与开放 Shadow Root 中的可见交互元素，最多 1000 个；文本摘要仅取主 frame，最多 20000 字，达到上限返回 `truncated`。引用在元素对象存续期间稳定，导航、刷新、frame 文档替换或元素被移除后失效；CSS selector 必须恰好命中一个元素，跨作用域使用 `>>>` 或完整引用，边界见下文。Snapshot 包含控件标签、checkbox/radio 状态、select 选项，并隐藏 password 值。`fill` 使用原生 value setter 和非 trusted input/change 事件；拒绝 disabled fieldset、只读字段、无效 select 值以及文件、checkbox、radio 的文字填写。`wait` 默认等待页面加载或唯一元素可见，也可显式等待 URL、文本或 DOM 状态；选择器错误不会被吞掉当成普通超时。

Evaluate 默认使用 evaluateJavaScript；`--await` 使用 callAsyncJavaScript 等待表达式返回的 Promise（同样在 page world）。返回不能被 JSON 表示的值时明确失败。alert/confirm/prompt 对话框自动处理并计数；网站新窗口转为同 Space Tab，不改变 CLI 默认 Tab 或自动抢前台。外部 URL scheme 被明确拒绝，不启动其他应用；弹窗、opener 和合成点击的边界见下文。

## 超时与恢复

每条页面命令使用单调时钟的截止时间。JS、异步 JS 和截图通过 PendingOperation 将 WebKit 回调与主队列计时器协调，保证 continuation 只完成一次；晚到的回调不能再次完成请求或污染后续请求的计时。WebKit 调用超时后，标签页标记 `unresponsive`，Space 锁释放。`state`、`tab list`、`space info` 可在忙碌或故障期间读取，不需要执行页面 JavaScript。

超时只是停止宿主等待，不是可靠地中断页面 JS。为避免继续在未知状态上操作，该 Tab 的后续 DOM 命令会返回 `web_content_unresponsive`。显式 `open` / `reload` 替换异常 WKWebView，继承同一 Tab ID、WKWebsiteDataStore 与 TLS 策略；不重放点击、填写或提交。真正的 WebContent 终止通知会让挂起调用立即失败，并在 UI 显示恢复提示。当前已实测无限循环和永不完成的 Promise 恢复；进程被系统终止的分支尚未单独故障注入验证。

故障恢复后立即删除 Space，实测 WebKit 可能仍持有没有活动页面的网络会话，`remove(forIdentifier:)` 返回 `Data store is in use (by network process)`。流程先调用 `removeData` 清理全部公开网站数据类型，再用 `fetchDataRecords` 验证为空，并有限重试容器删除。容器未释放时返回 `websiteDataRemoved: true`、`dataStoreRemoved: false`、`cleanupPending: true`，保留 tombstone；不会把容器删除当成成功。重启后会再次清理，可通过 `status.pendingStoreCleanup` 查询。同名重建使用新 UUID，测试验证它读不到旧 LocalStorage，并验证重启后旧容器和 tombstone 清除。

若注册表只剩 tombstone、没有存活 Space，恢复时先初始化一个临时 `WKWebsiteDataStore.nonPersistent()` 并持有到恢复完成，避免在尚未初始化 Store 的进程中首次静态删除触发本机 WebKit 的 WebsiteDataStoreIO 崩溃。没有打开用户默认 Store、创建额外 WebView 或发起导航。`python3 tests/reliability.py --cleanup-only` 用真实 Store 和测试自产注册表模拟“删除标记已写入、清理前进程退出”的状态；完整可靠性套件也包含它。这里只模拟中断位置，不宣称执行过真实断电或强杀删除过程。

导航等待超时不会停止网络加载，可继续 `wait` 或打开其他 URL。被新导航取消的旧请求不会把迟到的错误写入当前页面。URL 在请求开始时保留，避免重启恢复过程中把尚未加载的标签页覆盖成 about:blank；SPA URL 变化也会保存。恢复仅保证持久化状态和 URL，页面 JS 内存、未提交表单和完整后退历史不在恢复范围内。后台页面定时器仍受 WebKit 节流。

重复加载证书失败的 URL 时，WebKit 可能没有返回可追踪的 `WKNavigation` 对象。加载请求仍保持 pending，直到终止回调；等待还直接检查证书拒绝，不能仅凭旧文档的 readyState 返回成功。TLS 回归对错误主机名和过期证书各重复三次导航，保留实际拒绝记录。

## 网站弹窗与回调

`WKUIDelegate.createWebViewWith` 使用 WebKit 提供的原始 configuration 创建同 Space Tab；检查其 DataStore 与 Space 相同，继承 TLS delegate 策略和独立 DOM world，不手动二次 load，以保留 opener、命名窗口复用和请求语义。原生窗口几何/工具栏请求不生效，`page.popupPolicy` 明示此限制。弹窗不改 CLI default 或 GUI 选择。

`webViewDidClose` 仅移除本 Space 的对应 Tab；最后一个脚本窗口关闭时保留一个普通空白 Tab。关闭或删除 Space 会解绑全部 delegate、回调并释放窗口。`openerTabId` 为本次运行时的来源信息，不在重启后伪造 opener；重启仍恢复 Tab ID、URL 和网站数据。

`click --wait-for-popup` 与 `--wait-for-navigation` 互斥，返回观察到的 `newTabId`；调用方再用该 ID 等待页面加载。若网站要求可信激活或 WebKit 阻止弹窗而未调用 delegate，期限内返回 `popup_not_opened`，不修改 page world 的 `window.open` 来伪装结果。`unsupported_navigation` 表示 URL scheme 被拒绝；GUI 和 state 的 `lastNavigationRejection` 也可查询。普通 click/fill 返回 `businessOutcomeVerified: false`，成功不等于业务完成。

`tests/popup_cases.py` 由 reliability（Direct）和 acceptance（真实 Whistle + insecure TLS）调用；`tests/tls_cases.py` 另验证弹窗 custom-ca 的接受、错误主机名及过期证书拒绝。fixture 覆盖重定向、opener/postMessage、父页回调导航、命名窗口复用、关闭最后一个窗口、双 Space、重启和可信事件拒绝。

手动 GUI 回归可运行 `python3 tests/ui_fixture.py --conflict`。它复制生成的应用并使用独立测试 Bundle ID、数据目录和本地页面，不干扰已打开的用户应用；输出 `fixture.json` 标明 socket、代理设置文件和 URL。解除测试设置（将该文件写为 `{}`）后点击重新加载，检查 Direct 恢复；在页面点击 Require trusted click、切换新 Tab 并点击 Send result and close，检查回调和关闭。终端按 Enter 清理测试 Space 并退出。这个人工测试工具不会操作系统代理。

## DOM bridge 隔离

`snapshot/click/fill/wait` 的脚本注入与调用统一使用命名 `WKContentWorld`（`AgentWebKit.DOM`），不注册跨 world 消息处理器。`evaluate` 和 `evaluate --await` 明确留在 `.page`，可读取网页全局变量；等待 readyState 也在隔离 world 执行。

每个文档在 documentStart 初始化一次 bridge，刷新、导航、进程替换及重启均产生新的随机引用后缀；同文档 SPA 更新保持连接节点的引用，已移除节点返回 `stale_ref`。隔离只保护实现和命名空间，不阻止网页改变 DOM，也不提供原生可信事件。`tests/reliability.py` 用真实页面覆盖、删除和伪造同名对象，检查四项内部命令、页面 Promise、SPA、重载及重启。

## iframe 与 Shadow DOM 定位

内部 bridge 仍只从主 frame 的隔离 world 发起，通过同源 DOM 访问 frame、开放的 `shadowRoot`，不注入 page-world shim，不绕过同源策略。`snapshot.elements[].context` 用 boundary 的稳定引用标明 frame/shadow 路径，所有元素引用属于同一 Tab 文档的随机 epoch。引用解析除 `isConnected` 外，还验证所属 Document 仍是各层 frame 当前的 `contentDocument`，防止 frame 导航后仍连接旧 Document 的节点被误用。

`#frame >>> #host >>> input` 逐层进入唯一 frame 或开放 Shadow Root；`>>>` 是本工具的作用域分隔符，不是 CSS 标准组合器，不能用于选择器中的字面值。普通 CSS 不自动穿透；snapshot 返回的完整 `@e…` 引用则可直接操作跨作用域元素。frame 内 fill 使用该文档的原型 setter 和 Event 构造器，仍是非可信 DOM 事件。

跨源或尚不可访问的 frame 在 snapshot 的 `unsupported` 中返回上下文和原因，显式进入时返回 `unsupported_context`。公开 DOM 无法区分 closed root 和没有 root；显式进入两者均返回该错误，snapshot 不声称完整枚举 closed root。`textScope` 为 main-frame；元素 bounds 的 `coordinateSpace` 区分主视口和 frame 内视口，不伪装成整页截图坐标。

遍历上限为 1000 个控件、10000 个扫描节点、16 层边界；达到上限标记 `truncated`。`tests/context_cases.py` 随 reliability 执行，覆盖嵌套作用域、同名 ID 不串用、frame 的输入事件、隐藏祖先、display:contents 宿主、跨源/closed 错误、frame 导航及宿主替换后的旧引用拒绝。尚未覆盖全部 slot/富文本组件或跨源 frame 内容。

## 逐步计时

重新构建并重启应用，然后运行：

```sh
python3 tests/timing.py
python3 scripts/google_demo.py --space google-demo
# 可选：--browser PATH、--socket PATH、--out 新目录
```

脚本连接已经启动的应用，不自行构建或重启。它使用 direct 和默认系统证书校验，逐条启动独立 CLI 进程，保留演示 Space 与最终页面。每次运行生成一个新目录，内有 `report.json`、各条命令的完整 JSON、首页 / 搜索结果 / 滚动后 / 目标页截图。遇到网络错误、验证码或页面结构变化会失败并保存已完成步骤，不使用本地假页面代替 Google。

计时使用单调时钟，单位均为毫秒。脚本的每条记录包含 `cliEndToEndMs`，CLI 响应顶层新增 `timing`：

| 字段 | 测量边界 |
| --- | --- |
| `cliEndToEndMs`（脚本） | 父进程启动 CLI 之前，到收完 stdout / stderr 并等待退出之后；包括进程加载、CLI、IPC、服务端和退出，排除脚本解析 JSON 与保存文件。 |
| `cliMs` | Swift main 入口到解析完响应、准备输出 JSON；不含程序装载、最终 JSON 编码、stdout 和退出。 |
| `ipcRoundTripMs` | CLI 序列化请求、连接 Socket、发送请求到读完响应；包含服务端主队列等待与响应传输。 |
| `serverMs` | 主 Actor 开始处理请求到命令完成或报错；包含检查、等待、保存元数据、PNG 编码与写盘，排除进入主队列前的等待和响应序列化 / 传输。 |
| `webkitMs` | 当前请求中 WebKit 操作时间区间的并集，避免导航和读取 readyState 的 JS 重叠计数。 |
| `webkitOperations` | 按 `evaluateJavaScript`、`callAsyncJavaScript`、`takeSnapshot`、`navigation` 返回调用次数、各自总时长及 `inProgress` 数量；分项可能重叠，不能直接相加。 |

WebKit 计时是宿主可观测的 API 延迟，包含 WebKit 进程间通信、调度和异步工作，不是渲染引擎内部 CPU 时间。JS 和截图从调用 API 计到回调入口，截图不包含之后的 PNG 编码和写盘。`open` 导航从调用 `load` 计到 `didFinish` / `didFail`；点击引发的导航从 `didStartProvisionalNavigation` 计到完成，点击到导航开始之间的间隔不会算作导航区间。导航耗时包含网络、TLS 和加载工作。此完成标志不代表网站以后不再发起异步请求，也不保证某一画面已经显示；滚动步骤验证的是 DOM 滚动位置，随后独立截图验证画面。

`click --wait-for-navigation` 将点击及一次完整导航放在同一请求内计时，脚本用它提交搜索和打开结果；普通 `click` 仍只等待 DOM 操作回调。同页锚点和仅更新 DOM 的 SPA 操作不会满足完整导航等待，可用原有 `wait SELECTOR` 等待。超时返回错误和已消耗时间；尚未结束的导航标为 `inProgress`，不会把它后续的时长计入下一条请求。JS 执行失败和结果无法序列化时也保留计时。

`tests/timing.py` 使用有固定延迟的本地页面，验证计时范围的嵌套关系、并发 Space 归属、导航完成与超时、无导航点击、JS / 序列化错误及真实截图；不依赖 Google 的实时可用性。Google 演示是一次实际样本，沿用持久化 Cookie；`open` 跳过本地缓存，之后的链接导航遵循 WebKit 常规策略，不能当成严格冷启动基准。

命令专属选项在 CLI 与服务端同时校验。CLI 在发送前发现的参数错误只有 `cliMs`，不会伪造 IPC 或 WebKit 耗时。`--` 后的参数作为字面值处理，适用于以连字符开头的表单内容。
