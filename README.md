# Agent WebKit

一个供本机 AI Agent 共用的原生 macOS 浏览器。每个 Space 独立保存登录状态、网站数据、代理配置和标签页。Agent 通过 CLI 操作页面，你可以在原生窗口中查看进展。

- 多个 Agent 可同时使用不同 Space，页面操作不受窗口当前选中标签页的影响。
- 支持页面快照、点击、填写、JavaScript、条件等待和截图。
- 支持独立 Whistle 代理、证书策略，以及重启后恢复标签页和持久化网站数据。
- 提供页面错误诊断和 JS 对话框的显式回应，方便 Agent 判断结果、定位问题。
- 支持原生文件下载的状态、等待和取消，已完成文件按 Space/Tab 独立保存。
- 支持向 file input 上传本机单/多文件；后台路径使用合成事件，仍需确认页面提交结果。

## 构建和启动

需要 macOS 14+、Command Line Tools / Swift 5.10+，以及已登录的桌面会话。

```sh
zsh scripts/build.sh
export PATH="$PWD/.build/Agent WebKit.app/Contents/MacOS:$PATH"
browser daemon
```

也可以双击构建生成的 `.build/Agent WebKit.app`。启动和 CLI 操作不会主动激活应用；关闭窗口后服务继续运行，通过 Dock 可重新打开窗口。

## CLI

在另一个终端设置同样的 PATH，创建专属 Space 并打开页面：

```sh
browser space create work --proxy direct
browser open https://example.com --space work
browser snapshot --space work
browser screenshot --space work --out /tmp/work.png
```

用 `browser help` 查看命令，`browser help open` 查看单项用法。点击或填写前先获取 snapshot，使用其中的完整元素引用；操作后通过页面内容或等待条件确认结果。

每个 Agent 使用独立 Space。页面命令必须指定 `--space`；省略 `--tab` 时操作该 Space 的固定默认标签页，切换窗口中的页面不会改变这个目标。

## 手动浏览与 Agent 接管

点击工具栏的 **＋** 新建标签页，在地址栏输入网址。首次使用会创建直连的 `personal` Space。你可以先登录或填写内容，再点击分享按钮，复制接管命令交给 Agent；它会继续操作同一 Space 和标签页。

交给 Codex / Pi 时，提供 `browser` 的路径和专属 Space 名称即可。仓库内的 [agent-webkit Skill](skills/agent-webkit/SKILL.md) 提供快照、动作、验证和失败恢复流程；可按[安装说明](docs/DEVELOPMENT.md#codex--pi-skill)自行安装，也可让 Agent 单次读取该文件。

常用快捷键：⌘T 新建标签页，⌘L 输入网址，⌘W 隐藏观察窗口，⌘Q 退出应用。

CLI 全局退出使用 `browser shutdown --all`，会停止全部 Space；先用 `browser status` 查看 `shutdownImpact` 中的影响范围。退出保留网站数据，页面内存和未提交表单不保留。

暂时不用的 Space 可用 `browser space suspend work` 休眠，释放页面运行资源。`browser space resume work` 开始恢复加载，后续页面操作也会按需恢复。网站数据、标签页 ID 和地址保留，页面内存及未提交表单不保留。

## Whistle 与 direct

已启动本机 Whistle 后，可为开发任务创建代理 Space：

```sh
browser space create dev --proxy http://127.0.0.1:8899
browser open https://example.com --space dev
```

将实际域名映射到本地服务后，即可在页面中调试开发项目；规则和 Vite 热更新配置见[域名与 HMR 配置](docs/DEVELOPMENT.md#vite--whistle-域名与-hmr-回归)。多个 Space 可连接不同端口的 Whistle。localhost / 127.0.0.1 的代理路由暂不保证，开发页请使用域名映射。

默认使用系统证书校验，也可为 Space 配置本机 CA；忽略证书错误仅适用于显式选择的受控开发环境，详见[证书配置](docs/DEVELOPMENT.md#space-证书策略)。

`direct` 遇到已启用的系统代理会暂停该 Space。关闭系统代理后，执行 `browser reload --space work` 恢复。应用不会修改系统代理设置。

## 使用边界

- 点击和填写使用 DOM 合成事件，不等同于真实键鼠输入。[后台 Hover/键盘实验](docs/DEVELOPMENT.md#后台-hover键盘独立实验)尚未加入 CLI。网站要求可信点击、复杂编辑器操作或人工登录时，可在窗口中完成后再交给 Agent。
- 页面卡住时可用 `browser reload --space work` 恢复；未提交表单和页面内存状态不会保留。超时动作可能已经生效，先核对结果，再决定是否重试。
- 支持开放 Shadow Root 和同源 iframe；[跨源 iframe](docs/DEVELOPMENT.md#跨源-frame-独立实验)、closed Shadow Root 暂不支持。截图默认视口，`--element SELECTOR_OR_REF` 截取元素可见范围，`--full-page` 有界拼接整页并还原滚动；动态页面边界见开发说明。
- JS alert/confirm/prompt 需要显式查询和回应，操作流程见[对话框说明](docs/DEVELOPMENT.md#js-对话框)。弹窗能打开不代表第三方 OAuth 已全自动兼容。
- 普通关闭和重启保留持久化网站数据，登录是否延续仍由网站决定。`browser space delete work` 会删除该 Space 的网站数据。

## 更多文档

- [开发说明](docs/DEVELOPMENT.md)：CLI 契约、代理与证书、诊断、存储、构建和测试。
- [验收记录](docs/VALIDATION.md)：实际运行证据、失败和未测范围。
- [实现依据](docs/RESEARCH.md)：参考项目与 API 选择。
- [第三方许可](THIRD_PARTY_NOTICES.md)。
