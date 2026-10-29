# 实现依据

检查时间：2026-10-23。两个项目均直接读取了源码与 LICENSE；以下结论针对固定提交，不把 README 的能力描述当作测试结果。

| 项目 | 检查提交 | 许可 | 对本项目有用的部分 | 不直接 fork 的原因 |
| --- | --- | --- | --- | --- |
| [agent-safari](https://github.com/handlecusion/agent-safari/tree/2010ad84c95efb22399200ce5cd8f01d3441e1c9) | `2010ad84` | MIT，Hyun Yoon-sung | Swift/AppKit WKWebView、Socket CLI、WeakMap 元素引用、DOM click/fill、截图、异步等待 | `makeWebView()` 仍选择 `.default()` / `.nonPersistent()`；Profile 名称为 daemon 元数据，未对应命名持久化 DataStore。直接沿用其会话模型不能满足 Space 隔离。已有 MCP、媒体、上传、下载与原生输入超出本次范围 |
| [mcp-browser](https://github.com/brainfuel/mcp-browser/tree/90d9a05a463b4d3488ab570c85011db83dc314c3) | `90d9a05a` | MIT，Moosia LLC | 每 Tab 持有 WebView、SwiftUI Host 重挂载、页面委托与状态处理 | `BrowserTab.makeConfiguredWebView` 默认使用 `.default()`；MCP、书签、历史、录制和用户确认等功能增加了本次不需要的依赖关系 |

最终独立实现 Swift Package + AppKit，借鉴 agent-safari 的自动化机制，不引入两个项目的产品层和 MCP。`DOM.swift` 保留其 WeakMap 稳定引用思路，改为带导航随机后缀的引用，并通过 Map 直接定位元素，防止刷新后同编号引用误操作。保留 MIT 许可文本。

检查的 agent-safari 源码包括 `BrowserController.swift`、`BrowserControllerSnapshot.swift`、`BrowserControllerInput.swift`、`BrowserControllerScreenshot.swift`、`BrowserControllerSession.swift`、`BrowserControllerWaits.swift` 和 `UnixSocketTransport.swift`。其原生事件与 DOM 事件有区分，本次只取 DOM 路径。Socket 服务按连接读取后交给主 Actor，页面操作均需要显式目标；本项目为每个客户端独立处理连接，不让一次页面等待堵住 accept 循环。

检查的 mcp-browser 源码包括 `BrowserTab.swift`、`BrowserTab+Agent.swift`、`BrowserTab+Network.swift` 和 `WebViewHost.swift`。其网络日志读取页面注入的 fetch/XHR 数组，不能用于证明主文档、资源或 CONNECT 的真实路径。本项目因此在测试代理和来源站点分别记录 TCP 连接，不使用页面网络 shim 作为代理证据。

## Apple API

同时查阅官方 API 和本机 macOS 27 SDK 的头文件 / Swift interface，实际以真实进程验收验证隔离。

| API | macOS 最低版本 | 实际使用及边界 |
| --- | --- | --- |
| [WKWebsiteDataStore(forIdentifier:)](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/init(foridentifier:)) | 14.0 | UUID 命名持久化 Store，在创建 WebView 前指定。不同 Store 的 Cookie、LocalStorage 隔离及重启持久化已测试；不是完整浏览器进程或操作系统隔离 |
| [proxyConfigurations](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/proxyconfigurations) | 14.0 | 同一 Store 的全部 WebView 使用相同配置。创建后不提供热切换代理。空数组清除覆盖配置，不能证明绕过系统代理 |
| [evaluateJavaScript](https://developer.apple.com/documentation/webkit/wkwebview/evaluatejavascript(_:completionhandler:)) | 10.10 | completionHandler 版本返回值或错误；`browser evaluate` 保留主 frame / page world 语义，内部 DOM bridge 使用独立的 `AgentWebKit.DOM` content world。并非真实输入。content world / frame 重载最低为 11.0 |
| [takeSnapshot](https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot(with:completionhandler:)) | 10.13 | 截取当前 WebView 视口，不依赖系统屏幕截图权限。后台 Tab 在未显示的非激活 Panel 中保留视图；已检查实际图像内容 |
| [callAsyncJavaScript](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.h) | 11.0 | 0.2.0 的 `evaluate --await` 等待表达式返回的 Promise；宿主另设截止时间，不将超时解释为 JS 已取消 |

SDK 的 `WKWebsiteDataStore.h` 明确要求先释放使用该 Store 的 WKWebView 再调用 `remove(forIdentifier:)`。删除流程先持久化 tombstone，解除 WebView/窗口引用，跨过一次 AppKit autorelease 周期，再调用公开删除 API；重启时重试未完成的删除。

2026-10-24 的恢复测试发现，即使 Tab 与 Space 对象已经释放，WebKit 仍可能保留空网络会话。[WebKit 的容器删除实现](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebsiteData/Cocoa/WebsiteDataStoreCocoa.mm)会分别拒绝活动页面和仍有网络进程的 Store。0.2.0 因此区分网站数据清除与容器移除：先通过公开 removeData / fetchDataRecords 清除并核对，容器清理失败则返回 cleanupPending，保留 tombstone。只有数据确实清除才返回 websiteDataRemoved，只有公开容器删除成功才返回 dataStoreRemoved。

Apple 的 [WWDC23 Network Relay 介绍](https://developer.apple.com/videos/play/wwdc2023/10002/) 展示了同一个 `ProxyConfiguration` 用于 Network、URLSession 与 WebKit。HTTP CONNECT 支持 TCP；`allowFailover=false` 禁止代理失败后改走直连。以上说明不能替代路径验证：本机的 loopback 流量没有采用该代理。

## 跨源 iframe 可行性（2026-10-29，#9）

独立 spike 使用公开 `WKUserScript(forMainFrameOnly:false)`、隔离 `WKContentWorld` 的 `WKScriptMessage.frameInfo`，以及 `evaluateJavaScript(in:in:)`。复用当前 DOM.bootstrap，只在实验配置中注入所有 frame，两个 nonPersistent Store 代表 Space、三个 WKWebView 代表 Tab；同组两个 Tab 共享 Store。没有连接产品 daemon 或更改正式命令。

本机 SDK 的 WKFrameInfo.h 明确其为 transient/data-only，不唯一标识跨回调的 frame；公开属性只有 mainFrame、request、securityOrigin、webView，没有父 frame 身份。实际同一文档的重复消息产生不同且不 isEqual 的对象；两个兄弟 frame 可有完全相同 URL。隔离脚本产生的随机文档代号必须和宿主 WebView/Tab 归属绑定，URL、对象地址和层数均不能单独作为稳定身份或父子路径。

实测不同端口及不同主机名两种来源：原父文档 contentDocument 仍受 SOP 限制，frame 的 page world 也不能读取跨源 parent.document；原生定向调用可在子 frame 与嵌套 frame 执行现有 snapshot/ref/fill/click，实际 POST/服务端 nonce 被宿主独立核对。page world 无法访问该隔离消息处理器或覆盖隔离代号。合成事件仍不可信，动作成功仍需业务确认。第一方 LocalStorage 检查确认实验 Store 的同组共享/跨组隔离，不把它扩大为第三方 Cookie/Storage Access 兼容性。

关键反例：子 frame 完整导航后，保留的旧 WKFrameInfo 可指向新文档。实验把“代号相符才动作”放在同一次定向 JS 回合，旧代号在触及 DOM 前被拒绝；frame 移除、父 frame 导航和顶层 reload 后也验证原生 invalid-frame target 或文档失效。pagehide 只记录观察，不作为可靠失效前提。

定向 `callAsyncJavaScript` 也能返回隔离文档代号；保留引用的挂起Promise验证150ms宿主超时，另一Store/Tab的异步调用仍可用。未保留引用的Promise曾返回“Completion handler for function call is no longer reachable”；SDK明确允许thenable被GC后报不可达错误，不能把任意不resolve表达式都假定会等到宿主期限。宿主超时不代表取消JS。

结论：公开 API 足以支持受控的跨源定向 DOM bridge，可进入后续独立正式实现；本项完成可行性验证，当前 CLI 仍返回 unsupported_context。正式范围需先确定可寻址 frame/document 目标、父子路由与有界生命周期，不自动按 URL/深度拼接现有 >>>，不扩展到 closed Shadow Root。跨源可见性/坐标、截图/上传/对话框归属、sandbox/opaque origin、进程切换、CSP/跨站跟踪策略和任意网站均未由本 spike 验证，不宣称已支持。

## 代理实验结论

在 macOS 27.0.1 上测试过无域限制、空字符串匹配、显式 `localhost` / `127.0.0.1` 匹配，以及命名持久化 / 临时 Store。结果：loopback 请求均没有到达记录代理。最终配置使用空的 `matchDomains`，表示不限制域；不保留会缩小域范围的实验配置。

无域限制时，普通 HTTPS 域名实际产生了 CONNECT；本地代理故意返回 403，WebKit 导航失败，没有绕过此代理。另以 `agent-webkit.test` 作为仅由测试代理解析的域名，加载本地站点并比较 TCP 来源端口，证明普通域名的 HTTP 路径也经过了代理。这个附加实验没有替代 localhost 验收，也不能证明 HTTPS、WebSocket、Service Worker、媒体和全部子资源已全面隔离。

上述是首轮 loopback 实验的结论。后续按用户要求，B 改为真实域名经本机 Whistle 映射到本地服务，loopback 路由暂不纳入验收；当前结果见 [VALIDATION.md](VALIDATION.md)。域名映射由 Whistle 完成，浏览器保留原 URL，没有修改系统代理或 hosts。

## HTTPS 证书策略

使用公开的 WKNavigationDelegate server-trust challenge、[SecTrustSetAnchorCertificates](https://developer.apple.com/documentation/security/sectrustsetanchorcertificates(_:_:)) 和 [SecTrustSetAnchorCertificatesOnly](https://developer.apple.com/documentation/security/sectrustsetanchorcertificatesonly(_:_:))，为指定 Space 添加本机 CA，同时保留系统 Anchor 与原有 SSL 校验。Apple [Configuring a Trust](https://developer.apple.com/documentation/security/configuring-a-trust) 明确这些修改只影响当前 Trust 对象，不影响设备其他评估。CA 与可选的开发忽略策略均按 Space 持久化，不修改钥匙串。

本机 Whistle 2.10.2 的动态证书缺少 `serverAuth` EKU；严格添加 CA 后仍被拒绝。没有为兼容代理而暗中删除用途或主机名校验，而是提供互斥的 `--ca-cert` 与显式 `--ignore-certificate-errors`，并分别验证其语义。
