# Agent WebKit 界面问题与验证记录

基线为 `6651d9f`。下表保留每项问题的修复前证据，并在验收后补充实测结果和截图。

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
| 10 | **手动浏览缺少导航与查找入口**。工具栏和菜单缺少后退、前进、页内查找。 | [应用菜单](../Sources/Browser/main.swift) | 已验证 | [页内命中和历史按钮](ui-ux-evidence/after/10-page-find.png) |
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
| 17 | **过期错误占据底栏**。切页、成功导航或下载完成后，仍可能显示上一个操作的错误。 | [截图](ui-ux-evidence/before/14-popup.png) | 待修复 | 待补 |
| 18 | **轻微错误打断操作，网络错误重复**。地址格式错误弹出模态框，网络错误同时出现在弹框、横幅和底栏。应按操作就地提示。 | [截图](ui-ux-evidence/before/09-invalid-address.png) | 待修复 | 待补 |
| 19 | **错误操作与原因不符**。不支持的协议也显示重新加载。代理冲突时，底栏仍提示可以交接。 | [截图](ui-ux-evidence/before/15-unsupported-link.png) | 待修复 | 待补 |
| 20 | **休眠恢复用词不一致**。中央打开网页和侧栏恢复指向相同动作。应显示可恢复的标签数量和目标。 | [截图](ui-ux-evidence/before/20-suspended-front.png) | 待修复 | 待补 |

## 第五批 · 布局、可读性与表单

| 编号 | 问题与预期 | 修复前证据 | 状态 | 修复后证据 |
| --- | --- | --- | --- | --- |
| 21 | **窄窗口隐藏核心动作**。地址栏挤占空间，交接和新标签被收入溢出菜单。 | [截图](ui-ux-evidence/before/27-dark-narrow.png) | 待修复 | 待补 |
| 22 | **深色外观底栏文字难读**。切换外观后底栏出现深底深字，应跟随系统语义颜色。 | [截图](ui-ux-evidence/before/26-dark-wide.png) | 待修复 | 待补 |
| 23 | **侧栏截掉环境名和状态**。同前缀名称难区分，休眠或暂停信息可能被截断。 | [截图](ui-ux-evidence/before/14-popup.png) | 待修复 | 待补 |
| 24 | **新建表单缺少常驻标签**。填写后看不到字段用途，CA 路径要求手输。应保留字段标签并提供文件选择。 | [截图](ui-ux-evidence/before/05-create.png) | 待修复 | 待补 |
| 25 | **Space 策略与当前连接混淆**。明文 HTTP 页底部仍显示系统证书校验，信息面板重复网络信息。应区分当前连接和证书策略。 | [截图](ui-ux-evidence/before/28-space-info.png) | 待修复 | 待补 |

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
