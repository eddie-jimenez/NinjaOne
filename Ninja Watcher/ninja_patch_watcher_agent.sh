#!/bin/bash
# =============================================================================
# ninja_patch_watcher_agent.sh — User LaunchAgent
# Version: 4.12
# Fix: Agent log path changed from /var/log/ to /tmp/ so the user-context
#      agent process has write permission.
#
# Runs as the logged-in user. Polls /tmp/ninja_patch_ui.json for instructions
# written by the companion daemon (ninja_patch_watcher.sh) and handles all
# swiftDialog UI and app relaunch — things that require a user GUI session.
# =============================================================================

DIALOG_BIN="/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog"
UI_INSTRUCTION_FILE="/tmp/ninja_patch_ui.json"
DIALOG_CMD_FILE="/tmp/ninja_patch_dialog.cmd"
AGENT_LOG="/tmp/ninja_patch_watcher_agent.log"
POLL_INTERVAL=1
DIALOG_MAJOR_VERSION=2  # detected at startup

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" >> "$AGENT_LOG"
}

dialog_cmd() {
    echo "$*" >> "$DIALOG_CMD_FILE"
}

# ---------------------------------------------------------------------------
# Parse a field from the flat JSON instruction file
# Usage: parse_field "fieldname"
# ---------------------------------------------------------------------------
parse_field() {
    local field="$1"
    grep -o "\"${field}\":\"[^\"]*\"" "$UI_INSTRUCTION_FILE" 2>/dev/null | \
        head -1 | sed "s/\"${field}\":\"//;s/\"$//"
}

# ---------------------------------------------------------------------------
# Show progress dialog — version-aware for swiftDialog 2.x and 3.x
# swiftDialog 3.0 removed --button1disabled and requires bare flags at end
# ---------------------------------------------------------------------------
show_progress_dialog() {
    local app_name="$1"
    local app_icon="$2"

    rm -f "$DIALOG_CMD_FILE"
    touch "$DIALOG_CMD_FILE"
    chmod 666 "$DIALOG_CMD_FILE"

    local icon_arg="SF=arrow.down.circle.fill,colour=blue"
    [[ -n "$app_icon" && -f "$app_icon" ]] && icon_arg="$app_icon"

    if [[ "$DIALOG_MAJOR_VERSION" -ge 3 ]]; then
        # swiftDialog 3.x: no --button1disabled, bare flags must be at end
        "$DIALOG_BIN" \
            --title "🥷 Software Update In Progress" \
            --titlefont "size=17" \
            --message "**${app_name}** is being updated by your IT team.\n\nThe application will reopen automatically once the update is complete." \
            --messagefont "size=14" \
            --icon "$icon_arg" \
            --progress \
            --progresstext "Installing update…" \
            --button1text "Please Wait" \
            --commandfile "$DIALOG_CMD_FILE" \
            --appearance light \
            --windowbuttons close,min,max \
            --position centre \
            --width 520 \
            --height 260 \
            --moveable --ontop --hidetimerbar \
            &>/dev/null &
    else
        # swiftDialog 2.x: --button1disabled supported
        "$DIALOG_BIN" \
            --title "🥷 Software Update In Progress" \
            --titlefont "size=17" \
            --message "**${app_name}** is being updated by your IT team.\n\nThe application will reopen automatically once the update is complete." \
            --messagefont "size=14" \
            --icon "$icon_arg" \
            --progress \
            --progresstext "Installing update…" \
            --button1text "Please Wait" \
            --button1disabled \
            --commandfile "$DIALOG_CMD_FILE" \
            --appearance light \
            --windowbuttons close,min,max \
            --position centre \
            --moveable \
            --ontop \
            --width 520 \
            --height 260 \
            --hidetimerbar \
            &>/dev/null &
    fi

    log "swiftDialog $DIALOG_MAJOR_VERSION.x progress launched (PID $!) for: $app_name"
}

# ---------------------------------------------------------------------------
# Update running progress dialog with final app info
# ---------------------------------------------------------------------------
update_progress_app() {
    local app_name="$1"
    local app_icon="$2"
    dialog_cmd "title: 🥷 Software Update In Progress"
    [[ -n "$app_icon" && -f "$app_icon" ]] && dialog_cmd "icon: $app_icon"
    dialog_cmd "message: **${app_name}** is being updated by your IT team.\n\nThe application will reopen automatically once the update is complete."
}

# ---------------------------------------------------------------------------
# Show success — kill dead progress dialog, launch fresh standalone dialog
# ---------------------------------------------------------------------------
show_completion_dialog() {
    local app_name="$1"
    local prev_version="$2"
    local new_version="$3"

    local version_line=""
    if [[ -n "$new_version" && -n "$prev_version" && "$new_version" != "$prev_version" ]]; then
        version_line="\n\nUpdated from **${prev_version}** to **${new_version}**"
    elif [[ -n "$new_version" ]]; then
        version_line="\n\nNew version: **${new_version}**"
    fi

    # Kill any existing dialog and launch a fresh standalone success dialog
    pkill -f "Dialog.app" 2>/dev/null || true
    sleep 1
    rm -f "$DIALOG_CMD_FILE"

    "$DIALOG_BIN" \
        --title "🥷 Update Complete" \
        --titlefont "size=17" \
        --message "**${app_name}** has been updated successfully.${version_line}\n\nThe application is reopening now." \
        --messagefont "size=14" \
        --icon "SF=checkmark.circle.fill,colour=green" \
        --button1text "OK" \
        --appearance light \
        --windowbuttons close,min,max \
        --position centre \
        --width 520 \
        --height 220 \
        --moveable --ontop \
        &>/dev/null &

    log "Completion dialog launched (PID $!) for: $app_name ($prev_version → $new_version)"
}

# ---------------------------------------------------------------------------
# Show failure — kill dead progress dialog, launch fresh standalone dialog
# ---------------------------------------------------------------------------
show_failure_dialog() {
    local app_name="$1"
    local error_msg="$2"

    local error_line=""
    [[ -n "$error_msg" ]] && error_line="\n\nError: ${error_msg}"

    # Kill any existing dialog and launch a fresh standalone failure dialog
    pkill -f "Dialog.app" 2>/dev/null || true
    sleep 1
    rm -f "$DIALOG_CMD_FILE"

    "$DIALOG_BIN" \
        --title "🥷 Update Failed" \
        --titlefont "size=17" \
        --message "The update for **${app_name}** did not complete successfully.${error_line}\n\nPlease contact your IT team if this issue persists." \
        --messagefont "size=14" \
        --icon "SF=exclamationmark.triangle.fill,colour=red" \
        --button1text "OK" \
        --appearance light \
        --windowbuttons close,min,max \
        --position centre \
        --width 520 \
        --height 220 \
        --moveable --ontop \
        &>/dev/null &

    log "Failure dialog launched (PID $!) for: $app_name"
}

# ---------------------------------------------------------------------------
# Show timeout dialog (standalone — progress dialog already dismissed)
# ---------------------------------------------------------------------------
show_timeout_dialog() {
    local app_name="$1"

    dialog_cmd "quit:"
    sleep 1
    rm -f "$DIALOG_CMD_FILE"

    "$DIALOG_BIN" \
        --title "🥷 Update Status Unknown" \
        --titlefont "size=17" \
        --message "The update for **${app_name}** may still be in progress.\n\nYou can reopen the application manually." \
        --messagefont "size=14" \
        --icon "SF=exclamationmark.triangle.fill,colour=yellow" \
        --button1text "OK" \
        --appearance light \
        --windowbuttons close,min,max \
        --position centre \
        --moveable \
        --ontop \
        --width 520 \
        --height 220 \
        &>/dev/null &

    log "Timeout dialog shown for: $app_name"
}

# ---------------------------------------------------------------------------
# Relaunch app as current user
# ---------------------------------------------------------------------------
relaunch_app() {
    local app_path="$1"
    [[ -z "$app_path" || ! -d "$app_path" ]] && log "No valid app path for relaunch" && return

    local app_bundle
    app_bundle=$(basename "$app_path" .app)
    log "Relaunching: $app_path"
    open -a "$app_path" &

    local waited=0
    while ! pgrep -f "$app_bundle" > /dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        (( waited > 30 )) && break
    done
    sleep 5
    log "Relaunch complete: $app_bundle"
}

# ---------------------------------------------------------------------------
# Main loop — polls UI instruction file and reacts
# ---------------------------------------------------------------------------
main() {
    log "ninja_patch_watcher_agent v4.12 started (PID $$)"

    if [[ ! -x "$DIALOG_BIN" ]]; then
        log "ERROR: swiftDialog not found at $DIALOG_BIN — exiting."
        exit 1
    fi

    # Detect swiftDialog major version — 3.x removed --button1disabled
    # and requires bare flags at end of command when calling Dialog directly
    local detected_version
    detected_version=$("$DIALOG_BIN" --version 2>/dev/null | head -1 | cut -d. -f1)
    if [[ "$detected_version" =~ ^[0-9]+$ ]]; then
        DIALOG_MAJOR_VERSION="$detected_version"
    fi
    log "swiftDialog version: $("$DIALOG_BIN" --version 2>/dev/null | head -1) (major: $DIALOG_MAJOR_VERSION)"

    local last_ts=""
    local dialog_running=false

    while true; do
        sleep "$POLL_INTERVAL"

        [[ ! -f "$UI_INSTRUCTION_FILE" ]] && continue

        local action ts
        action=$(parse_field "action")
        ts=$(parse_field "ts")

        # Skip if we've already processed this instruction
        [[ "$ts" == "$last_ts" ]] && continue
        [[ -z "$action" || "$action" == "clear" ]] && continue

        last_ts="$ts"
        log "Received instruction: action=$action ts=$ts"

        local app_name app_icon app_path new_version prev_version error_msg
        app_name=$(parse_field "app_name")
        app_icon=$(parse_field "app_icon")
        app_path=$(parse_field "app_path")
        new_version=$(parse_field "new_version")
        prev_version=$(parse_field "prev_version")
        error_msg=$(parse_field "error")

        [[ -z "$app_name" ]] && app_name="Software Update"

        case "$action" in
            progress)
                # Kill any existing dialog first
                pkill -f "$DIALOG_BIN" 2>/dev/null || true
                sleep 1
                show_progress_dialog "$app_name" "$app_icon"
                dialog_running=true
                # Store current ts so the monitor knows when to stop
                local progress_ts="$ts"
                local _app_name="$app_name"
                local _app_icon="$app_icon"
                # Background monitor — if dialog gets killed, relaunch it
                # Runs until a new instruction (success/failure) replaces the progress ts
                {
                    local monitor_wait=0
                    while [[ $monitor_wait -lt 360 ]]; do
                        sleep 5
                        monitor_wait=$((monitor_wait + 5))
                        # Stop if instruction file has moved on from progress
                        local cur_ts cur_action
                        cur_ts=$(grep -o '"ts":"[^"]*"' "$UI_INSTRUCTION_FILE" 2>/dev/null | sed 's/"ts":"//;s/"//')
                        cur_action=$(grep -o '"action":"[^"]*"' "$UI_INSTRUCTION_FILE" 2>/dev/null | sed 's/"action":"//;s/"//')
                        [[ "$cur_ts" != "$progress_ts" ]] && break
                        [[ "$cur_action" != "progress" ]] && break
                        # Relaunch if dialog is not running
                        if ! pgrep -f "Dialog.app" > /dev/null 2>&1; then
                            log "Progress dialog was killed — relaunching for: $_app_name"
                            show_progress_dialog "$_app_name" "$_app_icon"
                        fi
                    done
                } &
                ;;

            success)
                # Wait for any updater process referencing the app path to
                # exit before showing the completion dialog. App updaters
                # (Firefox, Chrome, etc.) kill GUI processes while running.
                if [[ -n "$app_path" ]]; then
                    local updater_wait=0
                    while ps aux 2>/dev/null | grep -v grep | grep -qF "${app_path}"; do
                        [[ $updater_wait -eq 0 ]] && log "Waiting for updater processes in $app_path to exit..."
                        sleep 2
                        updater_wait=$((updater_wait + 2))
                        (( updater_wait > 120 )) && log "Timed out waiting for updater" && break
                    done
                    [[ $updater_wait -gt 0 ]] && log "Updater exited after ${updater_wait}s" && sleep 2
                fi

                show_completion_dialog "$app_name" "$prev_version" "$new_version"
                sleep 8
                relaunch_app "$app_path"
                dialog_running=false
                rm -f "$DIALOG_CMD_FILE"
                ;;

            failure)
                if $dialog_running; then
                    update_progress_app "$app_name" "$app_icon"
                    sleep 1
                    show_failure_dialog "$app_name" "$error_msg"
                else
                    show_progress_dialog "$app_name" "$app_icon"
                    sleep 1
                    show_failure_dialog "$app_name" "$error_msg"
                fi
                dialog_running=false
                rm -f "$DIALOG_CMD_FILE"
                ;;

            timeout)
                show_timeout_dialog "$app_name"
                dialog_running=false
                ;;
        esac
    done
}

main "$@"
