# Agent WebKit

一个供本机 AI Agent 共用的原生 macOS 浏览器。每个 Space 独立保存登录状态、网站数据、代理配置和标签页。Agent 通过 CLI 操作页面，你可以在原生窗口中查看进展。

- 多个 Agent 可同时使用不同 Space，页面操作不受窗口当前选中标签页的影响。
- 支持页面快照、点击、填写、JavaScript、条件等待和截图。可固定单个 Tab 的视口，避免观察窗口的尺寸影响页面布局。
- 支持独立 Whistle 代理、证书策略，以及重启后恢复标签页和持久化网站数据。
- 提供页面错误诊断和 JS 对话框的显式回应，方便 Agent 判断结果、定位问题。
- 支持原生文件下载的状态、等待和取消，已完成文件按 Space/Tab 独立保存。
- 支持向 file input 上传本机单/多文件；后台路径使用合成事件，仍需确认页面提交结果。

## 安装和启动

需要 Apple Silicon（M 系列）Mac、macOS 14+，以及已登录的桌面会话。

从 [GitHub Releases](https://github.com/viko16/agent-webkit/releases) 下载 `AgentWebKit-v版本号-macos-arm64.zip`，解压后将 `Agent WebKit.app` 放入 `/Applications`，双击启动。首次打开若被拦截，可在「系统设置 → 隐私与安全性」中选择「仍要打开」。更新时先退出应用，再替换 `.app`。

将下面这行加入 `~/.zshrc`，并在当前终端执行一次，即可使用 CLI：

```sh
export PATH="/Applications/Agent WebKit.app/Contents/MacOS:$PATH"
```

### 从源码构建

另需 Command Line Tools / Swift 5.10+。构建与发布流程见[开发说明](docs/DEVELOPMENT.md#构建与发布)。

```sh
zsh scripts/build.sh
export PATH="$PWD/.build/Agent WebKit.app/Contents/MacOS:$PATH"
awb daemon
```

也可以双击构建生成的 `.build/Agent WebKit.app`。启动和 CLI 操作不会主动激活应用；关闭窗口后服务继续运行，通过 Dock 可重新打开窗口。

## CLI

设置好 PATH 后，创建专属 Space 并打开页面：

```sh
awb space create work --proxy direct
awb open https://example.com --space work
awb snapshot --space work
awb screenshot --space work --out /tmp/work.png
```

用 `awb help` 查看命令，`awb help open` 查看单项用法。点击或填写前先获取 snapshot，使用其中的完整元素引用；操作后通过页面内容或等待条件确认结果。

页面较大时，可用 `awb snapshot --scope '#app' --interactive --space work` 只列出指定区域内的交互控件。表单也支持 `select` 和 `check/uncheck`，历史与滚动可直接用 `back/forward` 和 `scroll`。

验收响应式页面时，用 `awb viewport set 768 600 --space work --tab TAB_ID` 设置尺寸。打开 URL 后查看 `page.httpStatus`，或加 `--fail-on-http-error` 将主文档 4xx/5xx 作为命令失败。需要捕获页面启动错误时，先对目标 Tab 启用 `awb diagnostics --detail continuous --space work --tab TAB_ID`，再导航。

每个 Agent 使用独立 Space。页面命令必须指定 `--space`。允许省略 `--tab` 的命令会使用该 Space 的固定默认标签页，切换窗口中的页面不会改变这个目标。

## 手动浏览与 Agent 接管

点击工具栏的 **＋** 新建标签页，在地址栏输入网址。首次使用会创建直连的 `personal` Space。你可以先登录或填写内容，再点击分享按钮，复制接管命令交给 Agent；它会继续操作同一 Space 和标签页。

交给 Codex / Pi 时，提供 `awb` 的路径和专属 Space 名称即可。仓库内的 [agent-webkit Skill](skills/agent-webkit/SKILL.md) 提供快照、动作、验证和失败恢复流程；可按[安装说明](docs/DEVELOPMENT.md#codex--pi-skill)自行安装，也可让 Agent 单次读取该文件。

常用快捷键：⌘T 新建标签页，⌘L 输入网址，⌘W 隐藏观察窗口，⌘Q 退出应用。

CLI 全局退出使用 `awb shutdown --all`，会停止全部 Space；先用 `awb status` 查看 `shutdownImpact` 中的影响范围。退出保留网站数据，页面内存和未提交表单不保留。

暂时不用的 Space 可用 `awb space suspend work` 休眠，释放页面运行资源。`awb space resume work` 开始恢复加载，后续页面操作也会按需恢复。网站数据、标签页 ID 和地址保留，页面内存及未提交表单不保留。

## Whistle 与 direct

已启动本机 Whistle 后，可为开发任务创建代理 Space：

```sh
awb space create dev --proxy http://127.0.0.1:8899
awb open https://example.com --space dev
```

将实际域名映射到本地服务后，即可在页面中调试开发项目；规则和 Vite 热更新配置见[域名与 HMR 配置](docs/DEVELOPMENT.md#vite--whistle-域名与-hmr-回归)。多个 Space 可连接不同端口的 Whistle。localhost / 127.0.0.1 的代理路由暂不保证，开发页请使用域名映射。

默认使用系统证书校验，也可为 Space 配置本机 CA；忽略证书错误仅适用于显式选择的受控开发环境，详见[证书配置](docs/DEVELOPMENT.md#space-证书策略)。

`direct` 遇到已启用的系统代理会暂停该 Space。关闭系统代理后，执行 `awb reload --space work` 恢复。应用不会修改系统代理设置。

## 使用边界

- 点击和填写使用 DOM 合成事件。后台键盘先用 `awb focus SELECTOR_OR_REF --space work --tab TAB_ID`，再用 `awb key Enter --space work --tab TAB_ID`；[支持的按键及限制](docs/DEVELOPMENT.md#后台-focuskey)见开发说明。按键由宿主定向构造，不等同于物理输入或业务成功。hover、复杂编辑器、IME 和必须人工登录的操作仍需在窗口中接管。
- 页面卡住时可用 `awb reload --space work` 恢复；未提交表单和页面内存状态不会保留。超时动作可能已经生效，先核对结果，再决定是否重试。
- 支持开放 Shadow Root 和同源 iframe。跨源及嵌套 frame 先用 `awb frame list --space work --tab TAB_ID` 获取文档 ID，再给支持 `--frame` 的命令指定该 ID。导航后重新确认目标。`>>>` 仅穿透同源 frame 和开放 Shadow Root。截图默认截取视口，也可截取元素可见范围或有界拼接整页。[跨源定位与限制](docs/DEVELOPMENT.md#跨源-frame-dom-操作)
- JS alert/confirm/prompt 需要显式查询和回应，操作流程见[对话框说明](docs/DEVELOPMENT.md#js-对话框)。弹窗能打开不代表第三方 OAuth 已全自动兼容。
- 普通关闭和重启保留持久化网站数据，登录是否延续仍由网站决定。`awb space delete work` 会删除该 Space 的网站数据。

## 更多文档

- [开发说明](docs/DEVELOPMENT.md)：CLI 契约、代理与证书、诊断、存储、构建和测试。
- [实现依据](docs/RESEARCH.md)：参考项目与 API 选择。
- [MIT 许可证](LICENSE)与[第三方许可](THIRD_PARTY_NOTICES.md)。
