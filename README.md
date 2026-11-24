# Agent WebKit

Agent WebKit 是一款给本机 AI Agent 使用的 macOS 浏览器。你可以在窗口里看着 Agent 操作，也可以先自己登录网站，再把当前标签页交给它。每个 Space 有独立的网站数据、标签页和代理设置，多个 Agent 可以各用一个 Space，同时工作。

## 安装应用

需要 Apple Silicon Mac、macOS 14 或更高版本，以及已登录的桌面会话。

```sh
brew install --cask viko16/tap/agent-webkit
```

在「应用程序」中打开 Agent WebKit。首次打开若被 macOS 拦截，可在「系统设置 → 隐私与安全性」中选择「仍要打开」。

## 给 Codex 或 Pi 安装 Skill

在项目目录里运行这条命令，即可为当前项目安装 Skill。命令需要 Node.js 和 npm。

```sh
npx --yes skills add viko16/agent-webkit --skill agent-webkit --agent codex pi -y
```

在项目里新开一个 Codex 对话，试试这句话（Pi 中把开头换成 `/skill:agent-webkit`）。

> $agent-webkit 用一个新的直连 Space 打开 https://example.com，告诉我页面标题。

Skill 会引导 Agent 读取页面、操作元素并核对结果。如果你想在终端直接操作，Homebrew 也会一并安装 `awb`，运行 `awb help` 即可查看命令。

## 把当前标签页交给 Agent

在地址栏打开网页，完成登录等需要手动操作的步骤。点击工具栏的分享按钮，把复制的接管命令和任务一起发给 Agent，例如「列出这页还没勾选的待办事项」。命令里带有当前 Space 和标签页的编号，你切换到其他标签页后，Agent 仍会操作原来的页面。

关闭窗口后，Agent 可以继续工作。退出应用后，已保存的网站数据会保留，尚未提交的表单可能丢失。下次打开时是否需要重新登录，取决于网站。

如果开启了系统代理，直连 Space 会暂停。关闭系统代理后，重新加载页面即可恢复。调试本地项目时，也可以给 Space 单独配置 Whistle。[Whistle 配置示例](docs/DEVELOPMENT.md#vite--whistle-域名与-hmr-回归)

[开发说明](docs/DEVELOPMENT.md) · [实现依据](docs/RESEARCH.md) · [MIT 许可证](LICENSE) · [第三方许可](THIRD_PARTY_NOTICES.md)
