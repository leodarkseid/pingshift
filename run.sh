#!/bin/bash

# Force locale to C to prevent string extraction fragility from localization
export LC_ALL=C

# ==========================================
# 1. CONFIGURATION
# ==========================================
CHECK_INTERVAL=15               # Seconds between light ping tests
HEAVY_CHECK_MULTIPLIER=20       # Run heavy test every 20 loops (15s * 20 = 300s / 5 mins)

# Thresholds
MAX_LATENCY=150
MIN_DL_SPEED=1000000 
MIN_UL_SPEED=500000

# Redundant Endpoints to prevent Single Points of Failure
PING_TARGETS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
DL_TARGETS=("http://speedtest.tele2.net/1MB.zip" "https://proof.ovh.net/files/1Mb.dat")
UL_TARGETS=("https://httpbin.org/post" "https://ptsv2.com/t/netmon/post")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/monitor.conf"

# ==========================================
# 2. PARSE CONFIG & SETUP
# ==========================================
parse_config() {
    # Safe Config Parsing: Read only valid assignments
    if [ -f "$CONFIG_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            # Strip inline comments (only if # is preceded by a space or tab)
            line=$(echo "$line" | sed 's/[ \t]#.*//' | sed 's/[ \t]*$//')
            
            # Ignore full comment lines or empty lines
            [[ -z "${line// }" ]] && continue
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            
            # Match array assignments (spaces allowed only inside parentheticals)
            if [[ "$line" =~ ^([A-Z_]+)=\(\s*([a-zA-Z0-9_.:/\"\'[:space:]-]+)\s*\)$ ]]; then
                eval "${BASH_REMATCH[1]}=(${BASH_REMATCH[2]})"
            # Match scalar assignments (STRICTLY NO SPACES to prevent eval injection)
            elif [[ "$line" =~ ^([A-Z_]+)=([a-zA-Z0-9_.:/\"\'-]+)$ ]]; then
                eval "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
            fi
        done < "$CONFIG_FILE"
    fi

    # Command line overrides (safe parsing)
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --interval)
                if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then CHECK_INTERVAL="$2"; fi
                shift
                ;;
            --latency)
                if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then MAX_LATENCY="$2"; fi
                shift
                ;;
            --heavy-loops)
                if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then HEAVY_CHECK_MULTIPLIER="$2"; fi
                shift
                ;;
            *) ;;
        esac
        shift
    done

    # Ensure valid defaults if check interval is unset or invalid
    if ! [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] || [ "$CHECK_INTERVAL" -eq 0 ]; then
        CHECK_INTERVAL=15
    fi

    # Validate that arrays haven't been corrupted by misformatted monitor.conf entries
    if ! declare -p PING_TARGETS 2>/dev/null | grep -q "^declare -a"; then
        echo "Error: PING_TARGETS is missing or malformed in monitor.conf (Must be an array: VAR=(\"a\" \"b\"))"
        exit 1
    fi
    if ! declare -p DL_TARGETS 2>/dev/null | grep -q "^declare -a"; then
        echo "Error: DL_TARGETS is missing or malformed in monitor.conf"
        exit 1
    fi
    if ! declare -p UL_TARGETS 2>/dev/null | grep -q "^declare -a"; then
        echo "Error: UL_TARGETS is missing or malformed in monitor.conf"
        exit 1
    fi
}

setup_payload() {
    # 1. DEPENDENCY VERIFICATION
    local required_cmds=("ping" "curl" "nmcli" "ip" "awk" "notify-send")
    local missing_deps=0

    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Missing critical dependency: $cmd" >&2
            missing_deps=1
        fi
    done

    if [ "$missing_deps" -eq 1 ]; then
        echo "Exiting: Please install missing dependencies to run PingShift." >&2
        exit 1
    fi

    # 2. GENERATE UPLOAD PAYLOAD
    # Generate dummy upload payload ONCE to prevent SSD wear and limit false positives
    TMP_UP_FILE="/tmp/net_monitor_up_payload.dat"
    if [ -d "/dev/shm" ]; then
        TMP_UP_FILE="/dev/shm/net_monitor_up_payload.dat"
    fi
    if [ ! -f "$TMP_UP_FILE" ]; then
        head -c 1M </dev/urandom > "$TMP_UP_FILE" 2>/dev/null || true
    fi

    echo "Starting Robust Network Monitor..."
    echo "Ping: Every ${CHECK_INTERVAL}s | Bandwidth: Every $((CHECK_INTERVAL * HEAVY_CHECK_MULTIPLIER))s"
}

# ==========================================
# 3. HELPER: NUMERIC VALIDATION
# ==========================================
is_numeric() {
    # Returns 0 (true) if the input is a valid positive integer, 1 (false) otherwise
    [[ "$1" =~ ^[0-9]+$ ]]
}

# ==========================================
# 4. NETWORK QUALITY FUNCTIONS
# ==========================================

check_light_ping() {
    # Loop through targets. If ANY target succeeds, the network is alive.
    for target in "${PING_TARGETS[@]}"; do
        # Use LANG=C for parsing stability, reduce count/timeout to prevent accumulated delays
        ping_stats=$(LANG=C ping -c 2 -W 1 -q "$target" 2>/dev/null)
        
        # If ping failed entirely, try the next target
        if [ $? -ne 0 ]; then continue; fi
        
        # Extract latency safely: grabs text after '=', strips spaces, splits by '/', takes 2nd item (avg), and strips decimals
        avg_lat=$(echo "$ping_stats" | awk -F'=' '/^(rtt|round-trip)/ {print $2}' | tr -d ' ' | awk -F'/' '{print $2}' | cut -d. -f1)
        
        # Validate it's a number and check threshold
        if is_numeric "$avg_lat" && [ "$avg_lat" -le "$MAX_LATENCY" ]; then
            return 0 # Success! Ping is good.
        fi
    done
    
    echo "Light Check Failed: All ping targets unreachable or high latency."
    return 1 # Failure
}

check_heavy_bandwidth() {
    echo "Running heavy bandwidth check..."
    
    # --- DOWNLOAD TEST ---
    dl_passed=false
    for target in "${DL_TARGETS[@]}"; do
        # Fetch up to 2MB to limit total bandwidth waste during test
        dl_speed=$((curl -s -r 0-2097152 -m 5 -w "%{speed_download}" -o /dev/null "$target" || echo "0") | cut -d. -f1)
        
        if is_numeric "$dl_speed" && [ "$dl_speed" -ge "$MIN_DL_SPEED" ]; then
            dl_passed=true
            break # Success, no need to try backup download target
        fi
    done

    if [ "$dl_passed" = false ]; then
        echo "Heavy Check Failed: Download speeds below threshold on all targets."
        return 1
    fi

    # --- UPLOAD TEST ---
    ul_passed=false
    
    if [ ! -f "$TMP_UP_FILE" ]; then
        echo "Warning: Upload payload could not be created. Skipping upload verification."
        return 0 # Don't trigger a hard failure just because local file system has an issue
    fi

    for target in "${UL_TARGETS[@]}"; do
        ul_speed=$((curl -s -m 5 -w "%{speed_upload}" -o /dev/null -F "file=@${TMP_UP_FILE}" "$target" || echo "0") | cut -d. -f1)
        
        if is_numeric "$ul_speed" && [ "$ul_speed" -ge "$MIN_UL_SPEED" ]; then
            ul_passed=true
            break # Success
        fi
    done

    if [ "$ul_passed" = false ]; then
        echo "Heavy Check Failed: Upload speeds below threshold on all targets."
        return 1
    fi

    return 0 # Passed both DL and UL
}

# ==========================================
# 5. FAILOVER CHUNK LOGIC
# ==========================================
run_failover_protocol() {
    # Reset to 1 to prevent immediate bandwidth test upon reconnecting to a new network
    LOOP_COUNT=1
    
    echo "Network issue detected! Initiating failover protocol..."
    
    # Get active internet interface via route to avoid picking local-only connections (safely extracting 'dev' column)
    ACTIVE_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    
    if [ -n "$ACTIVE_IFACE" ]; then
        CURRENT_UUID=$(nmcli -g UUID,DEVICE connection show --active | grep ":$ACTIVE_IFACE$" | cut -d: -f1 | head -n 1)
    else
        # If ip route get 8.8.8.8 fails (e.g., no default route completely), fallback to just grabbing the first active non-loopback profile
        echo "Warning: No route to 8.8.8.8 found. Falling back to any active wireless/ethernet profile."
        CURRENT_UUID=$(nmcli -g UUID,TYPE connection show --active | grep -E ':(802-11-wireless|802-3-ethernet)$' | cut -d: -f1 | head -n 1)
    fi
    
    # Get a list of currently visible SSIDs for Wi-Fi to avoid hanging on out-of-range networks
    mapfile -t VISIBLE_SSIDS < <(nmcli -g SSID device wifi list 2>/dev/null | grep -v '^$')
    
    # Getting UUID and TYPE first makes parsing robust against names containing colons
    mapfile -t ALL_CONNS < <(nmcli -g UUID,TYPE,NAME connection show | grep -E ':(802-11-wireless|802-3-ethernet):')

    INTERNET_RESTORED=false

    for entry in "${ALL_CONNS[@]}"; do
        conn_uuid=$(echo "$entry" | cut -d: -f1)
        # Type is reliably the second colon-separated field now
        conn_type=$(echo "$entry" | cut -d: -f2)
        # Name is everything else (cutting from field 3 onwards), handling escaped colons natively
        conn_name=$(echo "$entry" | cut -d: -f3-)

        if [ -z "$conn_uuid" ] || [ "$conn_uuid" = "$CURRENT_UUID" ]; then
            continue
        fi

        # If it's a wireless connection, verify it's currently visible
        if [ "$conn_type" = "802-11-wireless" ]; then
            # Extract the actual SSID, not the profile name
            profile_ssid=$(nmcli -g 802-11-wireless.ssid connection show uuid "$conn_uuid" 2>/dev/null)
            
            # If the profile doesn't specify an SSID, skip visibility check
            if [ -n "$profile_ssid" ]; then
                is_visible=false
                for visible in "${VISIBLE_SSIDS[@]}"; do
                    if [ "$visible" = "$profile_ssid" ]; then
                        is_visible=true
                        break
                    fi
                done
                if [ "$is_visible" = false ]; then
                    continue
                fi
            fi
        fi

        echo "Attempting to switch to alternative network: $conn_name..."
        
        if nmcli connection up uuid "$conn_uuid" --wait 15 >/dev/null 2>&1; then
            echo "Connected to $conn_name. Testing connection quality..."
            
            if check_light_ping; then
                echo "Quality confirmed on $conn_name! Resuming normal monitoring."
                notify-send "Network Restored" "Switched to: $conn_name" -u normal
                INTERNET_RESTORED=true
                break 
            else
                echo "$conn_name connected locally, but failed quality checks."
            fi
        else
            echo "Could not connect to $conn_name."
        fi
    done

    # IF ALL ALTERNATIVES FAIL, RAISE ALARM
    if [ "$INTERNET_RESTORED" = false ]; then
        echo "All available connections exhausted or degraded! Raising alarm..."
        notify-send "CRITICAL NETWORK FAILURE" "No usable internet available on any network." -u critical
        
        if command -v paplay >/dev/null 2>&1; then
            paplay /usr/share/sounds/freedesktop/stereo/dialog-warning.oga
        else
            echo -e '\a' 
        fi
    fi
}

# ==========================================
# 6. MAIN MONITORING LOOP
# ==========================================
run_monitor_loop() {
    LOOP_COUNT=1 # Start at 1 to prevent instant heavy check on first launch/after failover

    while true; do
        
        NETWORK_GOOD=true

        # 1. Always run the light ping check
        if ! check_light_ping; then
            NETWORK_GOOD=false
        fi

        # 2. Run the heavy check only if it's time AND the ping check passed
        if [ "$NETWORK_GOOD" = true ] && (( LOOP_COUNT % HEAVY_CHECK_MULTIPLIER == 0 )); then
            if ! check_heavy_bandwidth; then
                NETWORK_GOOD=false
            fi
        fi

        if [ "$NETWORK_GOOD" = true ]; then
            LOOP_COUNT=$((LOOP_COUNT + 1))
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # IF WE REACH HERE, THE NETWORK IS BAD.
        run_failover_protocol

        sleep "$CHECK_INTERVAL"
    done
}

# ==========================================
# 7. EXECUTION ENTRY POINT
# ==========================================
# Execute only if run directly (not sourced by tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_config "$@"
    setup_payload
    run_monitor_loop
fi