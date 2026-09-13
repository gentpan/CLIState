# Changelog

## 0.2.0

**新增 / Added**
- 环境迁移：导出当前开发环境（配置文件或 Brewfile），在新 Mac 上导入对比后分步安装；内置 9 套模板，可让 AI 从内置工具清单中推荐。
- Environment restore: export your setup (profile or Brewfile), compare and install it step by step on a new Mac; 9 templates, plus AI suggestions limited to known tools.
- 变更时间线：记录每次扫描之间工具、版本、生效程序和 PATH 的变化，并区分由 CLIState 执行还是外部变更。
- Change timeline: what changed between scans (tools, versions, active binaries, PATH), marked as done by CLIState or external.
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
