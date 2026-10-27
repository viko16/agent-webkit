# 实际验收记录

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
