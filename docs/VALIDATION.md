# 实际验收记录

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
