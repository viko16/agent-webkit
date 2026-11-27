# 开发与测试

## 环境与构建

构建需要 macOS 14+、Xcode Command Line Tools（Swift 5.10+）；运行应用和 GUI 回归需要已登录的桌面会话。自动测试使用 Python 3；代理与 TLS 验收另需 OpenSSL 和本机已安装的 Whistle；框架表单回归需 Node.js 20.19+ / 22.12+。

Swift Package 无第三方依赖。`scripts/build.sh` 会构建二进制、由 `scripts/make_icon.swift` 生成原生图标并打包签名 `.build/Agent WebKit.app`。

```sh
zsh scripts/build.sh          # debug + 本地 ad-hoc 签名 .app
zsh scripts/build.sh release  # release + .app
```

> 服务应始终通过打包后的 `.app` 启动，保持 Bundle ID 一致；直接运行未打包的 `.build/debug/awb daemon` 会改变 WebKit 数据存储归属，不能与应用包混用。该二进制仍可直接作为 CLI 客户端。

## 测试入口

测试报告、截图与日志默认写入 `.artifacts/`（已忽略）。测试前需先构建 `debug` 或 `release`，并确保 CLI 与 `.app` 来自同一份源码。

```sh
# 离线单测与 CLI 契约检查（无需启动桌面会话）
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 tests/contract_cases.py

# 核心可靠性与专项回归
python3 tests/reliability.py
python3 tests/reliability.py --dialogs-only
python3 tests/reliability.py --downloads-only
python3 tests/reliability.py --uploads-only
python3 tests/reliability.py --lifecycle-only
python3 tests/reliability.py --diagnostics-only
python3 tests/reliability.py --screenshots-only
python3 tests/reliability.py --frames-only
python3 tests/reliability.py --keyboard-only
python3 tests/reliability.py --cleanup-only

# React / Vue 表单回归（需先安装测试页依赖）
npm ci --prefix tests/forms
python3 tests/reliability.py --forms-only

# 观察窗口与原生控件回归
python3 tests/search_selection_cases.py
BROWSER_TEST_FOREGROUND=1 python3 tests/search_selection_cases.py  # 含前台真实键盘事件
python3 tests/gui_security_cases.py                                # 原生证书与外观策略检查
python3 tests/ui_fixture.py [--conflict]                           # 独立手工 GUI 调试宿主

# 代理、TLS、Vite HMR 与公网站点验收
python3 tests/acceptance.py --out .artifacts/acceptance
python3 tests/acceptance.py --vite-only
python3 tests/acceptance.py --independent-proxies-only
python3 tests/acceptance.py --direct-conflicts
python3 tests/acceptance.py --real-sites-only

# 进程终止恢复、计时与 Codex Skill 集成测试
python3 tests/runtime_checks.py termination
python3 tests/runtime_checks.py timing --samples 30                # 需先构建 release
python3 tests/skill_workflow.py
```

## 发布流程

版本号只在 `Sources/Browser/Protocol.swift` 的 `productVersion` 中维护（格式 `MAJOR.MINOR.PATCH`）。更新版本号并提交后，推送同版本 tag `vMAJOR.MINOR.PATCH`：

- `.github/workflows/release.yml` 在 `macos-15`（Apple Silicon）构建 Release `.app`
- 运行离线单测与 `tests/contract_cases.py --binary` 校验
- 检查 `arm64` 架构、ad-hoc 签名、版本一致性，打包 `AgentWebKit-v版本号-macos-arm64.zip` 并发布 GitHub Release

## 运行模型与 CLI / IPC 契约

单进程同时承载 AppKit 观察窗口、Space 注册表与 Unix Domain Socket 服务。WKWebView 操作在主 Actor 执行，网络等待异步让出执行权。同一 Space 内页面命令串行（重叠返回 `space_busy`），不同 Space 可并发执行；忙碌时只读查询（`state`、`tab list`、`space info`、`dialog list`、`download list`、`diagnostics`）以及 `dialog respond`、`download wait/cancel` 仍可用。

- **离线自省**：`awb help [COMMAND [SUBCOMMAND]]`、`awb capabilities`、`awb version` 可完全离线运行。除成功的 `help` 输出多行纯文本外，其余命令返回单行 JSON（`{"ok":true,"result":...}` 或 `{"ok":false,"error":{"code":...,"message":...}}`）。
- **显式目标**：所有面向已有页的命令必须同时指定 `--space NAME_OR_ID` 和 `--tab UUID`。形如 UUID 的 Space 参数始终按 ID 解析。
- **数据目录与 Socket**：默认位于 `~/Library/Application Support/AgentWebKit`（权限 `0700`）与 `browser.sock`（权限 `0600`，`getpeereid` 校验同 UID）。可通过 `--data-dir` / `BROWSER_DATA_DIR` 和 `--socket` / `BROWSER_SOCKET` 隔离多实例。
- **超时与全局退出**：页面命令默认超时 15000 ms（`--timeout` 范围 1–60000 ms）；单条 IPC 上限 8 MiB，最大并发在途连接 32。退出整个服务需显式 `awb shutdown --all`。

### 资源限额环境变量

daemon 启动时读取以下可选环境变量，生效值可通过 `awb status` 与 `awb download list` 查看：

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `BROWSER_MAX_SPACES` | `64` | 最大 Space 数 |
| `BROWSER_MAX_TABS_PER_SPACE` | `64` | 单 Space 最大 Tab 数 |
| `BROWSER_MAX_TOTAL_TABS` | `1024` | 全局最大 Tab 数 |
| `BROWSER_MAX_LIVE_WEBVIEWS` | `128` | 最大活跃 WebView 数 |
| `BROWSER_MAX_POPUPS_PER_SPACE` | `8` | 单 Space 最大活跃弹窗数 |
| `BROWSER_DOWNLOAD_MAX_FILE_BYTES` | `512 MiB` | 单文件下载上限 |
| `BROWSER_DOWNLOAD_MAX_SPACE_BYTES` | `2 GiB` | 单 Space 累计下载上限 |
| `BROWSER_DOWNLOAD_MAX_TOTAL_BYTES` | `8 GiB` | 应用累计下载上限 |
| `BROWSER_DOWNLOAD_MIN_FREE_BYTES` | `512 MiB` | 最低保留磁盘余量 |

## 代理与 TLS 策略

Space 代理在创建时固定，支持 `direct` 或本机回环 `http://127.0.0.1:<PORT>`（1–65535），不支持远程代理、认证或 SOCKS。应用不会修改系统代理或 Whistle 规则。

- **Direct 冲突保护**：检测到 macOS 系统代理开启时，Direct Space 自动暂停并保留 Cookie/URL；关闭系统代理后重新检查或重载即可恢复。
- **证书策略**：默认使用系统信任校验；创建时可选互斥的 `--ca-cert PATH`（导入单张 PEM/DER 证书并保存 DER 与 SHA-256 指纹，同时保留系统信任与主机名校验）或 `--ignore-certificate-errors`（仅限受控开发环境）。

```sh
# 导出 Whistle CA 并创建自定义 CA Space
curl --noproxy '*' 'http://127.0.0.1:8899/cgi-bin/rootca?type=pem' -o /tmp/whistle-ca.pem
awb space create trusted --proxy http://127.0.0.1:8899 --ca-cert /tmp/whistle-ca.pem

# 受控开发环境忽略证书错误（如 Whistle 动态证书缺少 serverAuth EKU 时）
awb space create dev --proxy http://127.0.0.1:8899 --ignore-certificate-errors
```

### Whistle 与 Vite 配置示例

本地开发通过域名代理 Vite 服务与 HMR 时，可在 Whistle 中配置：

```text
example.com http://127.0.0.1:5173
example.com enable://capture
```

Vite 配置允许该域名并让 HMR 经 443 走 WSS：

```js
server: {
  allowedHosts: ['example.com'],
  hmr: { protocol: 'wss', host: 'example.com', clientPort: 443 }
}
```

随后在代理 Space 中打开 `https://example.com` 即可（注意 WebKit 下 `localhost` / `127.0.0.1` 请求可能绕过代理）。

## 核心能力与边界速查

- **DOM 快照与操作**：内部 bridge 注入隔离 world（`AgentWebKit.DOM`），支持同源 iframe 与 open Shadow Root（`>>>` 分隔符），跨源 iframe 通过 `frame list` + `--frame` 定向操作。DOM `click`/`fill`/`upload` 为合成事件（`nativeVerified: false`），操作后需用 `wait` / `snapshot` 核对业务结果。
- **后台键盘**：`focus` + `key` 通过公开 AppKit 定向事件发送，仅限主文档与 open Shadow Root；不支持后台 CSS `:hover`、通用快捷键和 IME，相关场景需在观察窗口人工接管。
- **JS 对话框**：`alert`/`confirm`/`prompt` 由 `DialogStore` 托管，可在 CLI（`dialog list/respond`）或观察窗口直接应答；随命令触发沿用命令期限（最长 60s），自主弹窗默认 15s 后自动取消。
- **上传与下载**：`upload` 支持 1–16 个绝对路径文件（总计 ≤ 4 MiB），通过隔离 world `DataTransfer` 写入且不自动提交；下载由 `WKDownload` 托管并保存到数据目录 `downloads/<SPACE_ID>/<TAB_ID>/<DOWNLOAD_ID>/`，单 Tab 最多 8 并发、单下载最长 5 分钟。
- **休眠与恢复**：`space suspend` 释放 WebView 但保留 URL 与网站数据（丢失 JS 内存与未提交表单）；`space resume` 重新加载页面。
- **诊断与 Safari Inspector**：`diagnostics` 默认仅记录脱敏摘要（每 Tab 200 条）；`--detail on|continuous` 开启最长 5 分钟的有界详情捕获；`--inspectable on|off`（或观察窗口 Space 信息面板开关）控制公开 `WKWebView.isInspectable`，供用户在 Safari 开发菜单中手动调试。
- **超时与进程终止恢复**：WebKit 调用超时后 Tab 标记为 `unresponsive`，内容进程退出标记为 `terminated`，不会自动重放操作；显式 `open` / `reload` 会重建 WebView 并沿用原 Tab ID、网站数据与 TLS 策略。

## Skill 安装

仓库中的 `skills/agent-webkit/SKILL.md` 面向 Codex（`$agent-webkit`）与 Pi（`/skill:agent-webkit`），可直接通过 `npx skills add` 安装，或复制到 `~/.agents/skills/agent-webkit` / 项目 `.agents/skills/agent-webkit`。
