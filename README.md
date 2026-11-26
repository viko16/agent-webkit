# Agent WebKit

Agent WebKit 是一款给本机 AI Agent 使用的 macOS 浏览器。你可以在窗口里看着 Agent 操作，也可以先自己登录网站，再把当前标签页交给它。每个 Space 有独立的网站数据、标签页和代理设置，多个 Agent 可以各用一个 Space，同时工作。

## 安装应用

需要 Apple Silicon Mac、macOS 14 或更高版本，以及已登录的桌面会话。

```sh
brew install --cask viko16/tap/agent-webkit
```

在「应用程序」中打开 Agent WebKit。首次打开若被 macOS 拦截，可在「系统设置 → 隐私与安全性」中选择「仍要打开」。

## 给 Agent 安装 Skill

运行这条命令，即可全局安装 Skill，供本机所有项目中的 Agent 使用。命令需要 Node.js 和 npm。

```sh
npx --yes skills add viko16/agent-webkit --skill agent-webkit -g -y
```

新开一个 Codex 对话，试试这句话（Pi 中把开头换成 `/skill:agent-webkit`）。

> $agent-webkit 用一个新的直连 Space 打开 <https://example.com>，告诉我页面标题。

Skill 会引导 Agent 读取页面、操作元素并核对结果。如果你想在终端直接操作，Homebrew 也会一并安装 `awb`，运行 `awb --help` 或 `awb help` 即可查看命令。

## 把当前标签页交给 Agent

在地址栏打开网页，完成登录等需要手动操作的步骤。点击工具栏的分享按钮，把复制的接管命令和任务一起发给 Agent，例如「列出这页还没勾选的待办事项」。命令里带有当前 Space 和标签页的编号，你切换到其他标签页后，Agent 仍会操作原来的页面。

点击标签页的 × 可关闭该页，⌘W 关闭当前页，⇧⌘W 隐藏观察窗口。最后一页保留。沙漏表示该页正在执行操作；该页执行中或 Space 正忙时无法关闭。关闭当前页后选右邻页，没有右邻页时选左邻页；关闭其他页保留选择。时钟标记表示过去五分钟有 Agent 操作，手动关闭时需确认。只读轮询和被拒绝的请求不延长这五分钟。

网页请求确认或输入时，可以在当前标签页应答。关闭标签页、删除 Space 或退出应用会中断活跃下载、关闭待处理的网页对话框，观察窗口会先提示影响。确认期间出现新的相关工作会再次询问。

侧栏可搜索、新建、休眠、恢复和删除 Space。搜索时保留当前页面，点击结果或按回车切换。新建时填写名称，选择 Direct 或 HTTP Proxy。折叠 TLS 高级选项会保留已选策略。手动休眠前会提醒你保存草稿，有活跃下载时须先等待或取消下载。休眠会保留地址、Cookie 和 LocalStorage。删除会清除登录和网站数据，若显示数据容器待清理，可从 `awb status` 的 `pendingStores` 查看进度。

**CLI / IPC 破坏性变更（契约 v2）**　对已有页面的操作必须同时提供 `--space` 和 `--tab`，即使 Space 只有一页。创建 Space 后从 `tabs[0].tabId` 取得初始页 ID；`tab new --space SPACE` 直接返回 `tabId`。关闭使用 `tab close --space SPACE --tab ID`。旧的 `tab default` 命令及 `defaultTabId` 字段已移除。现有注册表继续加载，Space、标签页和网站数据沿用原 ID。形如 UUID 的 Space 参数始终按 ID 查找；名称本身是 UUID 的 Space 请使用它自己的 ID。

回退到契约 v1 前，请先正常退出 v2 daemon，再配套启动旧版 daemon 和 CLI。注册表保留旧版所需的默认页 ID：原默认页仍在就沿用，否则取首个现存页。回退后旧版省略 Tab 的调用会使用该页。

关闭窗口后，Agent 可以继续工作。退出应用后，已保存的网站数据会保留，尚未提交的表单可能丢失。下次打开时是否需要重新登录，取决于网站。

如果开启了系统代理，直连 Space 会暂停。关闭系统代理后，重新加载页面即可恢复。调试本地项目时，也可以给 Space 单独配置 Whistle。[Whistle 配置示例](docs/DEVELOPMENT.md#vite--whistle-域名与-hmr-回归)

[开发说明](docs/DEVELOPMENT.md) · [实现依据](docs/RESEARCH.md) · [MIT 许可证](LICENSE) · [第三方许可](THIRD_PARTY_NOTICES.md)
