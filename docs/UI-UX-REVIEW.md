# Agent WebKit 界面问题与验证记录

最初五批以 `6651d9f` 为基线，共 27 项。表单边距列为第 26 项，随第一批修复。标签页关闭按钮列为第 27 项，随第二批修复。第六批以 `982ef57` 为基线，新增第 28 项。截图保留各批验收时的界面。

## 第一批 · 操作中断、数据和目标

| 编号 | 问题与预期 | 修复前证据 | 状态 | 修复后证据 |
| --- | --- | --- | --- | --- |
| 1 | **网页确认框不可见**。前台网页等待 confirm 时窗口仍提示可交接。应能看到来源、问题并应答，后台标签标记待处理。 | [截图](ui-ux-evidence/before/22-manual-confirm.png) | 已验证 | [前台确认](ui-ux-evidence/after/01-confirm.png) · [输入回复](ui-ux-evidence/after/01-prompt.png) · [后台标记](ui-ux-evidence/after/01-background.png) |
| 2 | **失败导航重试错地址**。从已打开页面访问断连网址，横幅重新加载了旧页。重试应指向失败目标，工具栏刷新仍作用于当前页。 | [截图](ui-ux-evidence/before/25-navigation-error.png) | 已验证 | [失败网址与重试按钮](ui-ux-evidence/after/02-retry.png) |
| 3 | **休眠丢失表单草稿**。普通页面休眠前没有提示，恢复后未提交的输入消失。应在释放页面前说明影响并允许取消。 | [截图](ui-ux-evidence/before/20-suspended-front.png) | 已验证 | [草稿与休眠确认](ui-ux-evidence/after/03-before-suspend.png) |
| 4 | **搜索改变工作目标**。输入筛选词即切换 Space，零结果时打开网页还会向其他 Space 建页。应通过点击或回车切换，零结果提供清除搜索和新建入口。 | [截图](ui-ux-evidence/before/08-no-match.png) | 已验证 | [无匹配时保留当前页](ui-ux-evidence/after/04-no-match.png) |
| 5 | **创建失败清空表单**。名称出错后表单关闭，已填的代理地址和证书路径丢失。应就地报错并保留输入，创建成功后关闭。 | [提交前](ui-ux-evidence/before/05-create.png) · [失败](ui-ux-evidence/before/06-create-error.png) · [重开](ui-ux-evidence/before/07-reopened-form.png) | 已验证 | [错误与原输入同屏](ui-ux-evidence/after/05-inline-error.png) |

## 第二批 · 手动浏览与标签页

| 编号 | 问题与预期 | 修复前证据 | 状态 | 修复后证据 |
| --- | --- | --- | --- | --- |
| 6 | **首次启动地址栏不可输入**。地址栏提示输入网址，却需要先点击中央按钮。允许首次直接输入并打开。 | [截图](ui-ux-evidence/before/01-first-launch.png) | 已验证 | [首次输入](ui-ux-evidence/after/06-first-address.png) |
| 7 | **标签标题过早截断**。单标签也仅显示省略号，多标签溢出后难以寻找。让短标题完整显示，并提供完整标题列表。 | [截图](ui-ux-evidence/before/03-working.png) | 已验证 | [完整标题列表](ui-ux-evidence/after/07-tab-list.png) · [窄窗标签栏](ui-ux-evidence/after/07-tab-strip.png) |
| 8 | **地址栏隐藏端口和协议**。本地不同端口在常态下都显示同一主机名。保留非默认端口，区分明文连接。 | [截图](ui-ux-evidence/before/03-working.png) | 已验证 | [常态地址](ui-ux-evidence/after/08-http-origin.png) |
| 9 | **手动打开的弹窗没有反馈**。前台点击授权型按钮后子页在后台打开。应切换到子页或提供查看入口。 | [截图](ui-ux-evidence/before/23-manual-popup.png) | 已验证 | [父页查看入口](ui-ux-evidence/after/09-popup-notice.png) |
| 10 | **手动浏览缺少导航与查找入口**。工具栏和菜单缺少后退、前进、页内查找。 | [工具栏](ui-ux-evidence/before/03-working.png) · [基线应用菜单](https://github.com/viko16/agent-webkit/blob/6651d9fa6b9cdb7d3b00d9739788ce4257928c38/Sources/Browser/main.swift) | 已验证 | [页内命中和历史按钮](ui-ux-evidence/after/10-page-find.png) |
| 11 | **关闭确认缺少页名**。确认框只显示 Space 名称，应显示目标页标题和主机，并解释最后一页为何不可关闭。 | [截图](ui-ux-evidence/before/11-close-recent.png) | 已验证 | [关闭目标与主机](ui-ux-evidence/after/11-close-target.png) |

## 第三批 · Agent 交接和执行状态

| 编号 | 问题与预期 | 修复前证据 | 状态 | 修复后证据 |
| --- | --- | --- | --- | --- |
| 12 | **Agent 交接入口难发现**。通用分享图标和底部短暂反馈相距很远。按钮应说明交给 Agent，并就地反馈已复制。 | [截图](ui-ux-evidence/before/02-new-tab.png) | 已验证 | [按钮原位反馈](ui-ux-evidence/after/12-copy-feedback.png) |
| 13 | **Space 忙碌时缺少具体目标**。后台页执行时，当前页地址栏还能编辑，回车却不导航。说明占用页面并保留地址草稿。 | [截图](ui-ux-evidence/before/16-other-tab-busy.png) | 已验证 | [忙碌目标与地址草稿](ui-ux-evidence/after/13-busy-draft.png) |
| 14 | **窗口没有下载管理入口**。下载时看不到进度或文件位置，休眠被拒绝后也无法从窗口取消下载。 | [截图](ui-ux-evidence/before/24-manual-download.png) | 已验证 | [运行中和已完成下载](ui-ux-evidence/after/14-downloads.png) |
| 15 | **固定视口被窗口裁掉**。Agent 固定大视口时，窄窗口看不到右下方控件。应标出视口尺寸并支持缩放预览。 | [截图](ui-ux-evidence/before/18-fixed-viewport.png) | 已验证 | [窄窗完整预览](ui-ux-evidence/after/15-viewport-preview.png) |
| 16 | **近期活动掩盖待处理状态**。多个标签只显示近期时钟。正在执行和等人应答应更易分辨。 | [截图](ui-ux-evidence/before/03-working.png) | 已验证 | [执行中的页面](ui-ux-evidence/after/16-executing.png) · [网页待回复](ui-ux-evidence/after/01-background.png) |

## 第四批 · 报错、恢复与状态反馈

| 编号 | 问题与预期 | 修复前证据 | 状态 | 修复后证据 |
| --- | --- | --- | --- | --- |
| 17 | **过期错误占据底栏**。切页、成功导航或下载完成后，仍可能显示上一个操作的错误。 | [截图](ui-ux-evidence/before/14-popup.png) | 已验证 | [重试成功后旧提示消失](ui-ux-evidence/after/17-recovered.png) |
| 18 | **轻微错误打断操作，网络错误重复**。地址格式错误弹出模态框，网络错误同时出现在弹框、横幅和底栏。应按操作就地提示。 | [截图](ui-ux-evidence/before/09-invalid-address.png) | 已验证 | [地址栏就地报错](ui-ux-evidence/after/18-invalid-inline.png) · [网络错误横幅](ui-ux-evidence/after/18-single-error.png) |
| 19 | **错误操作与原因不符**。不支持的协议也显示重新加载。代理冲突时，底栏仍提示可以交接。 | [截图](ui-ux-evidence/before/15-unsupported-link.png) | 已验证 | [忽略外部链接](ui-ux-evidence/after/19-external.png) · [重新检查代理](ui-ux-evidence/after/19-proxy.png) |
| 20 | **休眠恢复用词不一致**。中央打开网页和侧栏恢复指向相同动作。应显示可恢复的标签数量和目标。 | [截图](ui-ux-evidence/before/20-suspended-front.png) | 已验证 | [恢复目标和标签数](ui-ux-evidence/after/20-resume.png) |

## 第五批 · 布局、可读性与表单

| 编号 | 问题与预期 | 修复前证据 | 状态 | 修复后证据 |
| --- | --- | --- | --- | --- |
| 21 | **窄窗口隐藏核心动作**。地址栏挤占空间，交接和新标签被收入溢出菜单。 | [截图](ui-ux-evidence/before/27-dark-narrow.png) | 已验证 | [760 pt 工具栏](ui-ux-evidence/after/21-dark-narrow.png) · [活动窗口对照](ui-ux-evidence/after/22-dark-wide.png) |
| 22 | **深色外观底栏文字难读**。切换外观后底栏出现深底深字，应跟随系统语义颜色。 | [截图](ui-ux-evidence/before/26-dark-wide.png) | 已验证 | [深色宽窗](ui-ux-evidence/after/22-dark-wide.png) · [浅色对照](ui-ux-evidence/after/23-sidebar.png) |
| 23 | **侧栏截掉环境名和状态**。同前缀名称难区分，休眠或暂停信息可能被截断。 | [截图](ui-ux-evidence/before/14-popup.png) | 已验证 | [同前缀的两个环境](ui-ux-evidence/after/23-sidebar.png) |
| 24 | **新建表单缺少常驻标签**。填写后看不到字段用途，CA 路径要求手输。应保留字段标签并提供文件选择。 | [截图](ui-ux-evidence/before/05-create.png) | 已验证 | [折叠表单](ui-ux-evidence/after/24-form-basic.png) · [高级选项及错误状态](ui-ux-evidence/after/24-form-advanced.png) |
| 25 | **Space 策略与当前连接混淆**。明文 HTTP 页底部仍显示系统证书校验，信息面板重复网络信息。应区分当前连接和证书策略。 | [截图](ui-ux-evidence/before/28-space-info.png) | 已验证 | [Space 策略与底栏当前连接](ui-ux-evidence/after/25-space-policy.png) |

## 补充 · 本次随第一批修复

| 编号 | 问题与预期 | 修复前证据 | 状态 | 修复后证据 |
| --- | --- | --- | --- | --- |
| 26 | **新建表单左右边距不一致**。高级配置中的输入框贴住右边，左侧有明显留白。折叠、展开和报错时都应保留对称的内容边距。 | [用户截图](ui-ux-evidence/before/26-sheet-insets.png) | 已验证 | [折叠](ui-ux-evidence/after/26-collapsed.png) · [展开](ui-ux-evidence/after/26-expanded.png) · [报错](ui-ux-evidence/after/05-inline-error.png) |

## 第一批验收

使用独立数据目录和本机测试网页启动观察窗口，通过原生控件操作并截取当前窗口。截图展示界面状态，以下结果另外核对了页面返回值、服务端请求或 AppKit 布局。

- **网页对话框**。前台分别关闭 alert、取消 confirm、在 prompt 中输入 `reply`，网页收到对应结果。后台标签触发 confirm 后观察目标保持不变，CLI 回应后待处理标记消失。
- **失败导航**。先打开正常页面，再访问主动断开连接的 `/retry-target`。服务恢复后点击「重试此网址」，服务端收到对该路径的新 GET，标签页也切到了该网址。
- **休眠**。填入 `Unsaved draft` 后点休眠，确认框出现在释放页面之前。取消后从网页读回原文，再次休眠并确认后进入休眠状态，随后可恢复。
- **搜索**。筛选另一个 Space、清空搜索和输入无匹配词均保留原来的 Space 与标签页。零结果按回车不增加标签页，可清除搜索或打开新建表单。筛得结果并按回车后才切换。
- **创建与边距**。中文名称和无效证书分别触发创建失败，原表单仍可编辑。改用有效设置后创建成功并选中新 Space。测量可见输入框到表单两侧的距离，折叠时为 20 / 20 pt，展开及显示错误时三个输入框均为 20 / 20 pt。

审查后再次构建并完成上述窗口验收。原生前台回归通过 127 个交互步骤，导航专项通过 34 项检查。回归覆盖多结果搜索时回车选择高亮行、长 prompt 直接确认保留完整默认值，以及失败网址隐藏登录凭据。

## 第二批验收

- 从空数据目录直接输入本机网址，只创建一个 personal Space 和一个标签页。常态地址能看到 HTTP 和实际端口。先后打开两个测试页，点后退、前进后分别核对实际 URL。
- 从编辑菜单查找 `Popup`，网页高亮匹配文字，查找栏显示「已找到」。改为不存在的词后显示「未找到」。采用 macOS 的查找、下一处和上一处快捷键。[Apple HIG · Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- 点击网页上要求真实鼠标操作的按钮后，父页显示「查看新标签页」。点击提示才切换至 Popup Child。提示紧邻网页，后台创建子页保留观察目标。[Apple HIG · Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback)
- 在 760 pt 窗口创建六个标签。常态地址栏仍显示协议和端口，从完整标题列表选中最后一项，核对了目标 ID。只剩一页时，悬停标题可读到保留原因。关闭确认包含目标页名、主机和需要确认的原因，取消后目标仍在。

### 第 27 项 · 标签页关闭按钮

原先只有标题按钮绘制背景，× 在标签右侧独立占位。[修复前](ui-ux-evidence/before/03-working.png)

参照用户提供的 Safari 截图，将 × 放进标签左侧，图标和页名一起居中。选中页显示 ×，其他页移入指针时才显示，只剩一页时收起。通过窗口鼠标事件点击后台标签的 ×，确认框指出后台页名，取消后原选中页保持不变。[选中状态](ui-ux-evidence/after/27-tabs-selected.png) · [后台页悬停](ui-ux-evidence/after/27-tabs-hover.png) · [Apple · 在 Mac 上的 Safari 中关闭标签页](https://support.apple.com/zh-cn/guide/safari/ibrw27660e60/mac)

## 第三批验收

- 点击「交给 Agent」，按钮原位显示「已复制」。在独立测试剪贴板读回命令，核对 Space 和标签 ID。等待后台页执行时，底栏显示该页标题；按回车保留输入，结束后再次回车才导航。「查看执行页」会选中实际持有操作锁的页。[Apple HIG · Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback)
- 固定 CSS 视口为 1440 × 900，把窗口缩到 760 pt 后打开静态预览，可以看到页面右下角的「继续」。在打开前、显示时及关闭后读取网页的 `innerWidth` 和 `innerHeight`，三次结果相同。
- 当前等待用户或仍在执行的页面在标签上显示对应标记。操作结束后，近五分钟的活动可从标签提示查看。
- 下载面板按标签展示当前 Space 的任务。实测同时显示 41 字节的已完成文件，以及收到 41 / 141 字节的下载。休眠受阻时可直接进入管理面板，取消后由 CLI 核对终态。测试点击「在访达中显示」并截获系统调用，确认目标是实际下载的非空文件。[Apple HIG · Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)

## 第四批验收

- 空资料目录中输入无效网址，原输入保留，提示出现在地址栏下方。访问主动断开连接的本机服务，只有网页横幅提示失败；服务恢复后点击重试，实际 URL 更新，旧错误消失。[Apple HIG · Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback)
- 另用延迟 18 秒的页面触发等待超时。同一次导航最终成功后横幅自动消失。粘贴 `mailto:` 或 `tel:` 会保留输入并提示修正；单词形式的内网主机如需指定端口，可写完整的 `http://主机名:端口`。
- 点击不支持的外部链接后选择「忽略」，原页面仍在。仅对测试进程模拟系统代理冲突，横幅和底栏均显示已暂停。重新检查时代理仍开启会继续提示，解除模拟冲突后恢复。
- 有两个标签页时停留在「评审记录」，确认休眠后，中央显示两个标签页及原页名，侧栏和中央都能「恢复 Space」。恢复后核对原标签 ID 和实际网址；旧记录缺少标题时回退到可读网址或「新标签页」。

## 第五批验收

- 将窗口缩到 760 pt，通过原生工具栏的可见项目核对「交给 Agent」、新建标签页和地址栏。分别触发两个工具栏动作，观察到「已复制」反馈和标签数从一变二。窄窗图截取非活动窗口的完整工具栏，宽窗图可对照活动状态。同一窗口从浅色切到深色后，底栏的系统文字颜色随之改变。[Apple HIG · Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) · [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
- 两个 Space 名只有环境后缀不同，收窄侧栏后仍可区分，休眠状态排在连接方式和页数之前。悬停和辅助功能保留完整名称及状态。[Apple HIG · Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- HTTP 页面底栏显示「HTTP（未加密）」，打开信息面板可以分别读到 Space 的连接方式与证书策略。连接类型取自已提交的当前文档。
- 展开新建表单并触发名称错误后，名称、连接方式、代理地址、证书策略、CA 证书五行的左右外边距分别为 20 / 20 pt。字段标签和已填内容均保留，点击 CA 证书旁的「选择…」会打开系统文件选择器。[Apple HIG · Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields)
- 系统选择器实测进入指定的测试目录，取消后保留原路径。用 AppKit 测试面板返回选中的 PEM 文件，经生产回调核对表单和创建请求中的证书路径一致。系统文件列表内的双击未实测。

最终版本通过调试构建、164 个原生窗口回归步骤、34 项导航检查和 10 项连接状态检查。连接检查覆盖三种 Space 证书策略、服务重启后恢复选中页，以及通过 HTTPS 加载测试页时的证书警示。

## 第六批 · Space 侧栏操作

**28 · 新建、休眠和删除在左下角并排，三个等宽按钮让删除和日常操作同样醒目。** 将新建入口放在 Spaces 标题旁，把所选 Space 的休眠、恢复和删除放入原生菜单。底部保留状态文字。[修复前](ui-ux-evidence/after/23-sidebar.png) · [Apple HIG · Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) · [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) · [Menus](https://developer.apple.com/design/human-interface-guidelines/menus)

- 在 760 pt 窗口中，「＋」和「更多操作」与 Spaces 标题同排，列表可以一直延伸到底部数量上方。两项控件都有中文辅助功能名称。空资料目录也可以通过「＋」打开创建表单。[侧栏布局](ui-ux-evidence/after/28-sidebar-actions.png)
- 在独立测试窗口展开原生菜单，活动 Space 显示「休眠 Space…」，休眠后切换为「恢复 Space」。删除始终单独列在分隔线下方。[浅色 · 活动 Space](ui-ux-evidence/after/28-sidebar-menu.png) · [深色 · 休眠 Space](ui-ux-evidence/after/28-sidebar-dark.png)
- 调试构建通过。修正菜单展开通知的回调签名后重新运行原生窗口回归，最终报告记录了 166 次交互与状态读取。搜索无匹配时「更多操作」停用，「＋」仍能打开表单。选择「恢复 Space」后核对了实际运行状态，选择「删除 Space…」后核对了确认框和取消行为。截图通过独立 AppKit 窗口采集。

## 第二轮 · 键盘、窗口和 Space 状态

本轮从 `9a70961` 的调试构建重新启动 App。第 29、30、33、35 项能对应到 HIG 的具体指引。第 31、32、34 项依据 HIG 对反馈和浮层的建议，结合观察窗口的实际行为作出调整。

| 编号 | 复现与影响 | 修复与验证 | Apple HIG |
| --- | --- | --- | --- |
| 29 | 在新建 Space 的名称中输入 `review`，再追加 `-edited`。按 ⌘Z 后追加的文字仍在。「编辑」菜单缺少撤销、重做和剪切。[修复前](ui-ux-evidence/before/29-edit.png) | 补齐标准编辑命令，由当前编辑控件处理。前台表单中，⌘Z 恢复为 `review`，⇧⌘Z 恢复为 `review-edited`。[撤销后](ui-ux-evidence/after/29-edit.png) | [标准快捷键](https://developer.apple.com/design/human-interface-guidelines/keyboards#Standard-keyboard-shortcuts) · [编辑菜单](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar#Edit-menu) |
| 30 | 只有一页时隐藏观察窗口，按 ⌘T，再打开窗口，已经有两页。「关于」面板在前时也能改变背后的观察窗口。[修复前](ui-ux-evidence/before/30-hidden-tabs.png) | 观察窗口隐藏、最小化、带有附属表单，或其他窗口正在接收输入时，停用相应的观察菜单命令。「窗口 → 显示观察窗口」可找回隐藏或最小化的窗口。重复原操作后仍只有一页。[修复后](ui-ux-evidence/after/30-hidden-tabs.png) | [菜单项的可用状态](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar#Best-practices) |
| 31 | 打开 `personal` 的资料，再通过 CLI 删除该测试 Space。主窗口自动选中 `staging`，浮层仍然显示已删除 Space 的名称和证书策略。[旧浮层](ui-ux-evidence/before/31-stale-space.png) | 选中另一个 Space 时关闭旧资料。实测删除后浮层已关闭，再打开时标题和 ID 都属于 `staging`。[重新打开](ui-ux-evidence/after/31-current-space.png) | [浮层与来源控件](https://developer.apple.com/design/human-interface-guidelines/popovers) |
| 32 | 休眠 Space 后，「Space 信息」随网页操作一起停用。要查看连接方式或证书策略，只能先恢复网页。[休眠时的工具栏](ui-ux-evidence/before/32-suspended-space.png) | 按所选 Space 决定信息按钮是否可用。打开休眠 Space 的资料后，CLI 读回的状态仍为 `suspended`。[休眠页与资料浮层](ui-ux-evidence/after/32-suspended-space.png) | [在当前上下文中提供状态](https://developer.apple.com/design/human-interface-guidelines/feedback) |
| 33 | 选择「使用自定义 CA」，留空证书路径，再折叠高级选项。「创建」停用，可见字段看起来都已填好。[修复前](ui-ux-evidence/before/33-missing-ca.png) | 折叠控件直接提示「需选择 CA 证书」。展开后仍可输入路径或打开系统选择器，保留已选的证书策略。[修复后](ui-ux-evidence/after/33-missing-ca.png) | [让用户知道哪些数据必填](https://developer.apple.com/design/human-interface-guidelines/entering-data#Best-practices) |
| 34 | 模拟直连 Space 的系统代理冲突。点「重新检查」后出现「系统代理仍已开启」，同一 Space 的侧栏一刷新，横幅就恢复首次提示，用户难以判断刚才的检查结果。[刷新后丢失反馈](ui-ux-evidence/before/34-proxy-recheck.png) | 为当前 Space 保留这次检查的结果。同样的刷新后仍显示「系统代理仍已开启」。解除测试冲突并重新检查后，横幅消失。[修复后](ui-ux-evidence/after/34-proxy-recheck.png) | [反馈与操作结果](https://developer.apple.com/design/human-interface-guidelines/feedback) |
| 35 | 侧栏展开和折叠时，「显示」菜单都写「显示／隐藏侧边栏」。没有标签页时，「上一个」「下一个」也可选，点击没有效果。[空窗口的菜单](ui-ux-evidence/before/35-sidebar-menu.png) | 菜单根据布局显示「隐藏侧边栏」或「显示侧边栏」，沿用 ⌃⌘S。当前 Space 有两页及以上才启用切换命令。[侧栏已折叠](ui-ux-evidence/after/35-sidebar-menu.png) | [显示菜单的切换命令](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar#View-menu) · [菜单项的可用状态](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar#Best-practices) |

### 本轮覆盖与边界

| 界面 | 实际检查 |
| --- | --- |
| 首次启动、侧栏与标签 | 从空资料目录输入网址。检查零匹配、清除筛选、折叠后搜索、Space 操作菜单、六标签溢出列表和选中目标。通过标签的辅助功能关闭动作唤起确认框，取消后保留原页。 |
| 新建表单与文件选择器 | 切换直连、HTTP 代理和自定义 CA。验证非法名称就地报错、五行左右边距、取消选证书后保留路径。名称字段按 Tab 移到代理地址，⇧Tab 返回名称，Esc 关闭表单。 |
| 网页、工具栏与提示 | 执行后退、前进、页内查找、复制交接命令。通过网页读回 alert 继续执行、confirm 取消及 prompt 默认回复。核对固定视口预览关闭后网页仍是 1440 × 900。 |
| 浮层、确认框与窗口菜单 | 打开 Space 资料和空下载面板。查看跨标签的进行中及已完成下载，核对取消后的终态，并在测试进程中截获「在访达中显示」请求，确认目标是已下载文件。验证休眠与删除确认可取消，检查「关于」、隐藏及重新显示观察窗口。 |
| 尺寸、外观与辅助功能 | 分别在 760 和 1220 pt 宽的窗口切换浅深色。核对地址栏、交接、新标签仍在工具栏，底栏文字随外观切换。读取侧栏和表单的辅助功能名称、六个标签的角色、完整名称及选中值。 |

测试 App 使用独立资料目录、回环测试网页和专用交接剪贴板。通过独立的辅助功能客户端，在打包后的 App 中读取地址栏、搜索框及侧栏按钮的名称，用 AXPress 打开新建表单，再取消。其余专项在同一套产品源码构建的 App 中，从进程内派发原生菜单、键盘和控件操作。剪切核对菜单可用状态，撤销和重做另行核对字段实际内容。

窗口截图按测试窗口编号采集。菜单图在测试窗口内展开实际的「显示」菜单。PNG 转为标准 sRGB 后，只保留图像数据及颜色标记。VoiceOver 的实际朗读顺序、盲文显示及系统级「完全键盘控制」未实测。

复审时另测了「文件 → 隐藏观察窗口」。原先「关于」在前时按 ⇧⌘W 仍会隐藏背后的观察窗口。修正后，「关于」或创建表单在前时观察窗口保持可见，观察窗口在前时同一快捷键正常隐藏它。

最终调试构建通过。运行 `BROWSER_TEST_FOREGROUND=1 python3 tests/search_selection_cases.py` 后，回归报告记录了 170 次控件操作与状态读取。测试覆盖后台页执行、弹出子页、导航失败及重试、休眠与恢复、下载阻止退出，以及确认期间关闭目标发生变化。关闭与隐藏快捷键均由真实前台窗口接收。
