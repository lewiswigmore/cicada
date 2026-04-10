# Cicada — Step-by-step install guide

Everything below runs in the terminal. No GUI installers needed.

This guide assumes a fresh Windows machine with nothing pre-installed. If you
already have some dependencies, each step starts with a check — skip what you
already have.

---

## What you will install

| Dependency           | Required | What it does                        | Install command                          |
|----------------------|----------|-------------------------------------|------------------------------------------|
| PowerShell 7+       | Yes      | Runs Cicada                         | `winget install Microsoft.PowerShell`    |
| Windows Terminal     | Yes      | Hosts the multi-pane agent layout   | `winget install Microsoft.WindowsTerminal` |
| Git                  | Yes      | Clones the Cicada repo              | `winget install Git.Git`                 |
| GitHub Copilot CLI   | Yes      | Powers each AI agent                | `winget install GitHub.CopilotCLI`       |
| Python 3.10+        | Optional | Enables MCP team coordination tools | `winget install Python.Python.3.12`      |

---

## Step 0 — Open a terminal and check winget

Open **PowerShell** from the Start menu (the built-in Windows PowerShell 5.1 is
fine for bootstrapping).

```powershell
winget --version
```

If this prints a version number, you are good. Move on to Step 1.

If `winget` is not recognized, you need to install or update **App Installer**
from the Microsoft Store:

```powershell
# Open the App Installer page in Microsoft Store
Start-Process "ms-windows-store://pdp?productid=9NBLGGH4NNS1"
```

Install or update it, then **close and reopen PowerShell** and verify:

```powershell
winget --version
```

---

## Step 1 — Install PowerShell 7

**Check:**

```powershell
pwsh --version
```

If this prints `PowerShell 7.x.x` or higher, skip to Step 2.

**Install:**

```powershell
winget install Microsoft.PowerShell
```

**Close your terminal and reopen it** so the new `pwsh` command is on your PATH.

**Switch into PowerShell 7 now** — the rest of this guide must run in `pwsh`:

```powershell
pwsh
```

Verify you are in PowerShell 7:

```powershell
$PSVersionTable.PSVersion
```

You should see `7.x.x`. If you still see `5.x`, you are in the wrong shell —
type `pwsh` to switch.

> **Important:** From this point forward, every command must run in `pwsh`
> (PowerShell 7), not Windows PowerShell 5.1. Cicada's module requires
> PowerShell 7.0 or higher.

---

## Step 2 — Install Windows Terminal

**Check:**

```powershell
Get-Command wt -ErrorAction SilentlyContinue | Select-Object Source
```

If this prints a path, skip to Step 3. Windows 11 usually has it pre-installed.

**Install:**

```powershell
winget install Microsoft.WindowsTerminal
```

Close and reopen your terminal, then verify:

```powershell
wt --version
```

---

## Step 3 — Install Git

**Check:**

```powershell
git --version
```

If this prints a version, skip to Step 4.

**Install:**

```powershell
winget install Git.Git
```

**Close and reopen your terminal**, then verify:

```powershell
git --version
```

---

## Step 4 — Install GitHub Copilot CLI

**Check:**

```powershell
copilot --version
```

If this prints a version, skip ahead to the authentication check below.

**Install:**

```powershell
winget install GitHub.CopilotCLI
```

**Close and reopen your terminal**, then verify:

```powershell
copilot --version
```

### Authenticate

Copilot CLI needs to be linked to your GitHub account. Run:

```powershell
copilot auth
```

This opens an interactive authentication flow (browser-based device code). Follow
the prompts to sign in with your GitHub account.

> **Copilot subscription required.** You need an active GitHub Copilot plan
> (Individual, Business, or Enterprise). If you have a GitHub account but no
> Copilot access, the CLI will install but agents will not work. Check your
> subscription at https://github.com/settings/copilot.

Verify authentication worked:

```powershell
copilot --version
```

If it prints the version without errors, you are authenticated.

---

## Step 5 — Install Python (optional)

Python enables Cicada's MCP coordination features: inter-agent messaging, shared
task boards, and the live monitor's activity feed. Without Python, Cicada still
works in prompt-only mode.

**Check:**

```powershell
python --version
```

If this prints `Python 3.10.x` or higher, skip to Step 6.

### Windows Store alias issue

On a fresh Windows install, typing `python` may open the Microsoft Store instead
of running Python. If that happens:

1. Close the Store window that opened
2. Disable the Store alias:
   - Open **Settings > Apps > Advanced app settings > App execution aliases**
   - Turn off `python.exe` and `python3.exe`
3. Then install Python properly:

**Install:**

```powershell
winget install Python.Python.3.12
```

**Close and reopen your terminal**, then verify:

```powershell
python --version
```

You should see `Python 3.12.x` (or whichever 3.10+ version you installed).

If `python` still opens the Store or is not found after a terminal restart,
check that the Store alias is disabled (see above) and that Python's install
directory is on your PATH.

---

## Step 6 — Clone and install Cicada

Make sure you are in `pwsh` (PowerShell 7) before running this:

```powershell
git clone https://github.com/lewiswigmore/cicada.git
cd cicada
pwsh -File .\Install-Cicada.ps1
```

This copies the Cicada PowerShell module to your user modules directory and
installs the Python MCP package (if Python is available).

The installer runs in a subprocess, so you need to load the module in your
current session:

```powershell
Import-Module Cicada
```

Verify it loaded:

```powershell
cicada --help
```

> **Downloaded a ZIP instead of cloning?** Extract it, `cd` into the extracted
> folder, and run the same `Install-Cicada.ps1` command. If scripts are blocked,
> run `Unblock-File .\Install-Cicada.ps1` first.

---

## Step 7 — Make cicada available in every session

The installer loads the module for your current session, but to keep it
available after you close and reopen your terminal, add it to your PowerShell
profile:

```powershell
# Create the profile file if it does not exist yet
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Force -Path $PROFILE | Out-Null
}

# Append the import line
Add-Content -Path $PROFILE -Value "`nImport-Module Cicada"
```

Verify it took effect:

```powershell
# Reload profile
. $PROFILE

# Check the command exists
Get-Command cicada
```

---

## Step 8 — Verify everything

```powershell
cicada --doctor
```

This checks every dependency and reports status. A healthy output looks like:

```
  Cicada Doctor v0.1.0
  Checking dependencies...

  [OK] pwsh 7.x.x
  [OK] git 2.x.x
  [OK] wt.exe
  [OK] copilot 1.x.x
  [OK] python 3.12.x
  [OK] cicada-mcp 0.1.0
  [OK] MCP server importable
  [OK] roles.json (4 roles)

  All checks passed.
```

Items marked `[--]` are optional warnings. Items marked `[!!]` need fixing —
follow the hint next to each one.

---

## Step 9 — Launch your first team

```powershell
cicada
```

This opens Windows Terminal with four agents (Coder, Reviewer, Tester,
Researcher) in a 2x2 grid plus a live monitor sidebar.

Try a smaller team first if you prefer:

```powershell
cicada --team "coder,reviewer"
```

See `cicada --help` for all options, or read [USAGE.md](USAGE.md) for common
patterns.

---

## Quick reference — full install in one block

If you just want to copy-paste everything at once (still in `pwsh`):

```powershell
# Install prerequisites
winget install Microsoft.PowerShell
winget install Microsoft.WindowsTerminal
winget install Git.Git
winget install GitHub.CopilotCLI
winget install Python.Python.3.12

# Restart your terminal after this, then open pwsh:
# pwsh

# Authenticate Copilot CLI
# copilot auth

# Clone and install Cicada
git clone https://github.com/lewiswigmore/cicada.git
cd cicada
pwsh -File .\Install-Cicada.ps1

# Add to profile
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Force -Path $PROFILE | Out-Null }
Add-Content -Path $PROFILE -Value "`nImport-Module Cicada"
. $PROFILE

# Verify
cicada --doctor

# Launch
cicada
```

> **Important:** You must close and reopen your terminal after the `winget
> install` block, switch into `pwsh`, and run `copilot auth` before the clone
> step will fully work.

---

## Troubleshooting

### "winget is not recognized"

Your Windows version may not include App Installer. Install or update it from
the Microsoft Store:

```powershell
Start-Process "ms-windows-store://pdp?productid=9NBLGGH4NNS1"
```

Then close and reopen your terminal.

### "pwsh is not recognized" after installing PowerShell 7

Close your terminal completely and reopen it. Winget installs update the PATH
but existing sessions do not pick up the change.

### "copilot is not recognized" after installing

Same as above — close and reopen your terminal. If it still fails, check:

```powershell
winget list GitHub.CopilotCLI
```

If listed but the command is missing, the install directory may not be on your
PATH. Try opening a new Windows Terminal tab instead.

### Copilot CLI installs but authentication fails

- Verify you have an active Copilot subscription: https://github.com/settings/copilot
- Corporate proxies may block the OAuth device flow — try from a personal network
- If behind a firewall, you may need to set `HTTPS_PROXY`

### Python command opens Microsoft Store

Disable the Store alias:

1. **Settings > Apps > Advanced app settings > App execution aliases**
2. Turn off `python.exe` and `python3.exe`
3. Close and reopen your terminal
4. Run `python --version` again

### "Install-Cicada.ps1 cannot be loaded because running scripts is disabled"

PowerShell's default execution policy may block scripts:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Then retry the install.

### "Install-Cicada.ps1 is not digitally signed" (downloaded ZIP)

Windows marks downloaded files as untrusted:

```powershell
Get-ChildItem -Recurse | Unblock-File
pwsh -File .\Install-Cicada.ps1
```

### cicada --doctor shows "[!!] MCP server import failed"

This usually means a Python package conflict. Try reinstalling:

```powershell
pip install --force-reinstall cicada-mcp
```

Or from the Cicada directory:

```powershell
pip install --force-reinstall -e .
```

### Corporate or managed device restrictions

Some organizations restrict `winget`, block GitHub OAuth, or use proxy servers.
If you cannot install dependencies through `winget`:

- Ask your IT team for approved install methods
- Check if `scoop` or `chocolatey` are available as alternatives
- For GitHub auth issues behind a proxy, set the environment variable:
  ```powershell
  $env:HTTPS_PROXY = "http://your-proxy:port"
  ```

---

## Updating Cicada

If you installed via git clone:

```powershell
cicada --update
```

This runs `git pull --ff-only` and updates the Python MCP package.

If you installed from a downloaded ZIP, re-download and re-run the installer:

```powershell
cd cicada
git pull
pwsh -File .\Install-Cicada.ps1
```

---

## Uninstalling

```powershell
# Remove the module
Remove-Item "$(Split-Path $PROFILE)\Modules\Cicada" -Recurse -Force

# Remove the Import-Module line from your profile
(Get-Content $PROFILE) -notmatch 'Import-Module Cicada' | Set-Content $PROFILE

# Remove local data (optional)
Remove-Item "$HOME\.cicada" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$HOME\.copilot\cicada-state.json" -Force -ErrorAction SilentlyContinue
```
