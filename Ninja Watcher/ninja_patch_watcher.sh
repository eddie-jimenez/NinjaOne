#!/bin/bash
# =============================================================================
# ninja_patch_watcher.sh
# Watches for NinjaRMM NJDialog patch prompts. Only fires when the user
# explicitly clicks "Install Now" (Alert Dialog User Clicked Yes).
# Shows a swiftDialog progress UI and auto-relaunches the app when done.
#
# Requirements:
#   - swiftDialog 2.5.6+ installed at /usr/local/bin/dialog
#   - Run as root via LaunchDaemon
#   - sqlite3 (built into macOS — no Xcode or extras required)
#   - No other dependencies — pure bash throughout
#
# Data sources (all written by NinjaOne — no guesswork):
#   - ninjarmm_orbit_patching.db3  — approved patch catalog
#   - softwareInventory.json       — installed app name, path, version
#   - Orbit-apply-output.json      — patch status, new version, title
#
# Version: 3.21
# Fix: All swiftDialog launches now use `launchctl asuser <uid>` to run in
#      the logged-in user's GUI session. Previously dialogs were launched
#      directly from the root LaunchDaemon context, causing macOS to SIGKILL
#      them (Killed: 9) because they had no valid window server connection.
#      launchctl asuser is the correct macOS mechanism for displaying UI
#      from a system-level daemon without changing the daemon's own context.
# =============================================================================

DIALOG_BIN="/usr/local/bin/dialog"
NJDIALOG_LOG_DIR="/Applications/NinjaRMMAgent/programdata/logs/njdialog"
ORBIT_APPLY_OUTPUT="/Applications/NinjaRMMAgent/programdata/jsonoutput/Orbit-apply-output.json"
SOFTWARE_INVENTORY="/Applications/NinjaRMMAgent/programdata/jsonoutput/softwareInventory.json"
PATCH_POLICY_JSON="/Applications/NinjaRMMAgent/programdata/policy/ws.agent.patches.OSX.X86_64.json"
ORBIT_APPLY_SNAPSHOT="/tmp/ninja_orbit_apply_snapshot.json"
INVENTORY_SNAPSHOT="/tmp/ninja_inventory_snapshot.json"
DIALOG_CMD_FILE="/tmp/ninja_patch_dialog.cmd"
POLL_INTERVAL=3
INSTALL_TIMEOUT=300
WATCHER_LOG="/var/log/ninja_patch_watcher.log"

# ---------------------------------------------------------------------------
# Logging — file only, never stdout
# ---------------------------------------------------------------------------
log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" >> "$WATCHER_LOG"
}

# ---------------------------------------------------------------------------
# Get the currently logged-in console user and their UID.
# Sets globals: CONSOLE_USER, CONSOLE_UID
# ---------------------------------------------------------------------------
get_console_user() {
    CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null)
    if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" ]]; then
        CONSOLE_USER=""
        CONSOLE_UID=""
        return
    fi
    CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Launch swiftDialog in the user's GUI session using launchctl asuser.
# This is the correct way to display UI from a root LaunchDaemon — it
# connects to the user's window server without changing our process context.
# ---------------------------------------------------------------------------
dialog_as_user() {
    [[ -z "$CONSOLE_UID" ]] && log "No logged-in user — cannot show dialog" && return
    log "dialog_as_user: launching as $CONSOLE_USER (uid $CONSOLE_UID)"
    launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" "$DIALOG_BIN" "$@" &>/dev/null &
    local dialog_pid=$!
    log "dialog_as_user: PID $dialog_pid"
}

# ---------------------------------------------------------------------------
# Snapshot both Ninja output files at NJDialog trigger time.
# ---------------------------------------------------------------------------
snapshot_ninja_outputs() {
    if [[ -f "$ORBIT_APPLY_OUTPUT" ]]; then
        cp "$ORBIT_APPLY_OUTPUT" "$ORBIT_APPLY_SNAPSHOT"
        local mon
        mon=$(grep -o '"monTime" *: *[0-9]*' "$ORBIT_APPLY_SNAPSHOT" | grep -o '[0-9]*' | head -1)
        log "Orbit apply snapshot taken (monTime: ${mon:-unknown})"
    else
        rm -f "$ORBIT_APPLY_SNAPSHOT"
        log "Orbit apply output not found — no snapshot"
    fi
    if [[ -f "$SOFTWARE_INVENTORY" ]]; then
        cp "$SOFTWARE_INVENTORY" "$INVENTORY_SNAPSHOT"
        log "Software inventory snapshot taken"
    else
        rm -f "$INVENTORY_SNAPSHOT"
        log "Software inventory not found — no snapshot"
    fi
}

# ---------------------------------------------------------------------------
# Query the Ninja patch policy JSON file for productName and vendorName.
# Uses ws.agent.patches.OSX.X86_64.json — pretty-printed, always current,
# no sqlite3 required. Each product block looks like:
#   {
#       "productName": "Firefox",
#       "vendorName": "Mozilla",
#       ...
#   }
# We find the line containing our title's productName, then scan nearby
# lines for vendorName within the same product block.
# Sets globals: POLICY_PRODUCT_NAME, POLICY_VENDOR_NAME
# ---------------------------------------------------------------------------
lookup_policy_product() {
    local orbit_title="$1"
    POLICY_PRODUCT_NAME=""
    POLICY_VENDOR_NAME=""

    if [[ ! -f "$PATCH_POLICY_JSON" ]]; then
        log "Patch policy JSON not found — skipping policy lookup"
        return
    fi

    local title_lower
    title_lower=$(echo "$orbit_title" | tr '[:upper:]' '[:lower:]')

    # Find the line number of the productName match
    local match_line
    match_line=$(grep -in "\"productName\" *: *\"${orbit_title}\"" "$PATCH_POLICY_JSON" 2>/dev/null | head -1 | cut -d: -f1)

    if [[ -z "$match_line" ]]; then
        log "No policy match found for title: $orbit_title"
        return
    fi

    # Extract productName from the matched line
    POLICY_PRODUCT_NAME=$(sed -n "${match_line}p" "$PATCH_POLICY_JSON" | \
        grep -o '"productName" *: *"[^"]*"' | sed 's/"productName" *: *"//;s/"//')

    # vendorName appears within ~5 lines of productName in the same object
    # Search the surrounding lines for it
    local search_start=$(( match_line - 5 ))
    local search_end=$(( match_line + 5 ))
    [[ $search_start -lt 1 ]] && search_start=1

    POLICY_VENDOR_NAME=$(sed -n "${search_start},${search_end}p" "$PATCH_POLICY_JSON" | \
        grep -o '"vendorName" *: *"[^"]*"' | head -1 | sed 's/"vendorName" *: *"//;s/"//')

    log "Policy match: productName=$POLICY_PRODUCT_NAME vendorName=$POLICY_VENDOR_NAME"
}

# ---------------------------------------------------------------------------
# Inventory lookup — find app path by matching name field directly.
# softwareInventory.json: location is the line immediately before name.
# Sets globals: APP_NAME, APP_PATH, APP_PREV_VERSION
# ---------------------------------------------------------------------------
lookup_app_info() {
    local orbit_title="$1"
    local inventory_file="${2:-$SOFTWARE_INVENTORY}"

    APP_NAME="$orbit_title"
    APP_PATH=""
    APP_PREV_VERSION=""

    lookup_policy_product "$orbit_title"

    local match_name="${POLICY_PRODUCT_NAME:-$orbit_title}"

    if [[ -f "$inventory_file" ]]; then
        local name_line_num
        name_line_num=$(grep -n "\"name\" *: *\"${match_name}\"" "$inventory_file" 2>/dev/null | head -1 | cut -d: -f1)

        if [[ -n "$name_line_num" ]]; then
            local location_line_num=$(( name_line_num - 1 ))
            local location_line
            location_line=$(sed -n "${location_line_num}p" "$inventory_file" 2>/dev/null)
            local inv_path
            inv_path=$(echo "$location_line" | grep -o '"location" *: *"[^"]*"' | sed 's/"location" *: *"//;s/"//')

            if [[ -n "$inv_path" && -d "$inv_path" ]]; then
                APP_PATH="$inv_path"
                APP_NAME="$match_name"
                log "Inventory match: '$APP_NAME' @ $APP_PATH"

                if [[ -f "$INVENTORY_SNAPSHOT" ]]; then
                    local snap_name_line
                    snap_name_line=$(grep -n "\"name\" *: *\"${match_name}\"" "$INVENTORY_SNAPSHOT" 2>/dev/null | head -1 | cut -d: -f1)
                    if [[ -n "$snap_name_line" ]]; then
                        local version_line_num=$(( snap_name_line + 1 ))
                        APP_PREV_VERSION=$(sed -n "${version_line_num}p" "$INVENTORY_SNAPSHOT" 2>/dev/null | \
                            grep -o '"version" *: *"[^"]*"' | sed 's/"version" *: *"//;s/"//')
                    fi
                fi
            else
                log "Inventory name match found but location invalid: ${inv_path:-empty}"
            fi
        else
            log "No inventory match found for: $match_name"
        fi
    fi

    # Last resort: filesystem find
    if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
        local fs_keyword
        fs_keyword=$(echo "$match_name" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        log "Falling back to filesystem search for: $fs_keyword"
        APP_PATH=$(find /Applications -maxdepth 3 -iname "*.app" 2>/dev/null | while read -r app; do
            local bundle_lower
            bundle_lower=$(basename "$app" .app | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            if [[ "$bundle_lower" == *"$fs_keyword"* ]] || \
               [[ "$fs_keyword" == *"$bundle_lower"* && ${#bundle_lower} -gt 3 ]]; then
                echo "$app"
                break
            fi
        done | head -1)
        [[ -n "$APP_PATH" ]] && log "Filesystem match: $APP_PATH" || log "App not found anywhere for: $orbit_title"
    fi

    if [[ -n "$APP_PATH" && -d "$APP_PATH" && "$APP_NAME" == "$orbit_title" ]]; then
        local bundle_name
        bundle_name=$(defaults read "${APP_PATH}/Contents/Info" CFBundleName 2>/dev/null || \
                      defaults read "${APP_PATH}/Contents/Info" CFBundleDisplayName 2>/dev/null || true)
        [[ -n "$bundle_name" ]] && APP_NAME="$bundle_name"
    fi
}

# ---------------------------------------------------------------------------
# Wait for app-specific updater processes to exit after Orbit signals done.
# Watches for processes whose command line references the app install path.
# Only blocks if such a process is actually running — returns immediately otherwise.
# ---------------------------------------------------------------------------
wait_for_app_updater_to_exit() {
    local app_path="$1"
    local max_wait=120
    local waited=0

    if ! ps aux 2>/dev/null | grep -v grep | grep -qF "${app_path}/"; then
        log "No active updater process found for: $app_path — skipping wait"
        return
    fi

    log "Waiting for updater processes referencing $app_path to exit..."

    while (( waited < max_wait )); do
        if ! ps aux 2>/dev/null | grep -v grep | grep -qF "${app_path}/"; then
            log "App updater processes exited after ${waited}s"
            return
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log "Timed out waiting for updater ($app_path) after ${max_wait}s — proceeding"
}

# ---------------------------------------------------------------------------
# Read patch status from Orbit apply output.
# Ninja uses "success" for standard patches and "installed" for catalog patches.
# ---------------------------------------------------------------------------
get_patch_status() {
    local orbit_file="${1:-$ORBIT_APPLY_OUTPUT}"
    [[ ! -f "$orbit_file" ]] && echo "unknown" && return
    local status
    status=$(grep -o '"status" *: *"[^"]*"' "$orbit_file" 2>/dev/null | head -1 | sed 's/"status" *: *"//;s/"//')
    case "$status" in
        success|installed) echo "success" ;;
        failed)            echo "failed" ;;
        *)                 echo "unknown" ;;
    esac
}

# ---------------------------------------------------------------------------
# Get new version from Orbit apply output
# ---------------------------------------------------------------------------
get_new_version_from_orbit() {
    local orbit_file="${1:-$ORBIT_APPLY_OUTPUT}"
    [[ ! -f "$orbit_file" ]] && return
    grep -o '"version" *: *"[^"]*"' "$orbit_file" 2>/dev/null | head -1 | sed 's/"version" *: *"//;s/"//'
}

# ---------------------------------------------------------------------------
# Get error message from Orbit apply output
# ---------------------------------------------------------------------------
get_patch_error() {
    local orbit_file="${1:-$ORBIT_APPLY_OUTPUT}"
    [[ ! -f "$orbit_file" ]] && return
    grep -o '"message" *: *"[^"]*"' "$orbit_file" 2>/dev/null | head -1 | sed 's/"message" *: *"//;s/"//'
}

# ---------------------------------------------------------------------------
# Get app icon path from bundle
# ---------------------------------------------------------------------------
get_app_icon() {
    local app_path="$1"
    [[ -z "$app_path" || ! -d "$app_path" ]] && return

    local icon_name
    icon_name=$(defaults read "${app_path}/Contents/Info" CFBundleIconFile 2>/dev/null)
    icon_name="${icon_name%.icns}"
    [[ -z "$icon_name" ]] && return

    local icon_path="${app_path}/Contents/Resources/${icon_name}.icns"
    [[ ! -f "$icon_path" ]] && icon_path="${app_path}/Contents/Resources/${icon_name}"
    [[ -f "$icon_path" ]] && echo "$icon_path"
}

# ---------------------------------------------------------------------------
# Send a live command to swiftDialog via command file
# ---------------------------------------------------------------------------
dialog_cmd() {
    echo "$*" >> "$DIALOG_CMD_FILE"
}

# ---------------------------------------------------------------------------
# Show initial progress dialog (generic) — launched in user GUI session
# ---------------------------------------------------------------------------
show_progress_dialog() {
    rm -f "$DIALOG_CMD_FILE"
    touch "$DIALOG_CMD_FILE"
    chmod 666 "$DIALOG_CMD_FILE"

    dialog_as_user \
        --title "🥷 Software Update In Progress" \
        --titlefont "size=17" \
        --message "A software update is being installed by your IT team.\n\nThe application will reopen automatically once the update is complete." \
        --messagefont "size=14" \
        --icon "SF=arrow.down.circle.fill,colour=blue" \
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
        --hidetimerbar

    log "swiftDialog launched (generic)"
}

# ---------------------------------------------------------------------------
# Show progress dialog branded with app name and icon — in user GUI session
# ---------------------------------------------------------------------------
show_progress_dialog_with_app() {
    local app_name="$1"
    local app_icon="$2"
    rm -f "$DIALOG_CMD_FILE"
    touch "$DIALOG_CMD_FILE"
    chmod 666 "$DIALOG_CMD_FILE"

    local icon_arg="SF=arrow.down.circle.fill,colour=blue"
    [[ -n "$app_icon" && -f "$app_icon" ]] && icon_arg="$app_icon"

    dialog_as_user \
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
        --hidetimerbar

    log "swiftDialog launched (branded: $app_name)"
}

# ---------------------------------------------------------------------------
# Update running progress dialog with app name and icon
# ---------------------------------------------------------------------------
update_progress_dialog_with_app() {
    local app_name="$1"
    local app_icon="$2"

    dialog_cmd "title: 🥷 Software Update In Progress"
    if [[ -n "$app_icon" && -f "$app_icon" ]]; then
        dialog_cmd "icon: $app_icon"
    fi
    dialog_cmd "message: **${app_name}** is being updated by your IT team.\n\nThe application will reopen automatically once the update is complete."
}

# ---------------------------------------------------------------------------
# Transform dialog to success state
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

    dialog_cmd "title: 🥷 Update Complete"
    dialog_cmd "icon: SF=checkmark.circle.fill,colour=green"
    dialog_cmd "message: **${app_name}** has been updated successfully.${version_line}\n\nThe application is reopening now."
    dialog_cmd "progresstext: Update complete"
    dialog_cmd "progress: 100"
    dialog_cmd "button1text: OK"
    sleep 0.5
    dialog_cmd "button1: enable"

    log "Completion dialog shown for: $app_name ($prev_version → $new_version)"
}

# ---------------------------------------------------------------------------
# Transform dialog to failure state
# ---------------------------------------------------------------------------
show_failure_dialog() {
    local app_name="$1"
    local error_msg="$2"

    local error_line=""
    [[ -n "$error_msg" ]] && error_line="\n\nError: ${error_msg}"

    dialog_cmd "title: 🥷 Update Failed"
    dialog_cmd "icon: SF=exclamationmark.triangle.fill,colour=red"
    dialog_cmd "message: The update for **${app_name}** did not complete successfully.${error_line}\n\nPlease contact your IT team if this issue persists."
    dialog_cmd "progresstext: Update failed"
    dialog_cmd "progress: 100"
    dialog_cmd "button1text: OK"
    sleep 0.5
    dialog_cmd "button1: enable"

    log "Failure dialog shown for: $app_name (${error_msg:-no error message})"
}

# ---------------------------------------------------------------------------
# Show timeout/unknown status dialog — launched in user GUI session
# ---------------------------------------------------------------------------
show_timeout_dialog() {
    local app_name="$1"

    dialog_cmd "quit:"
    sleep 1
    rm -f "$DIALOG_CMD_FILE"

    dialog_as_user \
        --title "🥷 Update Status Unknown" \
        --titlefont "size=17" \
        --message "The update for **${app_name}** may still be in progress or encountered an issue.\n\nYou can reopen the application manually." \
        --messagefont "size=14" \
        --icon "SF=exclamationmark.triangle.fill,colour=yellow" \
        --button1text "OK" \
        --appearance light \
        --windowbuttons close,min,max \
        --position centre \
        --moveable \
        --ontop \
        --width 520 \
        --height 220

    log "Timeout dialog shown for: $app_name"
}

# ---------------------------------------------------------------------------
# Watch NJDialog log for user decision after a given byte offset
# Returns: "yes", "no", or "timeout"
# ---------------------------------------------------------------------------
watch_for_decision_after_offset() {
    local log_file="$1"
    local start_offset="$2"
    local wait_elapsed=0
    local max_wait=600

    while (( wait_elapsed < max_wait )); do
        sleep "$POLL_INTERVAL"
        wait_elapsed=$((wait_elapsed + POLL_INTERVAL))

        local new_content
        new_content=$(tail -c "+${start_offset}" "$log_file" 2>/dev/null)

        if echo "$new_content" | grep -qF "Alert Dialog User Clicked Yes"; then
            echo "yes"; return
        fi
        if echo "$new_content" | grep -qF "Alert Dialog User Clicked No"; then
            echo "no"; return
        fi
        if echo "$new_content" | grep -qF "Alert Dialog timeout"; then
            echo "timeout"; return
        fi
    done
    echo "timeout"
}

# ---------------------------------------------------------------------------
# Handle a single patch event end-to-end
# ---------------------------------------------------------------------------
handle_patch_event() {
    local log_file="$1"
    local trigger_offset="$2"

    log "=== NJDialog appeared — waiting for user decision ==="

    # Get console user early — needed for all dialog launches
    get_console_user
    if [[ -z "$CONSOLE_USER" ]]; then
        log "No logged-in user — cannot show dialogs, skipping patch event"
        return
    fi
    log "Console user: $CONSOLE_USER (uid: $CONSOLE_UID)"

    local decision
    decision=$(watch_for_decision_after_offset "$log_file" "$trigger_offset")
    log "User decision: $decision"

    if [[ "$decision" != "yes" ]]; then
        log "User did not click Install Now — doing nothing."
        return
    fi

    log "=== User clicked Install Now — starting patch handler ==="

    local snapshot_mon_time=""
    if [[ -f "$ORBIT_APPLY_SNAPSHOT" ]]; then
        snapshot_mon_time=$(grep -o '"monTime" *: *[0-9]*' "$ORBIT_APPLY_SNAPSHOT" | grep -o '[0-9]*' | head -1)
    fi
    log "Snapshot monTime: ${snapshot_mon_time:-none}"

    local snapshot_title=""
    if [[ -f "$ORBIT_APPLY_SNAPSHOT" ]]; then
        snapshot_title=$(grep -o '"title" *: *"[^"]*"' "$ORBIT_APPLY_SNAPSHOT" | head -1 | sed 's/"title" *: *"//;s/"//')
        log "Snapshot patch title: ${snapshot_title:-unknown}"
    fi

    local APP_NAME APP_PATH APP_PREV_VERSION
    APP_NAME="${snapshot_title:-Software Update}"
    APP_PATH=""
    APP_PREV_VERSION=""

    if [[ -n "$snapshot_title" ]]; then
        lookup_app_info "$snapshot_title" "$INVENTORY_SNAPSHOT"
        log "Early lookup — name: $APP_NAME | path: ${APP_PATH:-not found} | prev: ${APP_PREV_VERSION:-unknown}"
    fi

    local app_icon=""
    [[ -n "$APP_PATH" && -d "$APP_PATH" ]] && app_icon=$(get_app_icon "$APP_PATH")
    log "Early icon: ${app_icon:-not found}"

    if [[ -n "$APP_PATH" && -d "$APP_PATH" ]]; then
        show_progress_dialog_with_app "$APP_NAME" "$app_icon"
    else
        show_progress_dialog
        [[ -n "$APP_NAME" ]] && update_progress_dialog_with_app "$APP_NAME" ""
    fi

    # Give swiftDialog a moment to launch before we start writing to the command file
    sleep 2

    # Poll Orbit for monTime change — signals Ninja patch job is done
    local elapsed=0
    local install_done=false
    local patch_title=""

    while (( elapsed < INSTALL_TIMEOUT )); do
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))

        if [[ -f "$ORBIT_APPLY_OUTPUT" ]]; then
            local current_mon_time
            current_mon_time=$(grep -o '"monTime" *: *[0-9]*' "$ORBIT_APPLY_OUTPUT" | grep -o '[0-9]*' | head -1)

            if [[ -n "$current_mon_time" && "$current_mon_time" != "$snapshot_mon_time" ]]; then
                log "Orbit apply output updated (monTime: $current_mon_time)"
                patch_title=$(grep -o '"title" *: *"[^"]*"' "$ORBIT_APPLY_OUTPUT" | head -1 | sed 's/"title" *: *"//;s/"//')
                [[ -z "$patch_title" ]] && patch_title="$snapshot_title"
                log "Patch title from Orbit: $patch_title"
                install_done=true
                break
            fi
        fi

        case "$elapsed" in
            30)  dialog_cmd "progresstext: Still installing, almost there…" ;;
            90)  dialog_cmd "progresstext: This may take a few more minutes…" ;;
            180) dialog_cmd "progresstext: Finishing up…" ;;
        esac
    done

    if $install_done && [[ -n "$patch_title" ]]; then

        if [[ "$patch_title" != "$snapshot_title" || -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
            lookup_app_info "$patch_title" "$SOFTWARE_INVENTORY"
            log "Post-install lookup — name: $APP_NAME | path: ${APP_PATH:-not found}"
            [[ -n "$APP_PATH" && -d "$APP_PATH" ]] && app_icon=$(get_app_icon "$APP_PATH")
        fi

        local patch_status new_version patch_error
        patch_status=$(get_patch_status "$ORBIT_APPLY_OUTPUT")
        new_version=$(get_new_version_from_orbit "$ORBIT_APPLY_OUTPUT")
        patch_error=$(get_patch_error "$ORBIT_APPLY_OUTPUT")

        [[ -n "$APP_PREV_VERSION" && "$APP_PREV_VERSION" == "$new_version" ]] && APP_PREV_VERSION=""

        log "Patch status: $patch_status"
        log "App name: $APP_NAME"
        log "App path: ${APP_PATH:-not found}"
        log "Version: ${APP_PREV_VERSION:-unknown} → ${new_version:-unknown}"
        log "App icon: ${app_icon:-not found}"

        update_progress_dialog_with_app "$APP_NAME" "$app_icon"
        sleep 0.3

        if [[ "$patch_status" == "success" ]]; then

            # Wait for any app-specific updater processes to finish
            if [[ -n "$APP_PATH" ]]; then
                wait_for_app_updater_to_exit "$APP_PATH"
            fi

            # Show success dialog — user dismisses via OK button
            show_completion_dialog "$APP_NAME" "$APP_PREV_VERSION" "$new_version"
            sleep 3

            # Relaunch the app as the logged-in user
            if [[ -n "$APP_PATH" && -d "$APP_PATH" ]]; then
                local app_bundle
                app_bundle=$(basename "$APP_PATH" .app)
                log "Relaunching $APP_NAME as user: $CONSOLE_USER"
                launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" open -a "$APP_PATH" &

                local app_wait=0
                while ! pgrep -f "$app_bundle" > /dev/null 2>&1; do
                    sleep 1
                    app_wait=$((app_wait + 1))
                    (( app_wait > 30 )) && break
                done
                sleep 5
            else
                log "No valid app path — skipping relaunch"
            fi

        else
            log "Patch failed — error: ${patch_error:-unknown}"
            show_failure_dialog "$APP_NAME" "$patch_error"
        fi

        # Do not send quit: — user dismisses dialog via OK button
        rm -f "$DIALOG_CMD_FILE"

    else
        log "Install timed out — no Orbit output change detected within ${INSTALL_TIMEOUT}s"
        show_timeout_dialog "$APP_NAME"
    fi

    log "=== Patch event complete ==="
}

# ---------------------------------------------------------------------------
# Main loop — watches NJDialog log directory for new patch prompts
# ---------------------------------------------------------------------------
main() {
    log "ninja_patch_watcher started (PID $$)"

    if [[ ! -x "$DIALOG_BIN" ]]; then
        log "ERROR: swiftDialog not found at $DIALOG_BIN — exiting."
        exit 1
    fi

    if [[ ! -d "$NJDIALOG_LOG_DIR" ]]; then
        log "ERROR: NJDialog log directory not found — exiting."
        exit 1
    fi

    if [[ ! -f "$PATCH_POLICY_JSON" ]]; then
        log "WARNING: Patch policy JSON not found — app lookup will use inventory name directly"
    fi

    local offset_dir="/tmp/ninja_patch_offsets"
    rm -rf "$offset_dir"
    mkdir -p "$offset_dir"

    for existing_file in "$NJDIALOG_LOG_DIR"/NinjaRMMNJDialog_*.log; do
        [[ -f "$existing_file" ]] || continue
        local safe_name current_size
        safe_name=$(echo "$existing_file" | tr '/' '_' | tr '.' '_')
        current_size=$(wc -c < "$existing_file" 2>/dev/null || echo 0)
        echo "$current_size" > "${offset_dir}/${safe_name}"
        log "Seeded: $existing_file at offset $current_size"
    done

    log "Watching for NJDialog activity..."

    while true; do
        for log_file in "$NJDIALOG_LOG_DIR"/NinjaRMMNJDialog_*.log; do
            [[ -f "$log_file" ]] || continue

            local safe_name offset_file last_offset current_size new_content
            safe_name=$(echo "$log_file" | tr '/' '_' | tr '.' '_')
            offset_file="${offset_dir}/${safe_name}"

            last_offset=0
            [[ -f "$offset_file" ]] && last_offset=$(cat "$offset_file" 2>/dev/null || echo 0)

            current_size=$(wc -c < "$log_file" 2>/dev/null || echo 0)
            (( current_size <= last_offset )) && continue

            new_content=$(tail -c "+$((last_offset + 1))" "$log_file" 2>/dev/null)
            echo "$current_size" > "$offset_file"

            if echo "$new_content" | grep -qF "Showing Alert Dialog"; then
                log "NJDialog detected: $log_file (offset $last_offset → $current_size)"
                snapshot_ninja_outputs
                handle_patch_event "$log_file" "$((current_size + 1))" &
            fi
        done

        sleep "$POLL_INTERVAL"
    done
}

main "$@"