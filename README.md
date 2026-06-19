# CodeMate Setup

Windows-first AI coding environment setup assistant.

This MVP focuses on the pre-install checklist:

- Detect required local runtime prerequisites before installing AI coding assistants.
- Flag common Windows setup problems.
- Offer one-click environment installation/preparation for download, install, PATH refresh, and recheck.
- Install selected AI coding tools through a guarded preinstall dialog.
- Export a redacted diagnostic report.

## Run

Double-click:

```text
CodeMate Setup.cmd
```

Safe simulation mode for testing the first two steps without changing the
machine:

```text
CodeMate Setup - Test Mode.cmd
```

Test mode is UI-only simulation. It does not download files, call winget/npm,
start installers, or modify PATH. It is intended for checking the Environment
and Install Tools flows on a machine that already has a working setup.

Open PowerShell in this folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-check.ps1
```

Launch the GUI:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\CodeMate.Setup.ps1
```

Test a provider from command line:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-provider.ps1 -ProviderId custom -BaseUrl "https://example.com/v1" -ApiKey "sk-..." -Model "model-name"
```

Generate a CC Switch profile:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\new-ccswitch-profile.ps1 -Name "My Provider" -BaseUrl "https://example.com/v1" -ApiKey "sk-..." -Model "model-name"
```

## Scope

The first version does not register accounts, request API keys, bypass verification,
proxy traffic, or upload user secrets. All checks and repair actions run locally.
Exported reports are redacted before being written to disk.

## Current Checks

- Windows version
- PowerShell execution policy
- PATH health
- winget
- Git
- Node.js
- npm
- npm global command PATH

Tool install status for Codex App, Codex CLI, Claude Code CLI, Cursor Desktop,
and CC Switch Desktop is shown in the `Install Tools` tab instead of the
pre-install environment checklist.

## Current Tool Install Behavior

Clicking `安装` opens an install preselection dialog. The dialog shows the
official source, the planned install method, and a preselected install folder.
The folder is treated as a preference only: it is passed to the installer only
when the upstream installer or package manager explicitly supports custom
install locations.

- Codex App: downloads the official Microsoft App Installer entry from the
  OpenAI Codex App page.
- Codex CLI: installs with `npm install -g @openai/codex`.
- Claude Code CLI: installs with `npm install -g @anthropic-ai/claude-code`.
- Cursor Desktop: installs with `winget` package `Anysphere.Cursor`.
- CC Switch Desktop: installs with `winget` package `farion1231.CC-Switch`.

After Codex, Claude Code, or Cursor installation completes, the app checks
whether CC Switch is installed. If it is missing, the user sees a guided prompt
explaining why CC Switch may help in regions or network environments where
official login or model connectivity is unstable, then can choose `是，推荐下载`
or `否，暂不需要`.

After CC Switch installation completes, the app opens a login and API access
tutorial. The full local guide is stored at `docs/ccswitch-login-guide.md` and
explains official login, API gateway/Base URL/API Key collection, Provider Test,
profile generation, and CC Switch import.

## Current Environment Install Actions

- Refresh current process PATH
- Set current-user PowerShell execution policy to RemoteSigned
- Add npm global command directory to user PATH
- Add detected Git/Node install directories to user PATH when the tool is installed but the command is missing
- Install Git and Node.js LTS through winget when available
- Fall back to verified installer sources when winget or the default network path fails
- Recheck the environment after install/preparation actions
- Open official setup pages only for actions that cannot be safely automated

Installer fallback sources are configured in `config/install-sources.json`. The
current MVP includes verified official sources plus selected mirrors for Node.js
and Git for Windows.

## MVP Workflow

The desktop app currently has five tabs:

- Environment: pre-install prerequisite checks and one-click environment installation/preparation.
- Install Tools: preinstall dialog, official download/install execution, and installed/missing status for Codex App, Codex CLI, Claude Code CLI, Cursor Desktop, and CC Switch Desktop.
- Provider Test: local OpenAI-compatible Base URL / API Key test.
- CC Switch: generate a local profile JSON and deep link from the tested provider settings.
- License: activate and refresh a license against your own backend.

## License Backend

The backend is a minimal license server for your own software authorization.
It is not a cracking keygen and should not be used for third-party software.

The GUI performs license validation before showing the main setup tabs. A valid
license code is activated against the current machine ID and then refreshed on
startup. If the server is temporarily unavailable, a previously validated local
license can use the built-in offline grace period. Test mode bypasses this gate;
developers can also set `CODEMATE_SKIP_LICENSE_GATE=1` locally.

Server deployment docs:

- [License server deploy guide](docs/license-server-deploy.md)
- Admin page: `http://server-ip:8086/admin` when deployed with `HOST_PORT=8086`
- First admin visit creates the administrator username and password.
- Client license server URL: `http://server-ip:8086`

```powershell
cd .\backend
copy .env.example .env
npm install
npm start
```

Create a license:

```powershell
$headers = @{ Authorization = "Bearer change-me-admin-token" }
$body = @{ plan = "pro"; maxActivations = 1 } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8787/api/licenses/create" -Headers $headers -ContentType "application/json" -Body $body
```

Webhook for automated delivery services:

```text
POST /api/orders/webhook
```

The webhook is idempotent by `orderId`; repeated calls for the same order return
the same license code instead of creating duplicates.
