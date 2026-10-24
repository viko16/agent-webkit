# Agent WebKit

一个供本机 AI Agent 共用的原生 macOS 浏览器。每个 Space 独立保存登录状态、网站数据、代理配置和标签页。Agent 通过 CLI 操作页面，你可以在原生窗口中查看进展。

- 多个 Agent 可同时使用不同 Space，页面操作不会串到当前窗口选中的标签页。
- 支持 DOM 结构、稳定元素引用、点击、填写、JavaScript、元素等待和截图。
- 支持 Whistle 代理、Space 独立证书策略，以及重启后恢复标签页和网站数据。
- WebKit 调用有执行期限；页面卡住后可重新加载，保留 Tab ID 和持久化数据。

代理验收使用实际域名：代理 Space 经本机 Whistle 将 `https://example.com` 映射到本地开发页，direct Space 访问同一 URL 时显示公网页面。localhost / 127.0.0.1 的代理路由暂不纳入验收，不能据此保证 loopback 流量经过 Whistle。详见[实际测试结果](docs/VALIDATION.md)。

## 构建和启动

需要 macOS 14+、Command Line Tools / Swift 5.10+，以及已登录的桌面会话。运行时无第三方依赖；自动验收另需 Python 3、OpenSSL 和本机已安装的 Whistle。

```sh
zsh scripts/build.sh
export PATH="$PWD/.build/Agent WebKit.app/Contents/MacOS:$PATH"
browser daemon
```

也可以双击 `.build/Agent WebKit.app`。启动和 CLI 操作不会主动激活应用。关闭窗口会隐藏观察窗口，服务继续运行；通过 Dock 可重新打开窗口。

请始终使用打包后的应用启动服务，保持 Bundle ID 一致。`.build/debug/browser` 可作 CLI 客户端；直接用未打包的二进制启动 daemon 会改变 WebKit 的存储归属，不能与应用包混用。

## CLI

在另一个终端设置同样的 PATH，然后运行：

```sh
browser space create admin --proxy http://127.0.0.1:8899
browser space create user --proxy direct
browser space list
browser open https://example.com --space admin
browser snapshot --space admin
# 使用 snapshot 返回的完整引用，引用包含页面随机后缀
browser fill '@e1-页面后缀' hello --space admin
browser click '@e2-页面后缀' --space admin
browser fill '#message' hello --space user
browser evaluate 'document.title' --space admin
browser wait '#result' --space admin --timeout 5000
browser screenshot --space admin --out /tmp/admin.png
browser tab new https://example.com --space user
browser tab list --space user
browser snapshot --space user --tab '返回的完整 Tab UUID'
browser tab default '返回的完整 Tab UUID' --space user
browser tab close '返回的完整 Tab UUID' --space user
browser evaluate 'fetch("/api/status").then(r => r.json())' --space user --await
browser reload --space user
browser space info admin
browser space delete admin
browser shutdown
```

所有页面命令必须指定 `--space`，支持名称或 UUID。省略 `--tab` 时使用该 Space 的固定默认标签页，与 GUI 显示哪个页面无关；`tab default` 可显式修改并持久化这个默认值。不同 Agent 使用不同 Space；同一 Space 的重叠操作返回 `space_busy`，由调用方顺序执行。`state`、`tab list` 和 `space info` 在操作进行中仍可查询。

WebKit 操作默认超时为 15000 ms，可用 `--timeout 1–60000` 调整。`evaluate --await` 等待 Promise 返回结果。`wait SELECTOR` 等待唯一匹配的元素可见；无效选择器、匹配多个元素和过期引用会直接报错。值以 `--` 开头时，先写选项，再用 `--` 分隔，例如 `browser fill --space user -- '#message' '--hello'`。`browser --help` 和 `browser --version` 无需启动服务。

每条命令返回一行 JSON，成功为 `{"ok":true,"result":...}`，失败为 `{"ok":false,"error":{"code":...,"message":...}}`，退出码分别为 0 / 1。页面结果包含 Space ID、Tab ID、URL、加载状态和代理限制。`click` / `fill` 使用 DOM 合成事件，返回 `method: "dom"`、`nativeVerified: false`；不提供原生输入或剪贴板模拟。

默认数据目录为 `~/Library/Application Support/AgentWebKit`。`BROWSER_DATA_DIR` 可指定独立注册表目录，`BROWSER_SOCKET` 或 `--socket` 可指定 Socket；daemon 和客户端需使用相同设置。WebKit 网站数据由系统管理，`--data-dir` 不会把这些数据搬进该目录。`space delete` 会删除该 Space 的网站数据；普通关闭和重启保留数据及标签页 URL。

删除后若 WebKit 仍占用空的存储容器，结果会注明 `cleanupPending: true`：网站数据已清除并核对，容器将在下次启动时继续删除。新建同名 Space 会使用新的 ID。`status` 可查询 `pendingStoreCleanup`；启动恢复完成后 `ready` 为 `true`，之前的页面命令会返回 `not_ready`。

内部 DOM 操作使用独立脚本环境，网页覆盖同名变量不会替换自动化实现。`evaluate`（含 `--await`）仍访问网页自身的 JavaScript 状态。网页仍能修改 DOM；隔离不保证页面内容或操作结果可信。

## 手动浏览与 Agent 接管

点击工具栏右侧的 **＋** 新建标签页，在地址栏输入网址并按回车。新标签页沿用当前 Space 的登录状态和网络设置；第一次使用时会自动创建直连的 `personal` Space。省略协议的网址会使用 HTTPS，本地 HTTP 页面需输入 `http://`。

你可以先打开网页、登录或填写内容，再点击工具栏的分享按钮，复制接管命令并交给 Agent。命令明确指定当前 Space 和 Tab ID，Agent 会读取同一个页面并继续操作，保留登录状态和页面内容。

窗口采用 Safari 风格的原生侧边栏与工具栏，随系统外观显示。左侧搜索和切换 Space，顶部标签栏切换页面；图钉标记 CLI 默认标签页。底部显示代理和证书策略，忽略证书错误的 Space 会显示橙色提示。

每个 Space 会记住上次查看的标签页。窗口大小和观察选择会恢复，但不会改变 Agent 的操作目标。关闭窗口后服务继续运行；退出应用才会停止服务。

| 快捷键 | 操作 |
| --- | --- |
| ⌘T | 新建标签页 |
| ⌘L | 选中地址栏 |
| ⌃⌘S | 显示／隐藏侧边栏 |
| ⇧⌘F | 搜索 Space |
| ⇧⌘[ / ⇧⌘] | 上一个／下一个标签页 |
| ⌘W | 关闭观察窗口 |
| ⌘Q | 退出应用 |

页面加载失败会显示原因。若 `state` 返回 `unresponsive: true` 或 `webContentTerminated: true`，可通过 `browser reload --space NAME` 或窗口的重新加载按钮恢复。恢复会重新打开 URL，保留 Tab ID、Cookie 和 LocalStorage；未提交的表单和 JavaScript 内存状态不会保留。超时操作可能已经部分生效，应先核对页面状态，不要直接重试付款、提交等有副作用的动作。

## Whistle 与 direct

应用仅连接 `http://127.0.0.1:8899`，不修改 Whistle 或 macOS 系统代理。将域名映射到本地开发服务时，Whistle 使用以下规则，并开启 HTTPS 抓包：

```text
example.com http://127.0.0.1:5173
example.com enable://capture
```

两个 Space 均打开 `https://example.com`：代理 Space 应看到本地页面，direct Space 应看到公网 Example Domain。浏览器地址仍保持原域名，映射由 Whistle 完成。

默认使用系统证书校验。创建 Space 时可选择一种额外证书策略，之后该 Space 的全部 Tab 及应用重启均沿用它：

```sh
# 推荐：为该 Space 添加一个本机 CA；支持单张 PEM / DER，保留系统 CA 和主机名、有效期、用途校验
curl --noproxy '*' 'http://127.0.0.1:8899/cgi-bin/rootca?type=pem' -o /tmp/whistle-ca.pem
browser space create trusted --proxy http://127.0.0.1:8899 --ca-cert /tmp/whistle-ca.pem

# 仅供受控开发环境：该 Space 显式忽略证书链、主机名、有效期等证书错误
browser space create dev --proxy http://127.0.0.1:8899 --ignore-certificate-errors
```

两项互斥，且只能在 `space create` 时设置。CA 证书内容会保存在 Space 注册表中，不依赖原文件一直存在；不会写入钥匙串或改变其他 Space。`space info` 和页面结果返回 `tls.policy`、CA 指纹或忽略错误的警告。

本机 Whistle 2.10.2 的动态站点证书缺少 `serverAuth` 用途，在添加 CA 后仍可能被严格校验拒绝（`ServerAuthEKU`）。如果 Whistle CA 已受系统信任，通常直接使用默认策略即可；需要在未受系统信任的开发环境使用这些动态证书时，可显式选择 `--ignore-certificate-errors`，或为 Whistle 配置符合要求的站点证书。`--ca-cert` 不会掩盖证书本身的用途错误。

`direct` 清除自定义代理，并检测系统 HTTP、HTTPS、SOCKS、PAC 和自动发现代理。冲突时仅暂停受影响的 Direct Space，返回 `direct_system_proxy_conflict`；应用、Whistle Space 和状态查询继续可用。`space info` 的 `network.blocked/error`、`status.blockedSpaces` 和窗口提示可定位原因。关闭系统代理后执行 `browser reload --space NAME` 即可恢复，保留 Cookie、Tab ID 和 URL，无需删除重建。

恢复和每次导航前都会检查系统代理。公开 API 没有强制直连开关；已经加载的页面在系统配置动态变化期间，后续 fetch、WebSocket 等请求仍可能受影响。VPN、透明代理和内容过滤器也不在绕过保证内。

## 验证

```sh
python3 tests/acceptance.py
python3 tests/reliability.py
```

测试会启动真实应用、本地 HTML 站点和本机已安装的 Whistle，在 8899 使用临时规则、独立数据目录及测试 CA；不改动已有规则、系统代理或钥匙串。它检查主页面、fetch 与 WSS 的域名分流、HTTPS 证书策略、会话持久化、并发、截图与资源回收，并保存 Whistle 会话和来源站点日志。测试结束会停止自己启动的 Whistle。`reliability.py` 无需 Whistle，验证真实死循环、Promise、超时恢复、参数校验、DOM 边界及计时。

若 8899 已被占用，测试不会停止该服务。已有 Whistle 时，配置好域名规则后运行 `python3 tests/acceptance.py --whistle-existing --origin-port 5173`，测试会直接核对 Whistle 会话，无需只凭界面人工判断。完整复现步骤见[开发说明](docs/DEVELOPMENT.md)。

源码研究与 API 核实见[实现依据](docs/RESEARCH.md)，测试证据和功能边界见[验收记录](docs/VALIDATION.md)。借鉴部分的许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

应用启动后，可运行 `python3 scripts/google_demo.py` 重现 Google 搜索、滚动、点击跳转、结构提取和截图。脚本逐条启动 CLI，分别记录完整进程耗时、IPC、服务端与 WebKit 耗时，结果和截图保存在 `.artifacts/google-timing-时间戳/`。默认复用 `google-demo` Space，也可用 `--space NAME` 指定其他名称。计时口径见[开发说明](docs/DEVELOPMENT.md#逐步计时)。
