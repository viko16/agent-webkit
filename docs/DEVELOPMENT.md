# 开发与测试

```sh
zsh scripts/build.sh          # debug + 本地 ad-hoc 签名 .app
zsh scripts/build.sh release  # release + .app
python3 tests/acceptance.py --out .artifacts/acceptance
python3 tests/reliability.py  # 独立应用、本地页面、超时恢复和计时回归
```

Swift Package 无第三方包。`scripts/build.sh` 生成 `.build/Agent WebKit.app`，包含固定 Bundle ID、原生绘制的图标和允许 Web 内容联网的 ATS 配置。签名仅供本机开发，不包含公证或分发证书。测试使用 `.build/debug/browser` 作客户端，使用应用包中的 `browser daemon` 启动服务；测试前至少构建一次 debug，并确保客户端与应用包来自相同源码。`scripts/make_icon.swift` 以 AppKit 绘制各尺寸图标，再由系统 iconutil 打包，不需要图片生成服务或外部依赖。

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

表单模式只通过 Direct 加载本地 Vite 页面，**不是** Vite + Whistle 的域名/WSS/HMR 验收。后者与真实第三方站点回归仍由 Issue #1 跟踪。框架用法依据 [React 受控输入](https://react.dev/reference/react-dom/components/input)与 [Vue 表单绑定](https://vuejs.org/guide/essentials/forms.html)，兼容性结论仅来自本仓库实际运行的这些用例。

WebKit 在 DOM click 切换 checkbox 后，可能把派生的 input 事件标为 `isTrusted=true`；发起它的 click 仍是 false，也不证明有原生用户激活。测试分别记录 checkbox 的 click 与 input，以及 fill 主动派发的非可信 InputEvent，避免把这些事件混为一谈。

## 复现域名代理路径

默认的 `python3 tests/acceptance.py` 会使用本机已安装的 `whistle` / `w2`，在 8899 启动前台测试实例。规则通过 `--shadowRules` 传入，`--baseDir` / `--storage` 隔离测试数据，`--certDir` 指向临时 CA；不运行 `w2 proxy`、`w2 ca` 或 `--init`。其中 `--baseDir` 只隔离规则等数据，不隔离 Whistle 默认 CA，所以测试还显式提供临时证书目录。已有实例占用端口时不会覆盖或停止它。

若要复用已经运行的 Whistle，在其中准备以下规则：

```sh
example.com http://127.0.0.1:5173
example.com enable://capture
```

然后运行：

```sh
python3 tests/acceptance.py --whistle-existing --origin-port 5173
```

测试自己启动 5173 HTML 服务，通过 `/cgi-bin/rootca?type=pem` 读取 CA，并通过 `/cgi-bin/get-data` 读取 Whistle 会话。该模式不设置规则、不切换 HTTPS 开关、不停止现有 Whistle；要求本机可读这两个 API。如现有实例有 UI 认证，当前测试不会自动提供凭据。

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

Snapshot 只覆盖主 frame 的普通 DOM，最多 1000 个可见交互元素与 20000 字文本，并返回 `truncated`。引用在元素对象存续期间稳定，导航、刷新或元素被移除后失效；CSS selector 必须恰好命中一个元素。Snapshot 包含控件标签、checkbox/radio 状态、select 选项，并隐藏 password 值。`fill` 使用原生 value setter 和非 trusted input/change 事件；拒绝 disabled fieldset、只读字段、无效 select 值以及文件、checkbox、radio 的文字填写。`wait` 等待唯一元素可见，选择器错误不会被吞掉当成普通超时。

Evaluate 默认使用 evaluateJavaScript；`--await` 使用 callAsyncJavaScript 等待表达式返回的 Promise（同样在 page world）。返回不能被 JSON 表示的值时明确失败。页面弹窗自动关闭并计数，外部 URL scheme 和新窗口导航被拒绝，避免意外启动其他应用。

## 超时与恢复

每条页面命令使用单调时钟的截止时间。JS、异步 JS 和截图通过 PendingOperation 将 WebKit 回调与主队列计时器协调，保证 continuation 只完成一次；晚到的回调不能再次完成请求或污染后续请求的计时。WebKit 调用超时后，标签页标记 `unresponsive`，Space 锁释放。`state`、`tab list`、`space info` 可在忙碌或故障期间读取，不需要执行页面 JavaScript。

超时只是停止宿主等待，不是可靠地中断页面 JS。为避免继续在未知状态上操作，该 Tab 的后续 DOM 命令会返回 `web_content_unresponsive`。显式 `open` / `reload` 替换异常 WKWebView，继承同一 Tab ID、WKWebsiteDataStore 与 TLS 策略；不重放点击、填写或提交。真正的 WebContent 终止通知会让挂起调用立即失败，并在 UI 显示恢复提示。当前已实测无限循环和永不完成的 Promise 恢复；进程被系统终止的分支尚未单独故障注入验证。

故障恢复后立即删除 Space，实测 WebKit 可能仍持有没有活动页面的网络会话，`remove(forIdentifier:)` 返回 `Data store is in use (by network process)`。流程先调用 `removeData` 清理全部公开网站数据类型，再用 `fetchDataRecords` 验证为空，并有限重试容器删除。容器未释放时返回 `websiteDataRemoved: true`、`dataStoreRemoved: false`、`cleanupPending: true`，保留 tombstone；不会把容器删除当成成功。重启后会再次清理，可通过 `status.pendingStoreCleanup` 查询。同名重建使用新 UUID，测试验证它读不到旧 LocalStorage，并验证重启后旧容器和 tombstone 清除。

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
