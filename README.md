# CLIState

**看清 Mac 上安装的 CLI、运行时和开发工具，并知道终端真正使用的是哪一个版本。**

[English](README.en.md) · [下载](https://github.com/gentpan/CLIState/releases/latest) · [反馈问题](https://github.com/gentpan/CLIState/issues/new/choose)

![CLIState 概览](docs/images/overview.png)

CLIState 是一个原生 macOS 应用，用来理解和管理你的命令行开发环境。它会自动发现通过 Homebrew、npm、uv、pipx、pnpm、Cargo 以及官方安装器装上的工具，按终端的真实 PATH 解析出实际生效的可执行文件，找出重复安装和冲突，并跟踪可用更新。

它不是另一个 Homebrew GUI：Homebrew 关心"Homebrew 里有什么"，CLIState 关心"终端实际是什么环境"。

## 下载安装

1. 从 [Releases](https://github.com/gentpan/CLIState/releases/latest) 下载 `CLIState-<版本>.zip`（已签名并经 Apple 公证）。
2. 解压后把 `CLIState.app` 拖进"应用程序"文件夹。
3. 之后的版本会在 App 内自动提示更新，也可以在 设置 › 关于 里手动检查。

系统要求：macOS 15 或更高版本，支持 Apple Silicon 与 Intel。

## 功能

- **环境发现**：在干净环境里启动你的登录 Shell，读取与新开 Terminal 完全一致的 PATH；识别不存在、重复、受隐私保护的 PATH 目录。
- **解析链**：每个命令按 PATH 顺序列出所有匹配项，标出生效与被遮蔽的安装，并识别 alias / function 遮蔽。
- **来源归属与证据**：说明每个安装是谁装的（Homebrew、npm、uv、pipx、pnpm、Cargo、nvm、rustup、官方安装器、系统……），附带证据和可信度。可信度不足时只读，不做任何修改。
- **版本与更新**：直接询问各包管理器自己的官方源；官方安装器（如 Claude Code）通过发布渠道查询，并标明渠道。
- **健康检查**：PATH 冲突、多重安装、失效链接、缺失的运行时、失败的服务。
- **更新、卸载、服务管理**：只通过原本的包管理器执行。执行前展示确切命令，并用 dry-run 预览连带变化；执行后重新扫描，核对版本。
- **清理**：预览并清理包管理器缓存、旧版本、孤立依赖和失效链接。来源不明的文件只会移到废纸篓，从不直接删除。
- **自动更新策略**：可按工具、按来源或全局设置为关闭、仅提醒（默认）或自动；默认跳过大版本，只在接通电源时运行。

## 支持的来源

| 来源 | 发现 | 检查更新 | 更新 | 卸载 | 服务 | 清理 |
|---|---|---|---|---|---|---|
| Homebrew（formula / 带命令的 cask） | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| npm 全局包 | ✓ | ✓ | ✓ | ✓ | — | ✓ |
| uv tools | ✓ | ✓ | ✓ | ✓ | — | ✓ |
| pnpm 全局包 | ✓ | ✓ | ✓ | ✓ | — | ✓ |
| pipx | ✓ | — | ✓ | ✓ | — | — |
| Cargo | ✓ | ✓ | ✓ | ✓ | — | — |
| 官方安装器（Claude Code 等） | ✓ | ✓ | ✓ | — | — | — |
| nvm / fnm / Volta / mise / asdf / rustup / Bun | ✓ | — | 只读 | — | — | — |
| 系统程序 / 独立安装 | ✓ | — | 只读 | — | — | 失效链接 |

## 安全与隐私

- 从不执行 `sudo`，从不修改 Shell 配置文件。
- 所有外部命令都以独立参数执行，从不拼接 Shell 字符串。
- 读取操作不会修改任何东西；写操作要求归属已确认，并经过你的确认。后台自动更新只对你明确开启的工具生效。
- 从不执行来源不明的程序来探测版本。
- 本地优先：无账号、无遥测、无云同步；不读取 Shell 历史，不扫描项目代码；环境变量只在内存中使用。

## 常见问题

**版本信息从哪里来？** CLIState 不维护自己的软件包数据库，而是询问各包管理器的官方源：Homebrew（formulae.brew.sh）、npm（registry.npmjs.org）、PyPI、crates.io 等。你为 npm、Homebrew、uv 配置的镜像同样生效。

**需要每天手动更新吗？** 不需要。CLIState 每天在设定时间只读地检查一次，默认只提醒；只有你设为"自动"的工具才会在后台更新，而且默认跳过大版本。

**CLIState 自己怎么更新？** App 内置 Sparkle 更新机制，从本仓库的 Releases 获取新版本，并校验签名后才安装。

## 反馈问题

- 遇到 Bug 或识别不准确：[提交 Bug](https://github.com/gentpan/CLIState/issues/new?template=bug_report.yml)。
- 想要新功能或支持新的包管理器：[提交建议](https://github.com/gentpan/CLIState/issues/new?template=feature_request.yml)。
- 附上诊断包能帮助定位问题：设置 › 关于 › 导出诊断包…。诊断包会把主目录替换成 `~`、抹掉账户名，不含环境变量和命令输出；上传前你也可以自行查看内容。
- 安全问题请不要公开提交，使用本仓库的 [Security › Report a vulnerability](https://github.com/gentpan/CLIState/security/advisories/new)。

---

© 2026 GiantAccel, LLC. All rights reserved.
