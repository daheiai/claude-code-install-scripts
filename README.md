# Claude Code Install Scripts

This repository contains two install scripts used on `daheiai.com`:

- `cc.ps1` for Windows PowerShell
- `cc.sh` for macOS and Linux shells

Current usage:

```powershell
irm https://daheiai.com/cc.ps1 | iex
```

```bash
curl -fsSL https://daheiai.com/cc.sh | sh
```

Notes:

- The scripts automate Claude Code installation on the local machine.
- Windows users may need to add `C:\Users\<username>\.local\bin\` to user `PATH`.
- macOS and Linux users may need to add `$HOME/.local/bin` to `PATH` if the shell cannot find `claude`.
