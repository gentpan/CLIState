# Changelog

## 0.2.1

**新增 / Added**
- 新增“发现”页面：按开发入门、PHP、Python、影音处理分类展示 8 个精选工具，支持搜索、已安装识别和单个／批量安装预览。
- Discover curated developer, PHP, Python and media tools, with search, installed detection and individual or batch installation previews.
- 概览增加可视化环境检查、安装来源圆环图和可处理项入口；历史趋势按实际记录展示。
- Visual environment checks, an interactive installation-source chart and actionable maintenance in Overview.

**改进与修复 / Improvements and fixes**
- 工具页分类改为紧凑的原生分段选择控件，缩小筛选按钮，窄窗口自动切换为分类菜单。
- Tools categories now use a compact native segmented control, with a smaller filter button and a category menu for narrow windows.
- 对齐侧边栏首行与概览首张卡片的顶部位置。
- Aligned the first sidebar row with the top edge of the first Overview card.
- 浅色外观统一白色画布与灰色卡片；深色外观使用炭灰画布，并将侧边栏选中态改为整行圆角块。
- Unified white canvas and gray cards in Light mode, with a charcoal Dark mode and rounded full-row sidebar selection.
- 统一页面标题、原生 Liquid Glass 按钮、表单、筛选与程序字体；优化列表和可关闭的详情面板。
- Consistent page titles, native Liquid Glass controls on macOS 26+, typography, filters and dismissible inspectors.
- 单个更新不再触发完整软件包信息刷新；批量更新先检查新数据，操作后重新扫描。
- Individual updates reuse available package information; batch updates refresh first and operations rescan afterward.
- 清理预览保留来源明确的建议项；无法直接处理的问题提供具体处理方式。
- More reliable cleanup previews and concrete guidance for issues requiring manual attention.
- 卸载结果明确区分被移除的安装来源与仍然存在的其他副本。
- Uninstall results identify the removed provider and any remaining installations.
- 官方更新服务器与 GitHub 备用线路，带签名校验的更新发布。
- Signed update delivery through the official server and GitHub fallback.

## 0.2.0

**说明 / Notes**
- 产品名称改为 CLI State（App 文件名、GitHub 仓库和 Homebrew 安装名 `clistate` 保持不变）。
- The product is now called CLI State (the app file, GitHub repository and Homebrew token `clistate` stay the same).

**新增 / Added**
- 环境迁移：导出当前开发环境（配置文件或 Brewfile），在新 Mac 上导入对比后分步安装；内置 9 套模板，可让 AI 从内置工具清单中推荐。
- Environment restore: export your setup (profile or Brewfile), compare and install it step by step on a new Mac; 9 templates, plus AI suggestions limited to known tools.
- 变更时间线：记录每次扫描之间工具、版本、生效程序和 PATH 的变化，并区分由 CLI State 执行还是外部变更。
- Change timeline: what changed between scans (tools, versions, active binaries, PATH), marked as done by CLI State or external.
- 运行时停止支持提醒：Node、Python、PHP、Go、Ruby、PostgreSQL 等版本已停止或即将停止官方支持时提醒。
- End-of-life reminders for Node, Python, PHP, Go, Ruby, PostgreSQL and more.
- AI 解释：用 Mac 本地的 Apple 模型，或 OpenAI、DeepSeek 等 API，解释某个工具是做什么的、要不要保留。
- Explain with AI using Apple's on-device model or OpenAI, DeepSeek and compatible APIs.
- 工具右键菜单：更新、跳过版本、自动更新设置、服务启停、卸载、卸载并清理残留文件。
- Tool context menu: update, skip version, auto-update policy, services, uninstall, uninstall and clean up leftovers.
- 菜单栏图标与快捷指令：随时查看可更新数和问题数；快捷指令可扫描、检查更新、查询命令。
- Menu bar extra and Shortcuts actions to scan, check for updates and look up a command.
- 设置：浅色 / 深色 / 跟随系统，简体中文 / English。
- Settings: Light / Dark / System appearance and language choice.

**改进 / Improved**
- 全新概览页：已安装、可更新、问题和占用空间一目了然；列出占用空间最多的工具、最近使用的工具和 90 天以上没用过的工具，以及安装方式和分类分布。
- New Overview dashboard: installed tools, updates, issues and disk space at a glance, with the largest tools, recently used tools, tools unused for 90 days, and breakdowns by installer and category.
- 菜单栏面板重新设计，图标改为 App 标志样式；增加强制刷新。
- Redesigned menu bar panel with an app-icon style menu bar icon and a force refresh button.
- App 自身更新支持官方服务器与 GitHub 双线路，连不上时自动切换。
- CLI State updates itself from an update server or GitHub, switching automatically when one can't be reached.
- 工具页重新设计：分类标签和筛选菜单、单行表格、更简洁的详情面板；滚动条改为细的自动隐藏样式。
- Redesigned Tools page: category chips and a filter menu, single-line rows, a cleaner inspector, thin overlay scroll bars.
- 刚检查过更新时，启动不再重复联网，启动更快。
- Faster launch: recent update checks are reused instead of hitting the network again.
- 多个安装时，终端实际使用的那个排在最前。
- The installation your terminal actually runs is listed first.
- Homebrew 连带升级的依赖也记录在历史中。
- Dependencies upgraded alongside a Homebrew package are recorded in History.
- 每次检查更新前先刷新 Homebrew 软件包信息，刚发布的新版本能马上显示；后台可按每小时 / 3 小时 / 6 小时 / 每天自动检查（默认每 3 小时），自动安装仍每天一次；更新页显示软件包信息的实际更新时间。
- Homebrew package info is refreshed before every update check, so new releases show up right away; background checks run every 1, 3, 6 or 24 hours (default 3), automatic installs stay once a day; the Updates page shows how old the package info is.
- 本地数据损坏时自动重新扫描，不会丢失设置。
- Damaged local data is set aside and rescanned without losing your settings.

## 0.1.0

First release / 首个版本

- Environment discovery from your real login shell, PATH resolution chains and shadowing
- Homebrew, npm, uv, pipx, pnpm and Cargo; official installers such as Claude Code
- Attribution with evidence, version detection and update checks
- Update, uninstall, services, previewed cleanup, auto-update policies
- Health checks, diagnostics export, Simplified Chinese and English
