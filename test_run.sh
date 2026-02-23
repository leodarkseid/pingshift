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
cat << 'EOF' > "$SCRIPT_DIR/monitor.conf"
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
    rm -f "$SCRIPT_DIR/monitor.conf"
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

# Source the functions from run.sh WITHOUT running the infinite loop.
# We do this by modifying the copy in memory before sourcing it.
# We also strip the 1MB payload creation to prevent real disk writes during tests.
sed '/^while true; do/,$d' "$RUN_SCRIPT" | sed 's|head -c 1M.*|true|' > "$SCRIPT_DIR/run_functions_only.sh"
source "$SCRIPT_DIR/run_functions_only.sh"
rm -f "$SCRIPT_DIR/run_functions_only.sh"

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
# To test the failover section without infinite loops, we extract just that chunk.
sed -n '/# IF WE REACH HERE, THE NETWORK IS BAD./,/sleep "$CHECK_INTERVAL"/p' "$RUN_SCRIPT" | sed '/sleep "$CHECK_INTERVAL"/d' > "$SCRIPT_DIR/failover_chunk.sh"

# Note: run_functions_only.sh was deleted earlier. We must recreate it for this test.
# We also dynamically strip the 1MB payload creation to prevent disk writes on the actual host during testing.
sed '/^while true; do/,$d' "$RUN_SCRIPT" | sed 's|head -c 1M.*|true|' > "$SCRIPT_DIR/run_functions_only.sh"

echo -e "\n--- Test: Failover Logic (nmcli invisible Wi-Fi skip) ---"

test_hidden_wifi_skip() {
    # 1. Setup mock environment
    create_mock "ip" "echo '8.8.8.8 via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.100 metric 600'; exit 0"
    create_mock "notify-send" "exit 0"
    create_mock "paplay" "exit 0"
    create_mock "ping" "exit 1"

    # Mock nmcli: 
    # - We are on "BadCurrentNet"
    # - There is a saved profile "Out_of_range_network"
    # - BUT "Out_of_range_network" does NOT appear in `device wifi list`
    create_mock "nmcli" '
        arg_str="$*"
        if [[ "$arg_str" == *"--active"* ]]; then
            echo "uuid-current-1234:wlan0"
            exit 0
        elif [[ "$arg_str" == *"device wifi list"* ]]; then
            # Visible Networks List (Out of range network is NOT here)
            echo "Someone_elses_wifi"
            exit 0
        elif [[ "$arg_str" == *"802-11-wireless.ssid"* ]]; then
            echo "Out_of_range_network"
            exit 0
        elif [[ "$arg_str" == *"show"* && "$arg_str" != *"--active"* ]]; then
            echo "uuid-current-1234:BadCurrentNet:802-11-wireless"
            echo "uuid-missing-5678:Out_of_range_network:802-11-wireless"
            exit 0
        elif [[ "$arg_str" == *"up uuid"* ]]; then
            # If the script calls this on the missing network, it FAILED the visibility skip test
            echo "TEST_FAILED_ATTEMPTED_CONNECTION"
            exit 0
        fi
        exit 1
    '

    # Run the failover chunk
    output=$(bash -c "export PATH=\"$MOCK_BIN_DIR:\$PATH\"; source \"$SCRIPT_DIR/run_functions_only.sh\"; source \"$SCRIPT_DIR/failover_chunk.sh\"" 2>&1)
    
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

    # Mock nmcli: 
    # - We are on "BadCurrentNet"
    # - There is a saved profile "Hack:My:Wi-Fi" (which outputs as Hack\:My\:Wi-Fi normally, but with -g it's raw)
    # - It is visible
    create_mock "nmcli" '
        arg_str="$*"
        if [[ "$arg_str" == *"--active"* ]]; then
            echo "uuid-current-1234:wlan0"
            exit 0
        elif [[ "$arg_str" == *"device wifi list"* ]]; then
            echo "Hack:My:Wi-Fi"
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
    output=$(bash -c "export PATH=\"$MOCK_BIN_DIR:\$PATH\"; source \"$SCRIPT_DIR/run_functions_only.sh\"; source \"$SCRIPT_DIR/failover_chunk.sh\"" 2>&1)
    
    if echo "$output" | grep -q "Attempting to switch to alternative network: Hack:My:Wi-Fi"; then
        return 0
    else
        echo "Fail: Script failed to parse network name with colons. Output: $output"
        return 1
    fi
}
run_test "Parse Network Names with Colons (Handles escaped delimiters)" 0 "test_escaped_colon_parsing"


test_loop_reset() {
    # 3. Test loop counter logic reset
    # Start loop count high to simulate the script has been running for days
    # After a failover event triggers, it MUST hit the LOOP_COUNT=1 reset statement
    output=$(bash -c "
        export PATH=\"$MOCK_BIN_DIR:\$PATH\"
        source \"$SCRIPT_DIR/run_functions_only.sh\"
        
        LOOP_COUNT=9999
        source \"$SCRIPT_DIR/failover_chunk.sh\" >/dev/null 2>&1
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

# Clean up the temp execution files
rm -f "$SCRIPT_DIR/failover_chunk.sh"
rm -f "$SCRIPT_DIR/run_functions_only.sh"

# --- SCENARIO 4: Regex Numeric Validation (is_numeric) ---
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

    # 2. Extract just the config parsing logic from run.sh
    # We replace CONFIG_FILE with our test file mapping
    sed -n '/# 2. PARSE CONFIG & SETUP/,/^# Command line overrides/p' "$RUN_SCRIPT" | \
    sed 's|^if \[ -f "$CONFIG_FILE" \]; then|CONFIG_FILE="'"$SCRIPT_DIR"'/monitor_test.conf"; if [ -f "$CONFIG_FILE" ]; then|' > "$SCRIPT_DIR/parse_chunk.sh"

    # 3. Source the parsing block in a clean subshell and evaluate the results
    output=$(bash -c "
        source \"$SCRIPT_DIR/parse_chunk.sh\" >/dev/null 2>&1
        
        # Output results for the test to grep
        echo \"VALID_VAR=\$VALID_VAR\"
        echo \"MY_ARRAY_0=\${MY_ARRAY[0]}\"
        echo \"MY_ARRAY_1=\${MY_ARRAY[1]}\"
        echo \"VAR_WITH_COMMENT=\$VAR_WITH_COMMENT\"
        echo \"MALICIOUS_VAR=\$MALICIOUS_VAR\"
    " 2>&1)
    
    # Clean up test files
    rm -f "$SCRIPT_DIR/monitor_test.conf"
    rm -f "$SCRIPT_DIR/parse_chunk.sh"

    # 4. Assertions
    local failed=0
    
    if ! echo "$output" | grep -q "VALID_VAR=100"; then echo "Fail: VALID_VAR missing"; failed=1; fi
    if ! echo "$output" | grep -q 'MY_ARRAY_0=value 1'; then echo "Fail: Array parsing broke on spaces"; failed=1; fi
    if ! echo "$output" | grep -q "VAR_WITH_COMMENT=500"; then echo "Fail: Inline comment broke line parser"; failed=1; fi
    if echo "$output" | grep -q "MALICIOUS_VAR=10"; then 
        echo "Fail: Malicious injection was permitted!"; failed=1; 
    fi

    return $failed
}
run_test "Config Parse (Array spaces, Inline comments, Rejects malicious lines)" 0 "test_config_parser"

# --- SCENARIO 6: Mock Environment Isolation ---
echo -e "\n--- Test: Mock Environment Isolation ---"

test_payload_isolation() {
    # Delete any existing files that might have been created by the user running the real script
    rm -f "/dev/shm/net_monitor_up_payload.dat"
    rm -f "/tmp/net_monitor_up_payload.dat"
    
    # Re-trigger the exact extraction logic we use in the test suite
    sed '/^while true; do/,$d' "$RUN_SCRIPT" | sed 's|head -c 1M.*|true|' > "$SCRIPT_DIR/run_functions_only_test.sh"
    
    # Source it, triggering any global initializations
    source "$SCRIPT_DIR/run_functions_only_test.sh"
    
    # Check if the file was created (if so, our disk write isolation failed)
    local failed=0
    if [ -f "/dev/shm/net_monitor_up_payload.dat" ] || [ -f "/tmp/net_monitor_up_payload.dat" ]; then
        failed=1
    fi
    
    rm -f "$SCRIPT_DIR/run_functions_only_test.sh"
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

