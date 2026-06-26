#!/bin/bash
# =============================================================================
# ninja_patch_watcher.sh — Root LaunchDaemon
# Version: 4.15
#
# Watches NinjaRMM NJDialog logs. When user clicks Install Now, handles all
# Ninja/Orbit logic and writes UI instructions to /tmp/ninja_patch_ui.json.
# The companion agent (ninja_patch_watcher_agent.sh) runs as the logged-in
# user and handles all swiftDialog UI — LaunchDaemons run in System session
# type and cannot display GUI processes on macOS. This is not a workaround,
# it is the correct macOS architecture for system daemons that need UI.
# =============================================================================

NJDIALOG_LOG_DIR="/Applications/NinjaRMMAgent/programdata/logs/njdialog"
ORBIT_APPLY_OUTPUT="/Applications/NinjaRMMAgent/programdata/jsonoutput/Orbit-apply-output.json"
SOFTWARE_INVENTORY="/Applications/NinjaRMMAgent/programdata/jsonoutput/softwareInventory.json"
PATCH_POLICY_JSON="/Applications/NinjaRMMAgent/programdata/policy/ws.agent.patches.OSX.X86_64.json"
ORBIT_APPLY_SNAPSHOT="/tmp/ninja_orbit_apply_snapshot.json"
INVENTORY_SNAPSHOT="/tmp/ninja_inventory_snapshot.json"
UI_INSTRUCTION_FILE="/tmp/ninja_patch_ui.json"
POLL_INTERVAL=3
INSTALL_TIMEOUT=300
WATCHER_LOG="/var/log/ninja_patch_watcher.log"

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" >> "$WATCHER_LOG"
}

# ---------------------------------------------------------------------------
# Write UI instruction for the agent to act on.
# Agent polls this file and reacts to the action field.
# ---------------------------------------------------------------------------
write_ui() {
    local action="$1"       # progress | success | failure | timeout | clear
    local app_name="${2:-}"
    local app_icon="${3:-}"
    local app_path="${4:-}"
    local new_version="${5:-}"
    local prev_version="${6:-}"
    local error_msg="${7:-}"
    printf '{"action":"%s","app_name":"%s","app_icon":"%s","app_path":"%s","new_version":"%s","prev_version":"%s","error":"%s","ts":"%s"}\n' \
        "$action" "$app_name" "$app_icon" "$app_path" "$new_version" "$prev_version" "$error_msg" "$(date +%s)" \
        > "$UI_INSTRUCTION_FILE"
    chmod 644 "$UI_INSTRUCTION_FILE"
    log "UI instruction: action=$action app=$app_name"
}

# ---------------------------------------------------------------------------
# Snapshot both Ninja output files at NJDialog trigger time
# ---------------------------------------------------------------------------
snapshot_ninja_outputs() {
    if [[ -f "$ORBIT_APPLY_OUTPUT" ]]; then
        cp "$ORBIT_APPLY_OUTPUT" "$ORBIT_APPLY_SNAPSHOT"
        local mon
        mon=$(grep -o '"monTime" *: *[0-9]*' "$ORBIT_APPLY_SNAPSHOT" | grep -o '[0-9]*' | head -1)
        log "Orbit apply snapshot taken (monTime: ${mon:-unknown})"
    else
        rm -f "$ORBIT_APPLY_SNAPSHOT"
        log "Orbit apply output not found"
    fi
    if [[ -f "$SOFTWARE_INVENTORY" ]]; then
        cp "$SOFTWARE_INVENTORY" "$INVENTORY_SNAPSHOT"
        log "Software inventory snapshot taken"
    else
        rm -f "$INVENTORY_SNAPSHOT"
        log "Software inventory not found"
    fi
}

# ---------------------------------------------------------------------------
# Policy lookup from flat JSON file
# Sets globals: POLICY_PRODUCT_NAME, POLICY_VENDOR_NAME
# ---------------------------------------------------------------------------
lookup_policy_product() {
    local orbit_title="$1"
    POLICY_PRODUCT_NAME=""
    POLICY_VENDOR_NAME=""
    [[ ! -f "$PATCH_POLICY_JSON" ]] && log "Patch policy JSON not found" && return
    local match_line
    match_line=$(grep -in "\"productName\" *: *\"${orbit_title}\"" "$PATCH_POLICY_JSON" 2>/dev/null | head -1 | cut -d: -f1)
    [[ -z "$match_line" ]] && log "No policy match for: $orbit_title" && return
    POLICY_PRODUCT_NAME=$(sed -n "${match_line}p" "$PATCH_POLICY_JSON" | \
        grep -o '"productName" *: *"[^"]*"' | sed 's/"productName" *: *"//;s/"//')
    local s=$(( match_line - 5 ))
    local e=$(( match_line + 5 ))
    [[ $s -lt 1 ]] && s=1
    POLICY_VENDOR_NAME=$(sed -n "${s},${e}p" "$PATCH_POLICY_JSON" | \
        grep -o '"vendorName" *: *"[^"]*"' | head -1 | sed 's/"vendorName" *: *"//;s/"//')
    log "Policy match: productName=$POLICY_PRODUCT_NAME vendorName=$POLICY_VENDOR_NAME"
}

# ---------------------------------------------------------------------------
# Inventory lookup — location is line before name in softwareInventory.json
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
        local name_line
        name_line=$(grep -n "\"name\" *: *\"${match_name}\"" "$inventory_file" 2>/dev/null | head -1 | cut -d: -f1)
        if [[ -n "$name_line" ]]; then
            local loc_line=$(( name_line - 1 ))
            local inv_path
            inv_path=$(sed -n "${loc_line}p" "$inventory_file" 2>/dev/null | \
                grep -o '"location" *: *"[^"]*"' | sed 's/"location" *: *"//;s/"//')
            if [[ -n "$inv_path" && -d "$inv_path" ]]; then
                APP_PATH="$inv_path"
                APP_NAME="$match_name"
                log "Inventory match: '$APP_NAME' @ $APP_PATH"
                if [[ -f "$INVENTORY_SNAPSHOT" ]]; then
                    local snap_line
                    snap_line=$(grep -n "\"name\" *: *\"${match_name}\"" "$INVENTORY_SNAPSHOT" 2>/dev/null | head -1 | cut -d: -f1)
                    if [[ -n "$snap_line" ]]; then
                        APP_PREV_VERSION=$(sed -n "$(( snap_line + 1 ))p" "$INVENTORY_SNAPSHOT" 2>/dev/null | \
                            grep -o '"version" *: *"[^"]*"' | sed 's/"version" *: *"//;s/"//')
                    fi
                fi
            else
                log "Inventory location invalid for: $match_name"
            fi
        else
            log "No inventory match for: $match_name"
        fi
    fi
    if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
        # Build keywords to try: full lowercased name, then individual camelCase words
        # e.g. AcrobatDCContinuous -> try "acrobatdccontinuous", then "acrobat","continuous"
        local full_kw
        full_kw=$(echo "$match_name" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        local camel_words
        camel_words=$(echo "$match_name" | sed 's/\([A-Z][a-z]\)/\ \1/g; s/\([a-z]\)\([A-Z]\)/\1\ \2/g' | \
            tr '[:upper:]' '[:lower:]' | tr -s ' ')
        log "Filesystem search — full: $full_kw | words: $camel_words"
        local all_apps
        all_apps=$(find /Applications -maxdepth 3 -iname "*.app" 2>/dev/null)
        local kw
        for kw in "$full_kw" $camel_words; do
            [[ ${#kw} -le 3 ]] && continue
            local found
            found=$(echo "$all_apps" | while read -r app; do
                local b
                b=$(basename "$app" .app | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
                if [[ "$b" == *"$kw"* ]] || [[ "$kw" == *"$b"* && ${#b} -gt 3 ]]; then
                    echo "$app"; break
                fi
            done | head -1)
            if [[ -n "$found" && -d "$found" ]]; then
                APP_PATH="$found"
                log "Filesystem match ($kw): $APP_PATH"
                break
            fi
        done
        [[ -z "$APP_PATH" ]] && log "App not found for: $orbit_title"
    fi
    if [[ -n "$APP_PATH" && -d "$APP_PATH" && "$APP_NAME" == "$orbit_title" ]]; then
        local bn
        bn=$(defaults read "${APP_PATH}/Contents/Info" CFBundleName 2>/dev/null || \
             defaults read "${APP_PATH}/Contents/Info" CFBundleDisplayName 2>/dev/null || true)
        [[ -n "$bn" ]] && APP_NAME="$bn"
    fi
}

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

get_patch_status() {
    local f="${1:-$ORBIT_APPLY_OUTPUT}"
    local title="${2:-}"
    [[ ! -f "$f" ]] && echo "unknown" && return
    local s
    if [[ -n "$title" ]]; then
        s=$(python3 -c "
import json, sys
try:
    data = json.load(open('$f'))
    for item in data.get('patch_apply_report',{}).get('data',[]):
        if item.get('title','').lower() == '$title'.lower():
            print(item.get('status',''))
            break
except: pass
" 2>/dev/null)
    fi
    [[ -z "$s" ]] && s=$(grep -o '"status" *: *"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/"status" *: *"//;s/"//')
    case "$s" in
        success|installed) echo "success" ;;
        failed)            echo "failed" ;;
        *)                 echo "unknown" ;;
    esac
}

get_new_version_from_orbit() {
    local f="${1:-$ORBIT_APPLY_OUTPUT}"
    local title="${2:-}"
    [[ ! -f "$f" ]] && return
    local v
    if [[ -n "$title" ]]; then
        v=$(python3 -c "
import json, sys
try:
    data = json.load(open('$f'))
    for item in data.get('patch_apply_report',{}).get('data',[]):
        if item.get('title','').lower() == '$title'.lower():
            print(item.get('version',''))
            break
except: pass
" 2>/dev/null)
    fi
    [[ -z "$v" ]] && v=$(grep -o '"version" *: *"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/"version" *: *"//;s/"//')
    echo "$v"
}

get_patch_error() {
    local f="${1:-$ORBIT_APPLY_OUTPUT}"
    [[ ! -f "$f" ]] && return
    grep -o '"message" *: *"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/"message" *: *"//;s/"//'
}

wait_for_app_updater_to_exit() {
    local app_path="$1"
    local max_wait=120
    local waited=0
    if ! ps aux 2>/dev/null | grep -v grep | grep -qF "${app_path}/"; then
        log "No active updater for: $app_path"
        return
    fi
    log "Waiting for updater in $app_path to exit..."
    while (( waited < max_wait )); do
        if ! ps aux 2>/dev/null | grep -v grep | grep -qF "${app_path}/"; then
            log "Updater exited after ${waited}s"
            return
        fi
        sleep 1
        waited=$((waited + 1))
    done
    log "Timed out waiting for updater after ${max_wait}s"
}

watch_for_decision_after_offset() {
    local log_file="$1"
    local start_offset="$2"
    local waited=0
    local max_wait=600
    while (( waited < max_wait )); do
        sleep "$POLL_INTERVAL"
        waited=$((waited + POLL_INTERVAL))
        local content
        content=$(tail -c "+${start_offset}" "$log_file" 2>/dev/null)
        if echo "$content" | grep -qF "Alert Dialog User Clicked Yes"; then echo "yes"; return; fi
        if echo "$content" | grep -qF "Alert Dialog User Clicked No";  then echo "no";  return; fi
        if echo "$content" | grep -qF "Alert Dialog timeout";          then echo "timeout"; return; fi
    done
    echo "timeout"
}

handle_patch_event() {
    local log_file="$1"
    local trigger_offset="$2"

    log "=== NJDialog appeared — waiting for user decision ==="
    local decision
    decision=$(watch_for_decision_after_offset "$log_file" "$trigger_offset")
    log "User decision: $decision"

    if [[ "$decision" != "yes" ]]; then
        log "User did not click Install Now — doing nothing."
        return
    fi

    log "=== User clicked Install Now — starting patch handler ==="

    local snapshot_mon_time=""
    [[ -f "$ORBIT_APPLY_SNAPSHOT" ]] && \
        snapshot_mon_time=$(grep -o '"monTime" *: *[0-9]*' "$ORBIT_APPLY_SNAPSHOT" | grep -o '[0-9]*' | head -1)
    log "Snapshot monTime: ${snapshot_mon_time:-none}"

    local snapshot_title=""
    [[ -f "$ORBIT_APPLY_SNAPSHOT" ]] && \
        snapshot_title=$(grep -o '"title" *: *"[^"]*"' "$ORBIT_APPLY_SNAPSHOT" | head -1 | sed 's/"title" *: *"//;s/"//')
    log "Snapshot patch title: ${snapshot_title:-unknown}"

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

    # Tell agent to show progress dialog
    write_ui "progress" "$APP_NAME" "$app_icon" "$APP_PATH"

    # Poll Orbit for completion — detect via monTime change OR title appearing in apply report
    # Orbit does not always update monTime when appending results for subsequent patches
    local elapsed=0
    local install_done=false
    local patch_title=""

    while (( elapsed < INSTALL_TIMEOUT )); do
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        if [[ -f "$ORBIT_APPLY_OUTPUT" ]]; then
            local current_mon_time
            current_mon_time=$(grep -o '"monTime" *: *[0-9]*' "$ORBIT_APPLY_OUTPUT" | grep -o '[0-9]*' | head -1)

            # Primary detection: monTime changed
            if [[ -n "$current_mon_time" && "$current_mon_time" != "$snapshot_mon_time" ]]; then
                log "Orbit apply output updated (monTime: $current_mon_time)"
                patch_title=$(grep -o '"title" *: *"[^"]*"' "$ORBIT_APPLY_OUTPUT" | head -1 | sed 's/"title" *: *"//;s/"//')
                [[ -z "$patch_title" ]] && patch_title="$snapshot_title"
                # Check if this is a code 21 failure (app still running) — Orbit will retry
                local mt_error_code
                mt_error_code=$(python3 -c "
import json
try:
    data = json.load(open('$ORBIT_APPLY_OUTPUT'))
    for item in data.get('patch_apply_report',{}).get('data',[]):
        if item.get('title','').lower() == '$patch_title'.lower():
            codes = [e.get('code','') for e in item.get('errorCodes',[])]
            print(','.join(codes))
            break
except: pass
" 2>/dev/null)
                if [[ "$(get_patch_status "$ORBIT_APPLY_OUTPUT" "$patch_title")" == "failed" && "$mt_error_code" == *"21"* ]]; then
                    log "Orbit reports $patch_title failed (app still running, code 21) — updating dialog and waiting for retry..."
                    write_ui "waiting" "$APP_NAME" "$app_icon" "$APP_PATH"
                    snapshot_mon_time="$current_mon_time"
                else
                    log "Patch title from Orbit: $patch_title"
                    install_done=true
                    break
                fi
            fi

            # Secondary detection: snapshot title appears in apply_report with a terminal status
            # even if monTime did not change (Orbit appended result without updating monTime)
            # Exception: "failed" with error code 21 (Application running) means Orbit will
            # retry after the app closes — keep polling instead of treating as done
            if [[ -n "$snapshot_title" ]]; then
                local title_status title_error
                eval "$(python3 -c "
import json, sys
try:
    data = json.load(open('$ORBIT_APPLY_OUTPUT'))
    for item in data.get('patch_apply_report', {}).get('data', []):
        if item.get('title','').lower() == '$snapshot_title'.lower():
            status = item.get('status','')
            codes = [e.get('code','') for e in item.get('errorCodes',[])]
            print('title_status=' + repr(status))
            print('title_error=' + repr(','.join(codes)))
            break
except: pass
" 2>/dev/null)"
                if [[ "$title_status" == "installed" || "$title_status" == "success" ]]; then
                    log "Orbit apply report contains $snapshot_title with status: $title_status (monTime unchanged)"
                    patch_title="$snapshot_title"
                    install_done=true
                    break
                elif [[ "$title_status" == "failed" ]]; then
                    # Error code 21 = Application running — Orbit will retry, keep polling
                    if [[ "$title_error" == *"21"* ]]; then
                        log "Orbit reports $snapshot_title failed (app still running) — updating dialog and waiting for retry..."
                        write_ui "waiting" "$APP_NAME" "$app_icon" "$APP_PATH"
                    else
                        log "Orbit apply report contains $snapshot_title with status: failed (monTime unchanged)"
                        patch_title="$snapshot_title"
                        install_done=true
                        break
                    fi
                fi
            fi
        fi
    done

    if $install_done && [[ -n "$patch_title" ]]; then

        if [[ "$patch_title" != "$snapshot_title" || -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
            lookup_app_info "$patch_title" "$SOFTWARE_INVENTORY"
            log "Post-install lookup — name: $APP_NAME | path: ${APP_PATH:-not found}"
            [[ -n "$APP_PATH" && -d "$APP_PATH" ]] && app_icon=$(get_app_icon "$APP_PATH")
        fi

        local patch_status new_version patch_error
        patch_status=$(get_patch_status "$ORBIT_APPLY_OUTPUT" "$patch_title")
        new_version=$(get_new_version_from_orbit "$ORBIT_APPLY_OUTPUT" "$patch_title")
        patch_error=$(get_patch_error "$ORBIT_APPLY_OUTPUT")
        [[ -n "$APP_PREV_VERSION" && "$APP_PREV_VERSION" == "$new_version" ]] && APP_PREV_VERSION=""

        log "Patch status: $patch_status"
        log "App: $APP_NAME | path: ${APP_PATH:-not found} | version: ${APP_PREV_VERSION:-unknown} → ${new_version:-unknown}"

        if [[ "$patch_status" == "success" ]]; then
            # Wait for any app updater to finish before signaling success
            [[ -n "$APP_PATH" ]] && wait_for_app_updater_to_exit "$APP_PATH"
            # Tell agent to show success and relaunch app
            write_ui "success" "$APP_NAME" "$app_icon" "$APP_PATH" "$new_version" "$APP_PREV_VERSION"
        else
            log "Patch failed — error: ${patch_error:-unknown}"
            write_ui "failure" "$APP_NAME" "$app_icon" "$APP_PATH" "" "" "$patch_error"
        fi

    else
        log "Install timed out"
        write_ui "timeout" "$APP_NAME" "$app_icon" "$APP_PATH"
    fi

    log "=== Patch event complete ==="
}

main() {
    log "ninja_patch_watcher v4.15 started (PID $$)"

    if [[ ! -d "$NJDIALOG_LOG_DIR" ]]; then
        log "ERROR: NJDialog log directory not found — exiting."
        exit 1
    fi

    [[ ! -f "$PATCH_POLICY_JSON" ]] && log "WARNING: Patch policy JSON not found"

    # Clear any stale UI instruction
    echo '{"action":"clear"}' > "$UI_INSTRUCTION_FILE"
    chmod 644 "$UI_INSTRUCTION_FILE"

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
                log "NJDialog detected: $log_file"
                snapshot_ninja_outputs
                handle_patch_event "$log_file" "$((current_size + 1))" &
            fi
        done
        sleep "$POLL_INTERVAL"
    done
}

main "$@"
