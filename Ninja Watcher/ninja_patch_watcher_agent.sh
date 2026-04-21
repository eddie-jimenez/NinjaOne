#!/bin/bash
# =============================================================================
# ninja_patch_watcher_agent.sh — User LaunchAgent
# Version: 4.6
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
POLL_INTERVAL=2

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
# Show progress dialog — branded with app name and icon
# ---------------------------------------------------------------------------
show_progress_dialog() {
    local app_name="$1"
    local app_icon="$2"

    rm -f "$DIALOG_CMD_FILE"
    touch "$DIALOG_CMD_FILE"
    chmod 666 "$DIALOG_CMD_FILE"

    local icon_arg="SF=arrow.down.circle.fill,colour=blue"
    [[ -n "$app_icon" && -f "$app_icon" ]] && icon_arg="$app_icon"

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

    log "swiftDialog progress launched (PID $!) for: $app_name"
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
        --moveable \
        --ontop \
        --width 520 \
        --height 220 \
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
        --moveable \
        --ontop \
        --width 520 \
        --height 220 \
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
    log "ninja_patch_watcher_agent v4.6 started (PID $$)"

    if [[ ! -x "$DIALOG_BIN" ]]; then
        log "ERROR: swiftDialog not found at $DIALOG_BIN — exiting."
        exit 1
    fi

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
