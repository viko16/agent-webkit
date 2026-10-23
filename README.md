# Agent WebKit

一个供本机 AI Agent 共用的原生 macOS 浏览器原型。每个 Space 有自己的持久化 WebKit 数据、代理配置和标签页，CLI 通过 Unix Socket 操作页面，窗口只用于观察。

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
browser tab close '返回的完整 Tab UUID' --space user
browser space info admin
browser space delete admin
browser shutdown
```

所有页面命令必须指定 `--space`，支持名称或 UUID。省略 `--tab` 时使用该 Space 的固定默认标签页，与 GUI 显示哪个页面无关。不同 Agent 使用不同 Space；同一 Space 的重叠操作返回 `space_busy`，由调用方顺序执行。

每条命令返回一行 JSON，成功为 `{"ok":true,"result":...}`，失败为 `{"ok":false,"error":{"code":...,"message":...}}`，退出码分别为 0 / 1。页面结果包含 Space ID、Tab ID、URL、加载状态和代理限制。`click` / `fill` 使用 DOM 合成事件，返回 `method: "dom"`、`nativeVerified: false`；不提供原生输入或剪贴板模拟。

默认数据目录为 `~/Library/Application Support/AgentWebKit`。`BROWSER_DATA_DIR` 可指定独立注册表目录，`BROWSER_SOCKET` 或 `--socket` 可指定 Socket；daemon 和客户端需使用相同设置。WebKit 网站数据由系统管理，`--data-dir` 不会把这些数据搬进该目录。`space delete` 会删除该 Space 的网站数据；普通关闭和重启保留数据及标签页 URL。

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

`direct` 清除自定义代理，并检测系统 HTTP、HTTPS、SOCKS、PAC 和自动发现代理。检测到启用的系统代理会返回 `direct_system_proxy_conflict`，包括恢复已有 direct Space 的应用启动。公开 API 没有强制直连开关；VPN、透明代理、内容过滤器和运行中系统配置变化仍可能影响实际路径。

## 验证

```sh
python3 tests/acceptance.py
```

测试会启动真实应用、本地 HTML 站点和本机已安装的 Whistle，在 8899 使用临时规则、独立数据目录及测试 CA；不改动已有规则、系统代理或钥匙串。它检查域名分流、HTTPS 证书策略、会话持久化、并发、截图与资源回收，并保存 Whistle 会话和来源站点日志。测试结束会停止自己启动的 Whistle。

若 8899 已被占用，测试不会停止该服务。已有 Whistle 时，配置好域名规则后运行 `python3 tests/acceptance.py --whistle-existing --origin-port 5173`，测试会直接核对 Whistle 会话，无需只凭界面人工判断。完整复现步骤见[开发说明](docs/DEVELOPMENT.md)。

源码研究与 API 核实见[实现依据](docs/RESEARCH.md)，测试证据和功能边界见[验收记录](docs/VALIDATION.md)。借鉴部分的许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

应用启动后，可运行 `python3 scripts/google_demo.py` 重现 Google 搜索、滚动、点击跳转、结构提取和截图。脚本逐条启动 CLI，分别记录完整进程耗时、IPC、服务端与 WebKit 耗时，结果和截图保存在 `.artifacts/google-timing-时间戳/`。默认复用 `google-demo` Space，也可用 `--space NAME` 指定其他名称。计时口径见[开发说明](docs/DEVELOPMENT.md#逐步计时)。
