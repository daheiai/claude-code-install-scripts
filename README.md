# Claude Code 安装脚本

这个仓库包含 `daheiai.com` 当前使用的两个 Claude Code 安装脚本：

- `cc.ps1`：用于 Windows PowerShell
- `cc.sh`：用于 macOS / Linux Shell

当前使用方式：

```powershell
irm https://daheiai.com/cc.ps1 | iex
```

```bash
curl -fsSL https://daheiai.com/cc.sh | sh
```

说明：

- 这两个脚本用于在本地自动化安装 Claude Code。
- Windows 用户安装完成后，可能需要把 `C:\Users\<用户名>\.local\bin\` 加到用户级 `PATH`。
- macOS / Linux 用户安装完成后，如果终端里找不到 `claude`，通常需要把 `$HOME/.local/bin` 加到 `PATH`。
