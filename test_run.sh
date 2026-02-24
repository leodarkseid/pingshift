#!/bin/bash
# test_run.sh - Comprehensive mock test suite for run.sh
# Mocks system dependencies (ping, curl, nmcli, ip, notify-send) to test logical flows.

# ==========================================
# 0. SETUP & MOCKING FRAMEWORK
# ==========================================
set -e # Exit immediately on unhandled error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="$SCRIPT_DIR/run.sh"

export MOCK_BIN_DIR="$SCRIPT_DIR/mock_bins"
mkdir -p "$MOCK_BIN_DIR"

# Pre-pend mock directory to PATH so our mocks are called instead of real binaries
export PATH="$MOCK_BIN_DIR:$PATH"

# Setup dummy config
export CONFIG_FILE="$SCRIPT_DIR/monitor_dummy_test.conf"
cat << 'EOF' > "$CONFIG_FILE"
CHECK_INTERVAL=1
HEAVY_CHECK_MULTIPLIER=1
MAX_LATENCY=150
MIN_DL_SPEED=1000000 
MIN_UL_SPEED=500000
PING_TARGETS=("1.1.1.1")
DL_TARGETS=("http://dummy.dl")
UL_TARGETS=("http://dummy.ul")
EOF

# Function to clean up mocks
cleanup() {
    rm -rf "$MOCK_BIN_DIR"
    rm -f "$SCRIPT_DIR/monitor_dummy_test.conf"
    rm -f "$SCRIPT_DIR/fake_upload_payload.dat"
    echo -e "\nCleanup complete."
}
trap cleanup EXIT

# Helper to create mock binaries
create_mock() {
    local name="$1"
    local script="$2"
    echo '#!/bin/bash' > "$MOCK_BIN_DIR/$name"
    echo "$script" >> "$MOCK_BIN_DIR/$name"
    chmod +x "$MOCK_BIN_DIR/$name"
}

# Source the refactored run.sh functions!
source "$RUN_SCRIPT"

# Initialize global threshold configs natively since test_run.sh now has the functions in memory
parse_config "$@"

# Create a harmless empty fake payload so the normal bandwidth tests don't permanently skip 'upload' checking
export TMP_UP_FILE="$SCRIPT_DIR/fake_upload_payload.dat"
touch "$TMP_UP_FILE"

# ==========================================
# 1. TEST SUITE
# ==========================================
FAILED_TESTS=0
TOTAL_TESTS=0

run_test() {
    local test_name="$1"
    local expected_result="$2"
    local command_to_run="$3"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    echo -n "Test $TOTAL_TESTS: $test_name ... "
    
    # Run the command
    set +e
    eval "$command_to_run" > /dev/null 2>&1
    local actual_result=$?
    set -e

    if [ "$actual_result" -eq "$expected_result" ]; then
        echo -e "\e[32mPASS\e[0m"
    else
        echo -e "\e[31mFAIL\e[0m (Expected $expected_result, got $actual_result)"
        echo -e "\n  \e[33m[DEBUG OUTPUT]:\e[0m\n  $(echo "$output" | sed 's/^/  /')\n"
        echo -e "--- Output for $test_name ---\n$output\n" >> "$TEST_LOG_FILE"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

# --- SCENARIO 1: Ping Tests ---
# Mock ping to succeed with 50ms latency (Linux / iputils approach)
create_mock "ping" "echo 'rtt min/avg/max/mdev = 40.0/50.0/60.0/10.0 ms'; exit 0"
run_test "check_light_ping (Healthy Ping 50ms - Linux Form)" 0 "check_light_ping"

# Mock ping to succeed with 60ms latency (macOS / FreeBSD / BusyBox approach)
create_mock "ping" "echo 'round-trip min/avg/max/stddev = 50.0/60.0/70.0/5.0 ms'; exit 0"
run_test "check_light_ping (Healthy Ping 60ms - macOS/BSD Form)" 0 "check_light_ping"

# Mock ping to succeed but with 500ms (Above 150ms limit)
create_mock "ping" "echo 'rtt min/avg/max/mdev = 400.0/500.0/600.0/10.0 ms'; exit 0"
run_test "check_light_ping (High Ping 500ms)" 1 "check_light_ping"

# Mock ping entirely failing (Packet Loss/No Route)
create_mock "ping" "exit 1"
run_test "check_light_ping (100% Packet Loss)" 1 "check_light_ping"

# --- SCENARIO 2: Bandwidth Tests ---
# Mock curl to return passing bandwidth (2MB DL, 1MB UL)
create_mock "curl" '
    if [[ "$*" == *speed_download* ]]; then echo 2000000; exit 0; fi
    if [[ "$*" == *speed_upload* ]]; then echo 1000000; exit 0; fi
    exit 1
'
run_test "check_heavy_bandwidth (Fast Speeds)" 0 "check_heavy_bandwidth"

# Mock curl to fail download entirely (0 bytes/s)
create_mock "curl" '
    if [[ "$*" == *speed_download* ]]; then echo 000; exit 0; fi
    if [[ "$*" == *speed_upload* ]]; then echo 1000000; exit 0; fi
    exit 1
'
run_test "check_heavy_bandwidth (Download Failure)" 1 "check_heavy_bandwidth"

# Mock curl to fail upload entirely (0 bytes/s)
create_mock "curl" '
    if [[ "$*" == *speed_download* ]]; then echo 2000000; exit 0; fi
    if [[ "$*" == *speed_upload* ]]; then echo 000; exit 0; fi
    exit 1
'
run_test "check_heavy_bandwidth (Upload Failure)" 1 "check_heavy_bandwidth"

# Mock curl generic failure (timeout/host unresolved)
create_mock "curl" 'exit 6'
run_test "check_heavy_bandwidth (cURL Timeout/DNS Failure)" 1 "check_heavy_bandwidth"

# Mock filesystem missing /dev/shm upload payload (Read-only disk simulation)
# If the payload wasn't generated due to permissions/disk full, check_heavy_bandwidth should
# WARN but still cleanly pass the overall test if downloads are working.
create_mock "curl" '
    if [[ "$*" == *speed_download* ]]; then echo 2000000; exit 0; fi
    # Upload curl should NOT be called if file is missing, but mock it just in case
    if [[ "$*" == *speed_upload* ]]; then echo 1000000; exit 0; fi 
    exit 1
'
run_test_missing_payload() {
    # Simulate missing file by explicitly unsetting/deleting any generated payload variable
    # Inside run_functions_only.sh, TMP_UP_FILE relies on global state
    export TMP_UP_FILE="/tmp/this_file_does_not_exist_for_test.dat"
    rm -f "$TMP_UP_FILE"
    
    output=$(check_heavy_bandwidth)
    result=$?
    
    if echo "$output" | grep -q "Warning: Upload payload could not be created" && [ $result -eq 0 ]; then
        return 0
    else
        return 1
    fi
}
run_test "check_heavy_bandwidth (Missing Upload Payload / Disk Full fallback)" 0 "run_test_missing_payload"



# --- SCENARIO 3: Network Visibility & Failover Logic ---
# The failover logic is now isolated in the `run_failover_protocol` function native to run.sh

echo -e "\n--- Test: Failover Logic (nmcli invisible Wi-Fi skip) ---"

test_hidden_wifi_skip() {
    # 1. Setup mock environment
    create_mock "ip" "echo '8.8.8.8 via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.100 metric 600'; exit 0"
    create_mock "notify-send" "exit 0"
    create_mock "paplay" "exit 0"
    create_mock "ping" "exit 1"
    create_mock "sleep" "exit 0"

    # Mock nmcli: 
    # - We are on "BadCurrentNet"
    # - There is a saved profile "Out_of_range_network"
    # - BUT "Out_of_range_network" does NOT appear in `device wifi list`
    create_mock "nmcli" '
        arg_str="$*"
        if [[ "$arg_str" == *"device disconnect"* ]]; then
            exit 0
        elif [[ "$arg_str" == *"device wifi rescan"* ]]; then
            exit 0
        elif [[ "$arg_str" == *"--active"* ]]; then
            echo "uuid-current-1234:wlan0"
            exit 0
        elif [[ "$arg_str" == *"device wifi list"* ]]; then
            echo "Someone_elses_wifi"
            exit 0
        elif [[ "$arg_str" == *"connection.timestamp"* ]]; then
            echo "1700000000"
            exit 0
        elif [[ "$arg_str" == *"802-11-wireless.ssid"* ]]; then
            echo "Out_of_range_network"
            exit 0
        elif [[ "$arg_str" == *"show"* && "$arg_str" != *"--active"* ]]; then
            echo "uuid-current-1234:802-11-wireless:BadCurrentNet"
            echo "uuid-missing-5678:802-11-wireless:Out_of_range_network"
            exit 0
        elif [[ "$arg_str" == *"up uuid"* ]]; then
            echo "TEST_FAILED_ATTEMPTED_CONNECTION"
            exit 0
        fi
        exit 1
    '

    # Run the failover chunk
    output=$(bash -c "export PATH=\"$MOCK_BIN_DIR:\$PATH\"; source \"$RUN_SCRIPT\"; run_failover_protocol" 2>&1)
    
    # We want to ensure it DOES NOT say "Attempting to switch to alternative network: Out_of_range_network"
    
    if echo "$output" | grep -q "Attempting to switch"; then
        echo "Fail: Script attempted to connect to an invisible network."
        return 1
    elif echo "$output" | grep -q "All available connections exhausted"; then
        # It skipped the invisible network and properly exhausted options
        return 0
    else
        echo "Fail: Unexpected output: $output"
        return 1
    fi
}

run_test "Skip Invisible Connections (Ignores Out-of-Range Wi-Fi)" 0 "test_hidden_wifi_skip"


test_escaped_colon_parsing() {
    # 1. Setup mock environment
    create_mock "ip" "echo '8.8.8.8 via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.100 metric 600'; exit 0"
    create_mock "notify-send" "exit 0"
    create_mock "paplay" "exit 0"
    create_mock "ping" "exit 1"
    create_mock "sleep" "exit 0"

    # Mock nmcli: 
    # - We are on "BadCurrentNet"
    # - There is a saved profile "Hack:My:Wi-Fi" (which outputs as Hack\:My\:Wi-Fi normally, but with -g it's raw)
    # - It is visible
    create_mock "nmcli" '
        arg_str="$*"
        if [[ "$arg_str" == *"device disconnect"* ]]; then
            exit 0
        elif [[ "$arg_str" == *"device wifi rescan"* ]]; then
            exit 0
        elif [[ "$arg_str" == *"--active"* ]]; then
            echo "uuid-current-1234:wlan0"
            exit 0
        elif [[ "$arg_str" == *"device wifi list"* ]]; then
            echo "Hack:My:Wi-Fi"
            exit 0
        elif [[ "$arg_str" == *"connection.timestamp"* ]]; then
            echo "1700000000"
            exit 0
        elif [[ "$arg_str" == *"802-11-wireless.ssid"* ]]; then
            echo "Hack:My:Wi-Fi"
            exit 0
        elif [[ "$arg_str" == *"show"* && "$arg_str" != *"--active"* ]]; then
            echo "uuid-current-1234:802-11-wireless:BadCurrentNet"
            echo "uuid-hacked-5678:802-11-wireless:Hack:My:Wi-Fi"
            exit 0
        elif [[ "$arg_str" == *"up uuid"* ]]; then
            # If the script calls this on the hacked network, it successfully parsed the UUID despite the colons in the name
            if [[ "$arg_str" == *"uuid-hacked-5678"* ]]; then
                echo "SUCCESSFULLY_SWITCHED"
                exit 0
            fi
        fi
        exit 1
    '

    # Run the failover chunk
    output=$(bash -c "export PATH=\"$MOCK_BIN_DIR:\$PATH\"; source \"$RUN_SCRIPT\"; run_failover_protocol" 2>&1)
    
    if echo "$output" | grep -q "Attempting to switch to alternative network: Hack:My:Wi-Fi"; then
        return 0
    else
        echo "Fail: Script failed to parse network name with colons. Output: $output"
        return 1
    fi
}
run_test "Parse Network Names with Colons (Handles escaped delimiters)" 0 "test_escaped_colon_parsing"


test_failover_fallback() {
    # 1. Setup mock environment
    # Mock `ip route get` to return failure (empty output)
    create_mock "ip" "exit 1"
    create_mock "notify-send" "exit 0"
    create_mock "paplay" "exit 0"
    create_mock "ping" "exit 1"
    create_mock "sleep" "exit 0"

    # Mock nmcli: 
    # Current UUID should be fetched via the fallback type-based grep instead of DEVICE.
    create_mock "nmcli" '
        arg_str="$*"
        if [[ "$arg_str" == *"device disconnect"* ]]; then
            exit 0
        elif [[ "$arg_str" == *"device wifi rescan"* ]]; then
            exit 0
        elif [[ "$arg_str" == *"device status"* ]]; then
            echo "wlan0:wifi"
            exit 0
        elif [[ "$arg_str" == *"--active"* ]]; then
            echo "uuid-fallback-1234:802-11-wireless"
            exit 0
        elif [[ "$arg_str" == *"device wifi list"* ]]; then
            echo "BackupNet"
            exit 0
        elif [[ "$arg_str" == *"connection.timestamp"* ]]; then
            echo "1700000000"
            exit 0
        elif [[ "$arg_str" == *"802-11-wireless.ssid"* ]]; then
            echo "BackupNet"
            exit 0
        elif [[ "$arg_str" == *"show"* && "$arg_str" != *"--active"* ]]; then
            echo "uuid-fallback-1234:802-11-wireless:BadCurrentNet"
            echo "uuid-backup-5678:802-11-wireless:BackupNet"
            exit 0
        elif [[ "$arg_str" == *"up uuid"* ]]; then
            echo "SUCCESSFULLY_SWITCHED_VIA_FALLBACK"
            exit 0
        fi
        exit 1
    '

    # Run the failover chunk
    output=$(bash -c "export PATH=\"$MOCK_BIN_DIR:\$PATH\"; source \"$RUN_SCRIPT\"; run_failover_protocol" 2>&1)
    
    if echo "$output" | grep -q "Attempting to switch to alternative network: BackupNet"; then
        return 0
    else
        echo "Fail: Script did not correctly use the fallback interface detection logic. Output: $output"
        return 1
    fi
}
run_test "Failover (Fallback active interface detection logic)" 0 "test_failover_fallback"


test_loop_reset() {
    # 3. Test loop counter logic reset
    # Start loop count high to simulate the script has been running for days
    # After a failover event triggers, it MUST hit the LOOP_COUNT=1 reset statement
    create_mock "sleep" "exit 0"
    output=$(bash -c "
        export PATH=\"$MOCK_BIN_DIR:\$PATH\"
        source \"$RUN_SCRIPT\"
        
        LOOP_COUNT=9999
        run_failover_protocol >/dev/null 2>&1
        echo \"NEW_LOOP_COUNT=\$LOOP_COUNT\"
    " 2>&1)
    
    if echo "$output" | grep -q "NEW_LOOP_COUNT=1"; then
        return 0
    else
        echo "Fail: LOOP_COUNT was not reset to 1!"
        return 1
    fi
}

run_test "Failover (Correctly resets LOOP_COUNT to 1 to prevent flapping)" 0 "test_loop_reset"


test_disconnect_before_switch() {
    # Validates that the script disconnects the adapter BEFORE attempting connection up.
    # The mock logs the order of operations to a temp file.
    local ORDER_LOG="/tmp/nmcli_order_test_$$"
    rm -f "$ORDER_LOG"

    create_mock "ip" "echo '8.8.8.8 via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.100 metric 600'; exit 0"
    create_mock "notify-send" "exit 0"
    create_mock "paplay" "exit 0"
    create_mock "ping" "exit 1"
    create_mock "sleep" "exit 0"

    create_mock "nmcli" '
        arg_str="$*"
        ORDER_LOG="'"$ORDER_LOG"'"
        if [[ "$arg_str" == *"device disconnect"* ]]; then
            echo "DISCONNECT" >> "$ORDER_LOG"
            exit 0
        elif [[ "$arg_str" == *"device wifi rescan"* ]]; then
            echo "RESCAN" >> "$ORDER_LOG"
            exit 0
        elif [[ "$arg_str" == *"--active"* ]]; then
            echo "uuid-current-1234:wlan0"
            exit 0
        elif [[ "$arg_str" == *"device wifi list"* ]]; then
            echo "BackupNet"
            exit 0
        elif [[ "$arg_str" == *"connection.timestamp"* ]]; then
            echo "1700000000"
            exit 0
        elif [[ "$arg_str" == *"802-11-wireless.ssid"* ]]; then
            echo "BackupNet"
            exit 0
        elif [[ "$arg_str" == *"show"* && "$arg_str" != *"--active"* ]]; then
            echo "uuid-current-1234:802-11-wireless:BadCurrentNet"
            echo "uuid-backup-5678:802-11-wireless:BackupNet"
            exit 0
        elif [[ "$arg_str" == *"up uuid"* ]]; then
            echo "CONNECT_UP" >> "$ORDER_LOG"
            exit 0
        fi
        exit 1
    '

    # Run the failover
    bash -c "export PATH=\"$MOCK_BIN_DIR:\$PATH\"; source \"$RUN_SCRIPT\"; run_failover_protocol" >/dev/null 2>&1

    # Verify order: DISCONNECT must appear before CONNECT_UP
    local failed=0
    if [ ! -f "$ORDER_LOG" ]; then
        echo "Fail: No operations were logged."
        failed=1
    else
        local first_disconnect=$(grep -n "DISCONNECT" "$ORDER_LOG" | head -n1 | cut -d: -f1)
        local first_connect=$(grep -n "CONNECT_UP" "$ORDER_LOG" | head -n1 | cut -d: -f1)
        local has_rescan=$(grep -c "RESCAN" "$ORDER_LOG")

        if [ -z "$first_disconnect" ]; then
            echo "Fail: DISCONNECT was never called."
            failed=1
        elif [ -z "$first_connect" ]; then
            echo "Fail: CONNECT_UP was never called."
            failed=1
        elif [ "$first_disconnect" -ge "$first_connect" ]; then
            echo "Fail: DISCONNECT happened after CONNECT_UP (wrong order)."
            failed=1
        fi

        if [ "$has_rescan" -eq 0 ]; then
            echo "Fail: RESCAN was never called."
            failed=1
        fi
    fi

    rm -f "$ORDER_LOG"
    return $failed
}

run_test "Failover (Disconnects adapter before switching to new network)" 0 "test_disconnect_before_switch"


test_skip_never_connected() {
    # Validates that connections with timestamp=0 (never connected) are skipped.
    create_mock "ip" "echo '8.8.8.8 via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.100 metric 600'; exit 0"
    create_mock "notify-send" "exit 0"
    create_mock "paplay" "exit 0"
    create_mock "ping" "exit 1"
    create_mock "sleep" "exit 0"

    create_mock "nmcli" '
        arg_str="$*"
        if [[ "$arg_str" == *"device disconnect"* ]]; then
            exit 0
        elif [[ "$arg_str" == *"device wifi rescan"* ]]; then
            exit 0
        elif [[ "$arg_str" == *"--active"* ]]; then
            echo "uuid-current-1234:wlan0"
            exit 0
        elif [[ "$arg_str" == *"device wifi list"* ]]; then
            echo "NeverUsedNet"
            echo "PreviouslyUsedNet"
            exit 0
        elif [[ "$arg_str" == *"connection.timestamp"* ]]; then
            # NeverUsedNet has timestamp=0, PreviouslyUsedNet has a real timestamp
            if [[ "$arg_str" == *"uuid-never-1111"* ]]; then
                echo "0"
            else
                echo "1700000000"
            fi
            exit 0
        elif [[ "$arg_str" == *"802-11-wireless.ssid"* ]]; then
            if [[ "$arg_str" == *"uuid-never-1111"* ]]; then
                echo "NeverUsedNet"
            else
                echo "PreviouslyUsedNet"
            fi
            exit 0
        elif [[ "$arg_str" == *"show"* && "$arg_str" != *"--active"* ]]; then
            echo "uuid-current-1234:802-11-wireless:CurrentNet"
            echo "uuid-never-1111:802-11-wireless:NeverUsedNet"
            echo "uuid-used-2222:802-11-wireless:PreviouslyUsedNet"
            exit 0
        elif [[ "$arg_str" == *"up uuid"* ]]; then
            exit 0
        fi
        exit 1
    '

    output=$(bash -c "export PATH=\"$MOCK_BIN_DIR:\$PATH\"; source \"$RUN_SCRIPT\"; run_failover_protocol" 2>&1)

    local failed=0
    # Should NOT attempt NeverUsedNet
    if echo "$output" | grep -q "NeverUsedNet"; then
        echo "Fail: Script attempted to connect to a never-connected network."
        failed=1
    fi
    # SHOULD attempt PreviouslyUsedNet
    if ! echo "$output" | grep -q "PreviouslyUsedNet"; then
        echo "Fail: Script did not attempt the previously-connected network."
        failed=1
    fi
    return $failed
}

run_test "Skip Never-Connected Networks (Filters by connection.timestamp)" 0 "test_skip_never_connected"

# --- SCENARIO 4.5: Notification Toggle ---
echo -e "\n--- Test: Notification Toggle (ENABLE_NOTIFICATIONS) ---"

test_notifications_disabled() {
    # When ENABLE_NOTIFICATIONS=false, send_alert should NOT call notify-send or zenity
    create_mock "notify-send" 'echo "NOTIFY_SEND_WAS_CALLED"; exit 0'
    create_mock "zenity" 'echo "ZENITY_WAS_CALLED"; exit 0'

    output=$(bash -c "
        source \"$RUN_SCRIPT\"
        ENABLE_NOTIFICATIONS=false
        send_alert 'Test Title' 'Test Message' 'critical'
    " 2>&1)

    local failed=0
    # Should still log to stdout
    if ! echo "$output" | grep -q "\[Alert/critical\] Test Title: Test Message"; then
        echo "Fail: Alert was not logged to stdout."
        failed=1
    fi
    # Should NOT call notify-send or zenity
    if echo "$output" | grep -q "NOTIFY_SEND_WAS_CALLED"; then
        echo "Fail: notify-send was called despite ENABLE_NOTIFICATIONS=false."
        failed=1
    fi
    if echo "$output" | grep -q "ZENITY_WAS_CALLED"; then
        echo "Fail: zenity was called despite ENABLE_NOTIFICATIONS=false."
        failed=1
    fi
    return $failed
}

run_test "Notifications Disabled (Suppresses notify-send/zenity, still logs)" 0 "test_notifications_disabled"

test_notifications_enabled() {
    # When ENABLE_NOTIFICATIONS=true, send_alert SHOULD call notify-send
    create_mock "notify-send" 'echo "NOTIFY_SEND_WAS_CALLED"; exit 0'

    output=$(bash -c "
        export PATH=\"$MOCK_BIN_DIR:\$PATH\"
        source \"$RUN_SCRIPT\"
        ENABLE_NOTIFICATIONS=true
        send_alert 'Test Title' 'Test Message' 'normal'
    " 2>&1)

    local failed=0
    # Should log to stdout
    if ! echo "$output" | grep -q "\[Alert/normal\] Test Title: Test Message"; then
        echo "Fail: Alert was not logged to stdout."
        failed=1
    fi
    # SHOULD call notify-send
    if ! echo "$output" | grep -q "NOTIFY_SEND_WAS_CALLED"; then
        echo "Fail: notify-send was NOT called despite ENABLE_NOTIFICATIONS=true."
        failed=1
    fi
    return $failed
}

run_test "Notifications Enabled (Fires notify-send and logs)" 0 "test_notifications_enabled"

# --- SCENARIO 5: Regex Numeric Validation (is_numeric) ---
echo -e "\n--- Test: Regex Numeric Validation ---"

# Mock ping to return alphabetic characters where the number should be
# awk isolates the string after the =, then cuts by / to extract the average latency.
create_mock "ping" "echo 'rtt min/avg/max/mdev = a/InvalidText/c/d ms'; exit 0"
# In bash, checking if "InvalidText" <= 150 crashes the script with "integer expression expected".
# It must fail cleanly via our is_numeric regex logic.
run_test "check_light_ping (Rejects garbage string 'InvalidText' as Latency)" 1 "check_light_ping"

# Mock curl to output alphabets mixed with numbers like "2000kbps" or empty strings
create_mock "curl" '
    if [[ "$*" == *speed_download* ]]; then echo "2000kbps"; exit 0; fi
    if [[ "$*" == *speed_upload* ]]; then echo ""; exit 0; fi
    exit 1
'
run_test "check_heavy_bandwidth (Rejects non-numeric alphabets and empty variables)" 1 "check_heavy_bandwidth"

# --- SCENARIO 5: Config Parsing Security & Regex ---
echo -e "\n--- Test: Config Parsing Security & Regex ---"

test_config_parser() {
    # 1. Create a complex monitor.conf
    # - Has comments, inline comments, array with spaces, valid scalar, and a fake malicious attempt
    cat << 'EOF' > "$SCRIPT_DIR/monitor_test.conf"
# This is a full comment line
VALID_VAR=100
MY_ARRAY=( "value 1" "value 2" )
VAR_WITH_COMMENT=500     # This is an inline comment
MALICIOUS_VAR=10; cat /etc/passwd
EOF

    # 2. Source the parsing block in a clean subshell and evaluate the results
    output=$(bash -c "
        source \"$RUN_SCRIPT\"
        CONFIG_FILE=\"$SCRIPT_DIR/monitor_test.conf\"
        parse_config --interval 30 --interval fast --latency 250 --latency slow --heavy-loops 5 --heavy-loops invalid >/dev/null 2>&1
        
        # Output results for the test to grep
        echo \"VALID_VAR=\$VALID_VAR\"
        echo \"MY_ARRAY_0=\${MY_ARRAY[0]}\"
        echo \"MY_ARRAY_1=\${MY_ARRAY[1]}\"
        echo \"VAR_WITH_COMMENT=\$VAR_WITH_COMMENT\"
        echo \"MALICIOUS_VAR=\$MALICIOUS_VAR\"
        echo \"CHECK_INTERVAL=\$CHECK_INTERVAL\"
        echo \"MAX_LATENCY=\$MAX_LATENCY\"
        echo \"HEAVY_CHECK_MULTIPLIER=\$HEAVY_CHECK_MULTIPLIER\"
    " 2>&1)
    
    # Clean up test files
    rm -f "$SCRIPT_DIR/monitor_test.conf"

    # 4. Assertions
    local failed=0
    
    if ! echo "$output" | grep -q "VALID_VAR=100"; then echo "Fail: VALID_VAR missing"; failed=1; fi
    if ! echo "$output" | grep -q 'MY_ARRAY_0=value 1'; then echo "Fail: Array parsing broke on spaces"; failed=1; fi
    if ! echo "$output" | grep -q "VAR_WITH_COMMENT=500"; then echo "Fail: Inline comment broke line parser"; failed=1; fi
    if echo "$output" | grep -q "MALICIOUS_VAR=10"; then 
        echo "Fail: Malicious injection was permitted!"; failed=1; 
    fi
    if ! echo "$output" | grep -q "CHECK_INTERVAL=30"; then echo "Fail: CLI flag --interval missing/broken or accepted invalid string"; failed=1; fi
    if ! echo "$output" | grep -q "MAX_LATENCY=250"; then echo "Fail: CLI flag --latency missing/broken or accepted invalid string"; failed=1; fi
    if ! echo "$output" | grep -q "HEAVY_CHECK_MULTIPLIER=5"; then echo "Fail: CLI flag --heavy-loops missing/broken or accepted invalid string"; failed=1; fi

    return $failed
}
run_test "Config Parse (Array spaces, Inline comments, CLI Flag overrides & rejects invalid strings, Rejects malicious lines)" 0 "test_config_parser"

# --- SCENARIO 6: Main Daemon Loop Execution ---
echo -e "\n--- Test: Main Daemon Loop Execution ---"

test_monitor_loop() {
    # We must test run_monitor_loop, which is an infinite `while true` loop.
    # To prevent hanging the test suite, we mock `sleep` to exit the subshell after the first iteration!
    
    output=$(bash -c "
        export PATH=\"$MOCK_BIN_DIR:\$PATH\"
        source \"$RUN_SCRIPT\"
        
        # Override the check functions to just echo what they do
        check_light_ping() {
            echo \"MOCK_LIGHT_PING_CALLED\"
            return 0
        }
        check_heavy_bandwidth() {
            echo \"MOCK_HEAVY_BANDWIDTH_CALLED\"
            return 0
        }
        run_failover_protocol() {
            echo \"MOCK_FAILOVER_CALLED\"
        }
        
        # Override sleep to exit exactly when it hits the end of the first loop iteration
        sleep() {
            echo \"MOCK_SLEEP_CALLED\"
            exit 0
        }
        
        # Start conditions: Heavy check multiplier is 1 so it runs immediately
        HEAVY_CHECK_MULTIPLIER=1
        
        run_monitor_loop
    " 2>&1)
    
    local failed=0
    # It should have called the light ping
    if ! echo "$output" | grep -q "MOCK_LIGHT_PING_CALLED"; then echo "Fail: Light ping wasn't called in the main loop."; failed=1; fi
    
    # It should have called the heavy bandwidth because multiplier is 1
    if ! echo "$output" | grep -q "MOCK_HEAVY_BANDWIDTH_CALLED"; then echo "Fail: Heavy bandwidth wasn't called in the main loop."; failed=1; fi
    
    # It should have reached the sleep and cleanly exited
    if ! echo "$output" | grep -q "MOCK_SLEEP_CALLED"; then echo "Fail: The sleep interval wasn't executed or the loop crashed early."; failed=1; fi
    
    return $failed
}

run_test "Main Loop (Executes light ping and heavy bandwidth correctly)" 0 "test_monitor_loop"

test_monitor_loop_sad_path() {
    output=$(bash -c "
        export PATH=\"$MOCK_BIN_DIR:\$PATH\"
        source \"$RUN_SCRIPT\"
        
        # Override the check functions to simulate failure
        check_light_ping() {
            echo \"MOCK_LIGHT_PING_FAILED\"
            return 1
        }
        check_heavy_bandwidth() {
            echo \"MOCK_HEAVY_BANDWIDTH_CALLED_ERRONEOUSLY\"
            return 0
        }
        run_failover_protocol() {
            echo \"MOCK_FAILOVER_CALLED\"
        }
        
        # Override sleep to exit after first loop
        sleep() {
            echo \"MOCK_SLEEP_CALLED\"
            exit 0
        }
        
        HEAVY_CHECK_MULTIPLIER=1
        
        run_monitor_loop
    " 2>&1)
    
    local failed=0
    # Ping should be called and fail
    if ! echo "$output" | grep -q "MOCK_LIGHT_PING_FAILED"; then echo "Fail: Light ping wasn't called."; failed=1; fi
    
    # Heavy bandwidth MUST NOT be called because ping failed
    if echo "$output" | grep -q "MOCK_HEAVY_BANDWIDTH_CALLED_ERRONEOUSLY"; then echo "Fail: Heavy bandwidth was called despite ping failure."; failed=1; fi
    
    # Failover MUST be triggered
    if ! echo "$output" | grep -q "MOCK_FAILOVER_CALLED"; then echo "Fail: Failover wasn't triggered upon ping failure."; failed=1; fi
    
    # Sleep should be executed at the end of the loop
    if ! echo "$output" | grep -q "MOCK_SLEEP_CALLED"; then echo "Fail: The sleep interval wasn't executed or the loop crashed early."; failed=1; fi
    
    return $failed
}

run_test "Main Loop (Sad Path: Triggers failover and skips bandwidth on ping failure)" 0 "test_monitor_loop_sad_path"

# --- SCENARIO 7: Setup Payload & Initialization ---
echo -e "\n--- Test: Setup Payload Initialization ---"

test_setup_payload_creation() {
    # 1. Clean environment
    rm -f "/dev/shm/net_monitor_up_payload.dat"
    rm -f "/tmp/net_monitor_up_payload.dat"
    
    output=$(bash -c "
        export PATH=\"$MOCK_BIN_DIR:\$PATH\"
        source \"$RUN_SCRIPT\"
        
        # Mock head to prevent actual 1MB write (bash redirection still creates the empty file lock)
        echo '#!/bin/bash' > \"$MOCK_BIN_DIR/head\"
        echo 'exit 0' >> \"$MOCK_BIN_DIR/head\"
        chmod +x \"$MOCK_BIN_DIR/head\"
        
        CHECK_INTERVAL=10
        HEAVY_CHECK_MULTIPLIER=3
        
        setup_payload
    " 2>&1)
    
    local failed=0
    
    # Check output strings
    if ! echo "$output" | grep -q "Starting Robust Network Monitor..."; then echo "Fail: Missing startup string."; failed=1; fi
    if ! echo "$output" | grep -q "Ping: Every 10s | Bandwidth: Every 30s"; then echo "Fail: Math for bandwidth interval is wrong."; failed=1; fi
    
    # Check file creation (prefer /dev/shm if it exists normally, else /tmp)
    if [ -d "/dev/shm" ]; then
        if [ ! -f "/dev/shm/net_monitor_up_payload.dat" ]; then
            echo "Fail: Payload not created in /dev/shm when the dir exists."
            failed=1
        fi
    else
        if [ ! -f "/tmp/net_monitor_up_payload.dat" ]; then
            echo "Fail: Payload not created in /tmp fallback."
            failed=1
        fi
    fi
    
    # Cleanup
    rm -f "/dev/shm/net_monitor_up_payload.dat"
    rm -f "/tmp/net_monitor_up_payload.dat"
    
    return $failed
}

run_test "Payload Setup (Creates file in memory/tmp and prints config)" 0 "test_setup_payload_creation"


# --- SCENARIO 8: Mock Environment Isolation ---
echo -e "\n--- Test: Mock Environment Isolation ---"

test_payload_isolation() {
    # Delete any existing files that might have been created by the user running the real script
    rm -f "/dev/shm/net_monitor_up_payload.dat"
    rm -f "/tmp/net_monitor_up_payload.dat"
    
    # Re-trigger the exact extraction logic we use in the test suite
    # By simply sourcing the file and checking that the initialization doesn't execute
    source "$RUN_SCRIPT"
    
    # Check if the file was created (if so, our disk write isolation failed)
    local failed=0
    if [ -f "/dev/shm/net_monitor_up_payload.dat" ] || [ -f "/tmp/net_monitor_up_payload.dat" ]; then
        failed=1
    fi
    return $failed
}

run_test "Environment Isolation (Prevents 1MB disk writes during test suite)" 0 "test_payload_isolation"

# ==========================================
# 2. EXIT STATUS
# ==========================================
if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "\n\e[32mALL $TOTAL_TESTS TESTS PASSED SUCCESSFULLY.\e[0m"
    exit 0
else
    echo -e "\n\e[31m$FAILED_TESTS OUT OF $TOTAL_TESTS TESTS FAILED.\e[0m"
    exit 1
fi

