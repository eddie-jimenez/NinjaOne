# Ninja Watcher <img width="50" height="36" alt="image" src="https://github.com/user-attachments/assets/f7daa26e-71c9-4413-a62a-98a05d0e67d7" />




<img width="1030" height="281" alt="image" src="https://github.com/user-attachments/assets/0f8daad1-5497-4090-81f8-4a0845381b3e" />





https://github.com/user-attachments/assets/bdf5d005-5643-4ea0-a099-51457626030c







A macOS background service that enhances the NinjaOne RMM patch management experience by intercepting third-party software update events and providing users with a friendly, informative progress dialog — then automatically relaunching the updated application when the install is complete.

---

## The Problem

NinjaOne's built-in patch dialog (`NJDialog`) prompts users to install updates but provides no feedback after the user clicks "Install Now." The app closes, the update runs silently, and the user is left wondering what happened. There is no progress indicator, no completion notification, and no automatic relaunch.

---

## The Solution

This tool runs as a persistent background service and:

1. **Watches** for NinjaOne's NJDialog to appear
2. **Waits** for the user to click "Install Now" (ignores "Remind me later" and timeouts)
3. **Shows** a branded swiftDialog progress window immediately — with the real app name and native icon
4. **Monitors** the install by watching NinjaOne's own output files for completion
5. **Waits** for any app updater process to finish before showing the completion state
6. **Shows** a standalone completion dialog with version numbers once the updater is done
7. **Relaunches** the updated application automatically as the logged-in user
8. **Closes** the dialog once the app is visible on screen

---

## Architecture

Ninja Watcher uses a **daemon + agent** split — this is required by macOS, not a design choice.

### Why Two Components?

LaunchDaemons run in the `System` session type (`LimitLoadToSessionType = System`). macOS unconditionally kills any GUI process (including swiftDialog) spawned from a System session daemon — regardless of `launchctl asuser`, `sudo -u`, `SessionCreate`, or any plist key. This is an intentional macOS security boundary with no workaround.

The correct macOS architecture for system daemons that need to display UI is to use a companion LaunchAgent running in the user's `Aqua` session, which has full GUI access.

### Components

| Component | Type | Runs As | Responsibility |
|---|---|---|---|
| `ninja_patch_watcher.sh` | LaunchDaemon | root | Watches NJDialog logs, handles all Ninja/Orbit logic, writes UI instructions to `/tmp/ninja_patch_ui.json` |
| `ninja_patch_watcher_agent.sh` | LaunchAgent | logged-in user | Polls the instruction file, launches swiftDialog, waits for updater processes to finish, relaunches the app |

### Instruction File Format

The daemon writes a single JSON line to `/tmp/ninja_patch_ui.json`. The agent polls this file every 2 seconds and reacts to the `action` field:

```json
{"action":"progress","app_name":"Firefox","app_icon":"/Applications/Firefox.app/Contents/Resources/firefox.icns","app_path":"/Applications/Firefox.app","ts":"1776370787"}
{"action":"success","app_name":"Firefox","app_icon":"...","app_path":"/Applications/Firefox.app","new_version":"149.0.2","prev_version":"","ts":"1776370812"}
{"action":"failure","app_name":"Firefox","error":"Installation failed","ts":"..."}
{"action":"timeout","app_name":"Firefox","ts":"..."}
{"action":"clear"}
```

---

## Requirements

| Requirement | Details |
|---|---|
| macOS | 12 Monterey or later |
| swiftDialog | 2.5.2 or later — [Download](https://github.com/swiftDialog/swiftDialog/releases) |
| NinjaOne RMM Agent | Must be installed at `/Applications/NinjaRMMAgent` |
| NinjaOne Policy | Update Notifications must be set to **"Notify user then close software and update"** |
| Deployment | Run as **root** via Intune or NinjaOne Shell Script |
| Dependencies | None — uses only built-in macOS tools |

---

## How It Works

### NinjaOne Patch Flow

When NinjaOne detects a third-party app that needs updating and the app is currently open, it:

1. Runs `NinjaOrbit scan` to identify available patches
2. Runs `NinjaOrbit apply` to attempt installation
3. Gets error code `21 — Application running` because the app is open
4. Launches `NJDialog` to prompt the user

NJDialog writes a log file to:
```
/Applications/NinjaRMMAgent/programdata/logs/njdialog/NinjaRMMNJDialog_<timestamp>.log
```

The daemon handles both patterns (new log file per session or appended sessions) using byte-offset tracking.

### Decision Detection

The daemon reads only newly appended content in NJDialog log files. It looks for one of three outcomes:

| Log Entry | Meaning | Action |
|---|---|---|
| `Alert Dialog User Clicked Yes` | User clicked Install Now | **Show progress dialog, monitor install** |
| `Alert Dialog User Clicked No` | User clicked Remind Me Later | Do nothing |
| `Alert Dialog timeout` | Dialog auto-closed | Do nothing |

### App Name and Icon Detection

At the moment `Showing Alert Dialog` is detected, the daemon immediately snapshots two NinjaOne files:

**`Orbit-apply-output.json`** — Written by NinjaOrbit after every patch attempt. Contains the Ninja patch title (e.g. `ChromeEnterprise`, `ZoomWorkplace`, `VisualStudioCode`) and version.

**`softwareInventory.json`** — Written by the NinjaOne agent. Contains every installed app with its real display name, exact `.app` path, and installed version.

The daemon matches a Ninja title to a real app by searching the inventory's location paths. This approach is fully dynamic — no hardcoded app lists — and works for any app Ninja adds to its catalog in the future.

### Install Completion Detection

After the user clicks Install Now, the daemon polls `Orbit-apply-output.json` for a change in its `monTime` field. When `monTime` changes, NinjaOrbit has written a new result — the patch is complete.

A 5-minute timeout is enforced. If no completion is detected, the user sees an "Update Status Unknown" dialog.

### Updater Wait Logic

Many apps (Firefox, Chrome, etc.) run a privileged helper process after Orbit reports success to perform the final install steps. This helper kills any GUI process running in the user session while it's active.

The agent waits for all processes referencing the app's `.app` path to exit before launching the completion dialog. This is fully generic — it works for any app's updater without hardcoding process names.

### Dialog Lifecycle

```
[Showing Alert Dialog detected]
        ↓ daemon snapshots both Ninja files
[User clicks Install Now]
        ↓ daemon writes progress instruction
        ↓ agent launches progress dialog with real app name + native icon
[Orbit-apply-output.json monTime changes]
        ↓ daemon writes success instruction
        ↓ agent waits for any app updater processes to exit
        ↓ agent kills stale progress dialog
        ↓ agent launches fresh standalone completion dialog
[8 second grace period]
        ↓ agent relaunches app as logged-in user
[App process detected]
        ↓ dialog remains open for user to dismiss
```

### App Relaunch

Once completion is confirmed and the updater has exited, the app is relaunched using `open -a` running in the logged-in user's session, so the app opens with their preferences intact.

---

## File Structure

```
/usr/local/bin/ninja_patch_watcher.sh               — Daemon script (logic only, no UI)
/usr/local/bin/ninja_patch_watcher_agent.sh         — Agent script (UI and relaunch)
/Library/LaunchDaemons/ninja.patch.watcher.plist    — LaunchDaemon plist
/Library/LaunchAgents/ninja.patch.watcher.agent.plist — LaunchAgent plist
/etc/newsyslog.d/ninja_patch_watcher.conf           — Log rotation config
/var/log/ninja_patch_watcher.log                    — Daemon activity log
/var/log/ninja_patch_watcher_launchd.log            — LaunchDaemon stdout/stderr
/tmp/ninja_patch_watcher_agent.log                  — Agent activity log
```

### NinjaOne files read (never modified)
```
/Applications/NinjaRMMAgent/programdata/jsonoutput/Orbit-apply-output.json
/Applications/NinjaRMMAgent/programdata/jsonoutput/softwareInventory.json
/Applications/NinjaRMMAgent/programdata/logs/njdialog/NinjaRMMNJDialog_*.log
```

### Temporary files (auto-cleaned on restart)
```
/tmp/ninja_patch_offsets/             — Per-file byte offset tracking
/tmp/ninja_orbit_apply_snapshot.json  — Orbit output snapshot at trigger time
/tmp/ninja_inventory_snapshot.json    — Inventory snapshot at trigger time
/tmp/ninja_patch_dialog.cmd           — swiftDialog live command file
/tmp/ninja_patch_ui.json              — Daemon → agent instruction file
```

---

## Deployment

### Prerequisites

Before deploying this script, ensure **swiftDialog is already installed** on target devices:

```bash
# Quick swiftDialog install (run as root)
LATEST=$(curl -sL https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest \
    | grep "browser_download_url.*pkg" | cut -d '"' -f 4 | head -1)
curl -sL "$LATEST" -o /tmp/swiftDialog.pkg
installer -pkg /tmp/swiftDialog.pkg -target /
```

### Script Configuration (Intune or NinjaOne)

| Setting | Value |
|---|---|
| Script | Upload `deploy_ninja_patch_watcher.sh` |
| Run script as signed-in user / Run as | **No / System** |
| Hide script notifications | **Yes** |
| Script frequency | **Not configured** (run once) |
| Max retries | 3 |

### What the Deployment Script Does

The `deploy_ninja_patch_watcher.sh` script runs as root and:

1. Verifies swiftDialog and NinjaRMM agent are present (exits with error if not)
2. Writes `ninja_patch_watcher.sh` to `/usr/local/bin/` (base64-encoded inline — no external download)
3. Writes `ninja_patch_watcher_agent.sh` to `/usr/local/bin/`
4. Writes the LaunchDaemon plist to `/Library/LaunchDaemons/` (without `UserName` key — required to avoid `LimitLoadToSessionType=System`)
5. Writes the LaunchAgent plist to `/Library/LaunchAgents/`
6. Configures `newsyslog` log rotation
7. Loads the LaunchDaemon via `launchctl bootstrap system`
8. Bootstraps the LaunchAgent into the current logged-in user's GUI session via `launchctl asuser`
9. Verifies both loaded successfully

### Re-deployment / Updates

The deployment script is safe to re-run. It unloads existing components, overwrites scripts with the new versions, and reloads.

---

## Uninstalling

Deploy `uninstall_ninja_patch_watcher.sh` via Intune or NinjaOne.

### What the Uninstall Script Removes

| Item | Path |
|---|---|
| Daemon script | `/usr/local/bin/ninja_patch_watcher.sh` |
| Agent script | `/usr/local/bin/ninja_patch_watcher_agent.sh` |
| LaunchDaemon plist | `/Library/LaunchDaemons/ninja.patch.watcher.plist` |
| LaunchAgent plist | `/Library/LaunchAgents/ninja.patch.watcher.agent.plist` |
| Log rotation config | `/etc/newsyslog.d/ninja_patch_watcher.conf` |
| All logs | `/var/log/ninja_patch_watcher*.log` + archives |
| Temp files | `/tmp/ninja_patch_offsets/`, `/tmp/ninja_patch_ui.json`, snapshots |

---

## Verifying Deployment

```bash
# Check both services are running
sudo launchctl list | grep ninja.patch.watcher
launchctl asuser $(id -u $USER) launchctl list | grep ninja.patch.watcher.agent

# Watch live logs
tail -f /var/log/ninja_patch_watcher.log
tail -f /tmp/ninja_patch_watcher_agent.log
```

Expected daemon log on startup:
```
[2026-04-16 17:58:37] ninja_patch_watcher v4.6 started (PID 94416)
[2026-04-16 17:58:37] Seeded: .../NinjaRMMNJDialog_*.log at offset XXXXX
[2026-04-16 17:58:37] Watching for NJDialog activity...
```

Expected agent log on startup:
```
[2026-04-16 17:58:37] ninja_patch_watcher_agent v4.6 started (PID 94512)
```

Expected logs during a patch event:
```
[2026-04-16 17:59:57] NJDialog detected: ...NinjaRMMNJDialog_*.log
[2026-04-16 17:59:57] Orbit apply snapshot taken (monTime: 1776376796)
[2026-04-16 17:59:57] === NJDialog appeared — waiting for user decision ===
[2026-04-16 18:00:00] User decision: yes
[2026-04-16 18:00:00] === User clicked Install Now — starting patch handler ===
[2026-04-16 18:00:00] Inventory match: 'Firefox' @ /Applications/Firefox.app
[2026-04-16 18:00:00] UI instruction: action=progress app=Firefox
[2026-04-16 18:00:24] Orbit apply output updated (monTime: 1776376824)
[2026-04-16 18:00:24] Patch status: success
[2026-04-16 18:00:24] App: Firefox | version: unknown → 149.0.2
[2026-04-16 18:00:24] UI instruction: action=success app=Firefox
[2026-04-16 18:00:24] === Patch event complete ===
```

And in the agent log:
```
[2026-04-16 18:00:25] Received instruction: action=success ts=1776376824
[2026-04-16 18:00:25] Waiting for updater processes in /Applications/Firefox.app to exit...
[2026-04-16 18:00:26] Completion dialog launched (PID 5590) for: Firefox ( → 149.0.2)
[2026-04-16 18:00:34] Relaunching: /Applications/Firefox.app
[2026-04-16 18:00:39] Relaunch complete: Firefox
```

---

## Troubleshooting

### Dialog doesn't appear after clicking Install Now

Check the daemon log:
```bash
tail -f /var/log/ninja_patch_watcher.log
```

Check the agent is running:
```bash
launchctl asuser $(id -u $USER) launchctl list | grep ninja.patch.watcher.agent
```

If the agent shows exit code `78`, check that `/tmp/ninja_patch_watcher_agent.log` is writable by the user. The agent plist must use `/tmp/` for log paths, not `/var/log/`.

### App doesn't relaunch after update

The agent logs the relaunch attempt. If you see `Relaunch complete` in the agent log but the app doesn't appear, the app may still be finalizing its update. The `sleep 8` before relaunch is intentional — if needed for a specific slow app, it can be increased in the agent script.

### LaunchAgent fails to bootstrap (Error 5)

Error 5 (`Input/output error`) on `launchctl bootstrap` means the log path in the plist is not writable by the user. Ensure `StandardOutPath` and `StandardErrorPath` in the LaunchAgent plist point to `/tmp/`, not `/var/log/`.

### Manually stop/start the services

```bash
# Daemon
sudo launchctl bootout system/ninja.patch.watcher
sudo launchctl bootstrap system /Library/LaunchDaemons/ninja.patch.watcher.plist

# Agent (replace 501 with actual UID)
launchctl bootout gui/501/ninja.patch.watcher.agent
launchctl bootstrap gui/501 /Library/LaunchAgents/ninja.patch.watcher.agent.plist
```

---

## NinjaOne Policy Requirements

In the NinjaOne console, the patch policy for macOS devices must have **Update Notifications** set to:

> ✅ **Notify user then close software and update**

With the recommended settings:
- Period: **5 Minutes**
- Force update after: **3 prompts**

---

## Compatibility

| Component | Tested Version |
|---|---|
| macOS | Sequoia 15.x |
| swiftDialog | 2.5.2.4777 |
| NinjaOne macOS Agent | 7.x |
| NinjaOrbit (app patching) | 12.0.5400 |

---

## Version History

| Version | Changes |
|---|---|
| 4.6 | Added 8-second grace period before app relaunch to allow install to fully settle |
| 4.5 | Fixed deploy script structure using base64-encoded scripts to eliminate heredoc nesting issues; removed all decimal `sleep` calls incompatible with macOS `sleep` |
| 4.4 | Updater wait logic made fully generic — waits for any process referencing the app path to exit, covering all apps (Firefox, Chrome, TeamViewer, etc.) |
| 4.3 | Added wait for `org.mozilla.updater` before showing completion dialog (superseded by 4.4) |
| 4.2 | Agent `DIALOG_BIN` changed to real binary at `/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog` to avoid double-wrap kill from wrapper script |
| 4.1 | Fixed agent log path from `/var/log/` to `/tmp/` — user-context agent cannot write to `/var/log/` |
| 4.0 | **Architecture change**: Split into daemon (root, logic) + agent (user, UI). LaunchDaemons run in `System` session type and cannot spawn persistent GUI processes — this is a macOS restriction with no plist workaround. Agent runs as logged-in user in `Aqua` session with full GUI access. LaunchDaemon plist must omit `UserName` key to avoid being forced into `LimitLoadToSessionType=System` |
| 3.x | Single-script attempts — all failed due to `LimitLoadToSessionType=System` killing swiftDialog |
| 3.3 | Added bash-level fallbacks for version/path extraction when JXA fails |
| 3.2 | Added filesystem fallback when `softwareInventory.json` is missing |
| 3.1 | Fixed monTime extraction for pretty-printed JSON; added early app name display |
| 3.0 | Complete rewrite using `Orbit-apply-output.json` + `softwareInventory.json` as authoritative sources |
| 2.x | Various attempts using patch records JSON and process detection |
| 1.x | Initial implementation using NJDialog log file and NinjaOrbit log detection |
