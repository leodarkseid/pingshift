#!/bin/bash

# ==========================================
# 1. DEFAULT CONFIGURATION
# ==========================================
TARGET_IP="1.1.1.1"
CHECK_INTERVAL=15
MAX_LATENCY=150
MIN_DL_SPEED=1000000 
MIN_UL_SPEED=500000
CONFIG_FILE="monitor.conf"

# ==========================================
# 2. PARSE CONFIG FILE & ARGUMENTS
# ==========================================
# Load config file if it exists
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Override with any command-line arguments provided
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ip) TARGET_IP="$2"; shift ;;
        --interval) CHECK_INTERVAL="$2"; shift ;;
        --latency) MAX_LATENCY="$2"; shift ;;
        --dl) MIN_DL_SPEED="$2"; shift ;;
        --ul) MIN_UL_SPEED="$2"; shift ;;
        --config) 
            if [ -f "$2" ]; then source "$2"; fi
            shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

echo "Starting Network Monitor..."
echo "Target: $TARGET_IP | Interval: ${CHECK_INTERVAL}s | Max Lat: ${MAX_LATENCY}ms | Min DL: ${MIN_DL_SPEED}B/s | Min UL: ${MIN_UL_SPEED}B/s"
echo "Press Ctrl+C to stop."

# ==========================================
# 3. NETWORK QUALITY FUNCTION
# ==========================================
check_network_quality() {
    # STAGE 1: FAST PING (Is it alive?)
    # We grab the average latency directly from the ping command
    ping_stats=$(ping -c 3 -W 2 -q "$TARGET_IP" 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "Failure: Network is completely unreachable."
        return 1
    fi

    # Check Latency against threshold
    avg_lat=$(echo "$ping_stats" | awk -F'/' '/^rtt/ {print $5}' | cut -d. -f1)
    if [ -z "$avg_lat" ] || [ "$avg_lat" -gt "$MAX_LATENCY" ]; then
        echo "Quality Failure: Latency is ${avg_lat}ms (Limit: ${MAX_LATENCY}ms)."
        return 1
    fi

    # STAGE 2: BANDWIDTH QUALITY (Is it fast enough?)
    # Download Test: Fetch 1MB of garbage data, max 5 seconds wait
    dl_speed=$(curl -s -m 5 -w "%{speed_download}" -o /dev/null "http://speedtest.tele2.net/1MB.zip" | cut -d. -f1)
    dl_speed=${dl_speed:-0} # Default to 0 if empty
    
    if [ "$dl_speed" -lt "$MIN_DL_SPEED" ]; then
        echo "Quality Failure: Download speed too slow (${dl_speed} B/s)."
        return 1
    fi

    # Upload Test: Create a temporary 512KB file and upload it to a test sink
    head -c 512K </dev/urandom > /tmp/net_test_up.dat 2>/dev/null
    ul_speed=$(curl -s -m 5 -w "%{speed_upload}" -o /dev/null -F "file=@/tmp/net_test_up.dat" "https://httpbin.org/post" | cut -d. -f1)
    ul_speed=${ul_speed:-0}
    rm -f /tmp/net_test_up.dat # cleanup
    
    if [ "$ul_speed" -lt "$MIN_UL_SPEED" ]; then
        echo "Quality Failure: Upload speed too slow (${ul_speed} B/s)."
        return 1
    fi

    # If it passes all tests
    return 0
}

# ==========================================
# 4. MAIN MONITORING LOOP
# ==========================================
while true; do
    
    if check_network_quality; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # IF WE REACH HERE, THE NETWORK FAILED PING OR QUALITY CHECKS
    echo "Network issue detected! Initiating failover protocol..."
    
    CURRENT_UUID=$(nmcli -t -f UUID,TYPE connection show --active | grep -E '802-11-wireless|802-3-ethernet' | cut -d: -f1 | head -n 1)
    mapfile -t ALL_CONNS < <(nmcli -t -f UUID,NAME,TYPE connection show | grep -E '802-11-wireless|802-3-ethernet')

    INTERNET_RESTORED=false

    for entry in "${ALL_CONNS[@]}"; do
        conn_uuid=$(echo "$entry" | cut -d: -f1)
        conn_name=$(echo "$entry" | cut -d: -f2- | rev | cut -d: -f2- | rev)

        if [ -z "$conn_uuid" ] || [ "$conn_uuid" = "$CURRENT_UUID" ]; then
            continue
        fi

        echo "Attempting to switch to alternative network: $conn_name..."
        
        if nmcli connection up uuid "$conn_uuid" --wait 15 >/dev/null 2>&1; then
            echo "Connected to $conn_name. Testing connection quality..."
            
            # Use the exact same rigorous quality test on the new network
            if check_network_quality; then
                echo "Quality confirmed on $conn_name! Resuming normal monitoring."
                notify-send "Network Restored" "Switched to high-quality network: $conn_name" -u normal
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
        notify-send "CRITICAL NETWORK FAILURE" "No high-quality internet available on any network." -u critical
        
        if command -v paplay >/dev/null 2>&1; then
            paplay /usr/share/sounds/freedesktop/stereo/dialog-warning.oga
        else
            echo -e '\a' 
        fi
    fi

    sleep "$CHECK_INTERVAL"
done