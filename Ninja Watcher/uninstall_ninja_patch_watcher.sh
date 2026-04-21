#!/bin/bash
# =============================================================================
# uninstall_ninja_patch_watcher.sh
#
# Completely removes the ninja_patch_watcher daemon, agent, and all
# associated files. Safe to run multiple times — gracefully handles
# missing files.
#
# Deploy via Intune or NinjaOne as a Shell Script:
#   - Run as: root
#   - Run as logged-in user: No
#   - Max retries: 3
# =============================================================================

DAEMON_LABEL="ninja.patch.watcher"
AGENT_LABEL="ninja.patch.watcher.agent"
DAEMON_SCRIPT="/usr/local/bin/ninja_patch_watcher.sh"
AGENT_SCRIPT="/usr/local/bin/ninja_patch_watcher_agent.sh"
DAEMON_PLIST="/Library/LaunchDaemons/ninja.patch.watcher.plist"
AGENT_PLIST="/Library/LaunchAgents/ninja.patch.watcher.agent.plist"
NEWSYSLOG_CONF="/etc/newsyslog.d/ninja_patch_watcher.conf"
DAEMON_LOG="/var/log/ninja_patch_watcher.log"
LAUNCHD_LOG="/var/log/ninja_patch_watcher_launchd.log"
AGENT_LOG="/tmp/ninja_patch_watcher_agent.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Starting ninja_patch_watcher uninstall"

# ---------------------------------------------------------------------------
# 1. Stop and unload the LaunchDaemon
# ---------------------------------------------------------------------------
if launchctl list 2>/dev/null | grep -q "$DAEMON_LABEL"; then
    log "Stopping daemon: $DAEMON_LABEL"
    launchctl bootout system/"$DAEMON_LABEL" 2>/dev/null && \
        log "Daemon stopped" || log "WARNING: Could not stop daemon"
else
    log "Daemon not running — skipping bootout"
fi

# ---------------------------------------------------------------------------
# 2. Stop and unload the LaunchAgent for all logged-in users
# ---------------------------------------------------------------------------
CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null)
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
    CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
    if launchctl asuser "$CONSOLE_UID" launchctl list 2>/dev/null | grep -q "$AGENT_LABEL"; then
        log "Stopping agent for $CONSOLE_USER (uid $CONSOLE_UID)"
        launchctl asuser "$CONSOLE_UID" launchctl bootout "gui/${CONSOLE_UID}/${AGENT_LABEL}" 2>/dev/null && \
            log "Agent stopped" || log "WARNING: Could not stop agent"
    else
        log "Agent not running for $CONSOLE_USER — skipping bootout"
    fi
else
    log "No logged-in user — skipping agent bootout"
fi

# ---------------------------------------------------------------------------
# 3. Kill any lingering processes
# ---------------------------------------------------------------------------
if pgrep -f "ninja_patch_watcher" > /dev/null 2>&1; then
    log "Killing lingering ninja_patch_watcher processes"
    pkill -f "ninja_patch_watcher" 2>/dev/null || true
fi

if pgrep -f "Dialog.app" > /dev/null 2>&1; then
    log "Killing any active swiftDialog instances launched by watcher"
    pkill -f "Dialog.app/Contents/MacOS/Dialog" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. Remove installed files
# ---------------------------------------------------------------------------
for file in \
    "$DAEMON_PLIST" \
    "$AGENT_PLIST" \
    "$DAEMON_SCRIPT" \
    "$AGENT_SCRIPT" \
    "$NEWSYSLOG_CONF"
do
    if [[ -f "$file" ]]; then
        rm -f "$file"
        log "Removed: $file"
    else
        log "Not found (skipping): $file"
    fi
done

# ---------------------------------------------------------------------------
# 5. Remove log files
# ---------------------------------------------------------------------------
for logfile in \
    "$DAEMON_LOG" \
    "${DAEMON_LOG}.0.bz2" \
    "${DAEMON_LOG}.1.bz2" \
    "${DAEMON_LOG}.2.bz2" \
    "${DAEMON_LOG}.3.bz2" \
    "${DAEMON_LOG}.4.bz2" \
    "$LAUNCHD_LOG" \
    "${LAUNCHD_LOG}.0.bz2" \
    "${LAUNCHD_LOG}.1.bz2" \
    "${LAUNCHD_LOG}.2.bz2" \
    "${LAUNCHD_LOG}.3.bz2" \
    "${LAUNCHD_LOG}.4.bz2" \
    "$AGENT_LOG"
do
    if [[ -f "$logfile" ]]; then
        rm -f "$logfile"
        log "Removed log: $logfile"
    fi
done

# ---------------------------------------------------------------------------
# 6. Remove temp files
# ---------------------------------------------------------------------------
for tmpfile in \
    "/tmp/ninja_patch_ui.json" \
    "/tmp/ninja_patch_dialog.cmd" \
    "/tmp/ninja_orbit_apply_snapshot.json" \
    "/tmp/ninja_inventory_snapshot.json" \
    "/tmp/ninja_patch_offsets"
do
    if [[ -e "$tmpfile" ]]; then
        rm -rf "$tmpfile"
        log "Removed temp: $tmpfile"
    fi
done

# ---------------------------------------------------------------------------
# 7. Verify everything is gone
# ---------------------------------------------------------------------------
log "Verifying removal..."

FAILED=0

[[ -f "$DAEMON_PLIST" ]]  && log "ERROR: $DAEMON_PLIST still exists"  && FAILED=1
[[ -f "$AGENT_PLIST" ]]   && log "ERROR: $AGENT_PLIST still exists"   && FAILED=1
[[ -f "$DAEMON_SCRIPT" ]] && log "ERROR: $DAEMON_SCRIPT still exists" && FAILED=1
[[ -f "$AGENT_SCRIPT" ]]  && log "ERROR: $AGENT_SCRIPT still exists"  && FAILED=1

if launchctl list 2>/dev/null | grep -q "$DAEMON_LABEL"; then
    log "ERROR: Daemon $DAEMON_LABEL still registered"
    FAILED=1
fi

if (( FAILED == 0 )); then
    log "Uninstall complete — all components removed successfully"
else
    log "Uninstall completed with errors — review above"
    exit 1
fi

exit 0
