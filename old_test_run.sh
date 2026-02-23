#!/bin/bash
# ==========================================================================
# test_run.sh — Test suite for run.sh with fully mocked dependencies
#
# Mocking strategy:
#   We create stub scripts for ping, nmcli, notify-send, paplay, sleep,
#   curl, head, mktemp, and rm in a temp directory and prepend it to PATH.
#
#   All mock configuration is stored as FILES in $MOCK_STATE_DIR (not env
#   vars) to guarantee data survives setsid/subshell boundaries. The only
#   env var the mocks need is MOCK_STATE_DIR itself (a simple path string).
#
#   - ping reads results from  $MOCK_STATE_DIR/ping_results
#   - ping reads latency from  $MOCK_STATE_DIR/ping_latency
#   - curl reads speeds from   $MOCK_STATE_DIR/curl_speeds
#   - nmcli reads data from    $MOCK_STATE_DIR/nmcli_active_data
#                               $MOCK_STATE_DIR/nmcli_all_data
#                               $MOCK_STATE_DIR/nmcli_up_fail
#   - sleep reads max from     $MOCK_STATE_DIR/max_sleep_calls
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/run.sh"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_TESTS=0

# ──────────────────────────────────────────────
# Colors
# ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ──────────────────────────────────────────────
# Assertion helpers
# ──────────────────────────────────────────────
assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        return 0
    else
        echo -e "  ${RED}ASSERT FAIL${RESET}: $label"
        echo "    Expected output to contain: \"$needle\""
        echo "    Actual output (last 10 lines):"
        echo "$haystack" | tail -10 | sed 's/^/      /'
        return 1
    fi
}

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${RED}ASSERT FAIL${RESET}: $label"
        echo "    Expected output NOT to contain: \"$needle\""
        return 1
    else
        return 0
    fi
}

assert_file_contains() {
    local label="$1" filepath="$2" needle="$3"
    if [ -f "$filepath" ] && grep -qF "$needle" "$filepath"; then
        return 0
    else
        echo -e "  ${RED}ASSERT FAIL${RESET}: $label"
        echo "    Expected file '$filepath' to contain: \"$needle\""
        if [ -f "$filepath" ]; then
            echo "    File contents:"
            cat "$filepath" | sed 's/^/      /'
        else
            echo "    File does not exist."
        fi
        return 1
    fi
}

assert_file_not_exists() {
    local label="$1" filepath="$2"
    if [ ! -f "$filepath" ]; then
        return 0
    else
        echo -e "  ${RED}ASSERT FAIL${RESET}: $label"
        echo "    Expected file '$filepath' NOT to exist, but it does."
        return 1
    fi
}

# ──────────────────────────────────────────────
# Setup: create mock scripts in a temp directory
# ALL mocks read config from FILES in $MOCK_STATE_DIR
# ──────────────────────────────────────────────
setup_mocks() {
    TEST_TMP=$(mktemp -d /tmp/test_run_sh.XXXXXX)
    MOCK_DIR="$TEST_TMP/mocks"
    mkdir -p "$MOCK_DIR"

    # --- MOCK: ping ---
    # Reads results from $MOCK_STATE_DIR/ping_results (space-separated 0/1 exit codes)
    # Reads latency from $MOCK_STATE_DIR/ping_latency (integer ms)
    # Uses a counter file to cycle through results.
    # When exit code is 0, outputs fake rtt stats with the configured latency.
    cat > "$MOCK_DIR/ping" << 'MOCK_EOF'
#!/bin/bash
COUNTER_FILE="${MOCK_STATE_DIR}/ping_count"
count=0
if [ -f "$COUNTER_FILE" ]; then count=$(cat "$COUNTER_FILE"); fi
echo "ping $*" >> "${MOCK_STATE_DIR}/ping_log"
echo $((count + 1)) > "$COUNTER_FILE"

RESULTS_STR=$(cat "${MOCK_STATE_DIR}/ping_results" 2>/dev/null || echo "1")
IFS=' ' read -ra RESULTS <<< "$RESULTS_STR"
num=${#RESULTS[@]}
idx=$((count % num))
exit_code="${RESULTS[$idx]}"

if [ "$exit_code" -eq 0 ]; then
    lat=$(cat "${MOCK_STATE_DIR}/ping_latency" 2>/dev/null || echo "20")
    echo "PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data."
    echo "--- 1.1.1.1 ping statistics ---"
    echo "3 packets transmitted, 3 received, 0% packet loss, time 2003ms"
    echo "rtt min/avg/max/mdev = ${lat}.1/${lat}.2/${lat}.3/0.1 ms"
fi
exit "$exit_code"
MOCK_EOF
    chmod +x "$MOCK_DIR/ping"

    # --- MOCK: curl ---
    # Reads speeds from $MOCK_STATE_DIR/curl_speeds (space-separated integers)
    # Cycles through speeds on successive calls.
    cat > "$MOCK_DIR/curl" << 'MOCK_EOF'
#!/bin/bash
COUNTER_FILE="${MOCK_STATE_DIR}/curl_count"
count=0
if [ -f "$COUNTER_FILE" ]; then count=$(cat "$COUNTER_FILE"); fi
echo "curl $*" >> "${MOCK_STATE_DIR}/curl_log"
echo $((count + 1)) > "$COUNTER_FILE"

SPEEDS_STR=$(cat "${MOCK_STATE_DIR}/curl_speeds" 2>/dev/null || echo "0")
IFS=' ' read -ra SPEEDS <<< "$SPEEDS_STR"
num=${#SPEEDS[@]}
idx=$((count % num))
echo "${SPEEDS[$idx]}.000"
exit 0
MOCK_EOF
    chmod +x "$MOCK_DIR/curl"

    # --- MOCK: nmcli ---
    # Reads data from files:
    #   $MOCK_STATE_DIR/nmcli_active_data  → returned for "connection show --active"
    #   $MOCK_STATE_DIR/nmcli_all_data     → returned for "connection show"
    #   $MOCK_STATE_DIR/nmcli_up_fail      → comma-separated UUIDs that fail "connection up"
    cat > "$MOCK_DIR/nmcli" << 'MOCK_EOF'
#!/bin/bash
echo "nmcli $*" >> "${MOCK_STATE_DIR}/nmcli_log"
args="$*"

# Pattern 1: connection show --active
if echo "$args" | grep -q "connection show --active"; then
    cat "${MOCK_STATE_DIR}/nmcli_active_data" 2>/dev/null
    exit 0
fi

# Pattern 3: connection up (must check before pattern 2)
if echo "$args" | grep -q "connection up"; then
    conn_uuid=$(echo "$args" | sed 's/.*connection up //' | sed 's/^uuid //' | sed 's/ --wait.*//' | xargs)

    if [ -f "${MOCK_STATE_DIR}/nmcli_up_fail" ]; then
        FAIL_STR=$(cat "${MOCK_STATE_DIR}/nmcli_up_fail")
        IFS=',' read -ra FAIL_LIST <<< "$FAIL_STR"
        for fail_uuid in "${FAIL_LIST[@]}"; do
            fail_uuid=$(echo "$fail_uuid" | xargs)
            if [ "$conn_uuid" = "$fail_uuid" ]; then
                exit 1
            fi
        done
    fi
    exit 0
fi

# Pattern 4: device wifi list (must be mocked to provide VISIBLE_SSIDS)
if echo "$args" | grep -q "device wifi list"; then
    cat "${MOCK_STATE_DIR}/nmcli_wifi_list_data" 2>/dev/null
    exit 0
fi

# Pattern 2: connection show (list all)
if echo "$args" | grep -q "connection show"; then
    cat "${MOCK_STATE_DIR}/nmcli_all_data" 2>/dev/null
    exit 0
fi

exit 0
MOCK_EOF
    chmod +x "$MOCK_DIR/nmcli"

    # --- MOCK: notify-send ---
    cat > "$MOCK_DIR/notify-send" << 'MOCK_EOF'
#!/bin/bash
echo "notify-send $*" >> "${MOCK_STATE_DIR}/notify_log"
exit 0
MOCK_EOF
    chmod +x "$MOCK_DIR/notify-send"

    # --- MOCK: paplay ---
    cat > "$MOCK_DIR/paplay" << 'MOCK_EOF'
#!/bin/bash
echo "paplay $*" >> "${MOCK_STATE_DIR}/paplay_log"
exit 0
MOCK_EOF
    chmod +x "$MOCK_DIR/paplay"

    # --- MOCK: head ---
    cat > "$MOCK_DIR/head" << 'MOCK_EOF'
#!/bin/bash
echo "mock_data"
exit 0
MOCK_EOF
    chmod +x "$MOCK_DIR/head"

    # --- MOCK: mktemp ---
    cat > "$MOCK_DIR/mktemp" << 'MOCK_EOF'
#!/bin/bash
TMPFILE="${MOCK_STATE_DIR}/mock_upload.tmp"
touch "$TMPFILE"
echo "$TMPFILE"
exit 0
MOCK_EOF
    chmod +x "$MOCK_DIR/mktemp"

    # --- MOCK: rm ---
    cat > "$MOCK_DIR/rm" << 'MOCK_EOF'
#!/bin/bash
echo "rm $*" >> "${MOCK_STATE_DIR}/rm_log"
exit 0
MOCK_EOF
    chmod +x "$MOCK_DIR/rm"

    # --- MOCK: sleep ---
    # Reads max from $MOCK_STATE_DIR/max_sleep_calls
    # After that many calls, kills the process group.
    cat > "$MOCK_DIR/sleep" << 'MOCK_EOF'
#!/bin/bash
COUNTER_FILE="${MOCK_STATE_DIR}/sleep_count"
count=0
if [ -f "$COUNTER_FILE" ]; then count=$(cat "$COUNTER_FILE"); fi
echo $((count + 1)) > "$COUNTER_FILE"

MAX=$(cat "${MOCK_STATE_DIR}/max_sleep_calls" 2>/dev/null || echo "2")
if [ "$count" -ge "$MAX" ]; then
    kill -- -$$  2>/dev/null || true
    kill $PPID   2>/dev/null || true
    exit 0
fi
exit 0
MOCK_EOF
    chmod +x "$MOCK_DIR/sleep"
}

cleanup() {
    if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
        rm -rf "$TEST_TMP"
    fi
}

# ──────────────────────────────────────────────
# Run a scenario
# ──────────────────────────────────────────────
# Creates a state dir with all mock config as files, a test monitor.conf
# with single-element arrays (1 ping target, 1 DL target, 1 UL target),
# then runs run.sh with mocks on PATH from within the state dir.
#
# Arguments: scenario_name [extra args to pass to run.sh]
# Before calling, set these variables in the test function:
#   MOCK_PING_RESULTS   - space-separated exit codes (e.g. "1 0 0")
#   MOCK_PING_LATENCY   - integer ms (e.g. "20")
#   MOCK_CURL_SPEEDS    - space-separated integers (e.g. "2000000 2000000")
#   MOCK_NMCLI_ACTIVE   - UUID:TYPE for active connection
#   MOCK_NMCLI_ALL      - multiline UUID:NAME:TYPE for all connections
#   MOCK_NMCLI_UP_FAIL  - comma-separated UUIDs that fail to connect
#   MAX_SLEEP_CALLS     - integer, how many sleeps before kill
# ──────────────────────────────────────────────
run_scenario() {
    local name="$1"
    shift

    local state_dir="$TEST_TMP/state_$(echo "$name" | tr ' ' '_')"
    mkdir -p "$state_dir"

    # Write test monitor.conf with single-element arrays
    # So each check_light_ping = 1 ping call, each check_heavy_bandwidth = 2 curl calls
    cat > "$state_dir/monitor.conf" << 'CONFEOF'
CHECK_INTERVAL=15
HEAVY_CHECK_MULTIPLIER=20
MAX_LATENCY=150
MIN_DL_SPEED=1000000
MIN_UL_SPEED=500000
PING_TARGETS=("1.1.1.1")
DL_TARGETS=("http://test.example.com/1MB.zip")
UL_TARGETS=("https://test.example.com/post")
CONFEOF

    # Write ALL mock config to files (not env vars)
    echo "${MOCK_PING_RESULTS:-1}"              > "$state_dir/ping_results"
    echo "${MOCK_PING_LATENCY:-20}"             > "$state_dir/ping_latency"
    echo "${MOCK_CURL_SPEEDS:-2000000}"         > "$state_dir/curl_speeds"
    echo "${MOCK_NMCLI_ACTIVE:-}"               > "$state_dir/nmcli_active_data"
    echo "${MOCK_NMCLI_ALL:-}"                  > "$state_dir/nmcli_all_data"
    echo "${MOCK_NMCLI_UP_FAIL:-}"              > "$state_dir/nmcli_up_fail"
    echo "${MOCK_NMCLI_WIFI_LIST:-}"            > "$state_dir/nmcli_wifi_list_data"
    echo "${MAX_SLEEP_CALLS:-2}"                > "$state_dir/max_sleep_calls"

    local output
    output=$(
        cd "$state_dir" && \
        env MOCK_STATE_DIR="$state_dir" PATH="$MOCK_DIR:$PATH" \
        bash -c "cp '$RUN_SH' run.sh && setsid bash run.sh $@" 2>&1 || true
    )

    echo "$output" > "$state_dir/stdout"

    SCENARIO_OUTPUT="$output"
    SCENARIO_STATE_DIR="$state_dir"
}

# ──────────────────────────────────────────────
# Test runner
# ──────────────────────────────────────────────
run_test() {
    local test_name="$1"
    local test_func="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}TEST $TOTAL_TESTS: $test_name${RESET}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    local failed=0
    $test_func || failed=1

    if [ "$failed" -eq 0 ]; then
        echo -e "  ${GREEN}✓ PASS${RESET}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "  ${RED}✗ FAIL${RESET}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}


# ==========================================================================
# TEST SCENARIOS
# ==========================================================================

# ------------------------------------------
# Scenario 1: Network is healthy
# Ping succeeds with low latency. On loop 0, heavy check also runs
# and passes. Script loops silently.
#
# Call sequence:
#  Loop 0: ping(0)=pass → heavy: curl(0)=pass(DL), curl(1)=pass(UL) → sleep
#  Loop 1: ping(1)=pass → no heavy (1%20≠0) → sleep → killed
# ------------------------------------------
test_network_healthy() {
    MOCK_PING_RESULTS="0"
    MOCK_PING_LATENCY="20"
    MOCK_CURL_SPEEDS="2000000"
    MOCK_NMCLI_ACTIVE="11111111-1111-1111-1111-111111111111:802-11-wireless"
    MOCK_NMCLI_ALL="11111111-1111-1111-1111-111111111111:WiFi-Home:802-11-wireless"
    MOCK_NMCLI_UP_FAIL=""
    MAX_SLEEP_CALLS=2

    run_scenario "network_healthy"

    local ok=0
    assert_contains "Should show startup message" \
        "$SCENARIO_OUTPUT" "Starting Robust Network Monitor" || ok=1
    assert_not_contains "Should NOT detect network issue" \
        "$SCENARIO_OUTPUT" "Network issue detected" || ok=1
    assert_not_contains "Should NOT attempt switching" \
        "$SCENARIO_OUTPUT" "Attempting to switch" || ok=1
    assert_file_not_exists "No notifications sent" \
        "$SCENARIO_STATE_DIR/notify_log" || ok=1

    return $ok
}

# ------------------------------------------
# Scenario 2: Ping fails → switch to first alternative → restored
#
# Call sequence:
#  Loop 0: ping(0)=FAIL → failover
#    nmcli show --active → UUID 1111
#    nmcli show → [WiFi-Home(1111), WiFi-Office(2222)]
#    Skip WiFi-Home (matches CURRENT_UUID)
#    Try WiFi-Office: nmcli up 2222 → success
#    Verify: ping(1)=PASS → quality confirmed, break
#  Loop 1: ping(2)=FAIL → failover again (wraps around: 2%2=0=FAIL)
#    ... but we've already confirmed the switch happened
# ------------------------------------------
test_switch_to_first_alternative() {
    MOCK_PING_RESULTS="1 0"
    MOCK_PING_LATENCY="20"
    MOCK_CURL_SPEEDS="2000000"
    MOCK_NMCLI_ACTIVE="11111111-1111-1111-1111-111111111111:802-11-wireless"
    MOCK_NMCLI_ALL="11111111-1111-1111-1111-111111111111:WiFi-Home:802-11-wireless
22222222-2222-2222-2222-222222222222:WiFi-Office:802-11-wireless"
    MOCK_NMCLI_WIFI_LIST="WiFi-Home
WiFi-Office"
    MOCK_NMCLI_UP_FAIL=""
    MAX_SLEEP_CALLS=2

    run_scenario "switch_first_alt"

    local ok=0
    assert_contains "Should detect network issue" \
        "$SCENARIO_OUTPUT" "Network issue detected" || ok=1
    assert_contains "Should attempt WiFi-Office" \
        "$SCENARIO_OUTPUT" "Attempting to switch to alternative network: WiFi-Office" || ok=1
    assert_contains "Should confirm quality on WiFi-Office" \
        "$SCENARIO_OUTPUT" "Quality confirmed on WiFi-Office" || ok=1
    assert_file_contains "Desktop notification sent" \
        "$SCENARIO_STATE_DIR/notify_log" "Network Restored" || ok=1
    assert_not_contains "Should NOT raise alarm" \
        "$SCENARIO_OUTPUT" "Raising alarm" || ok=1

    return $ok
}

# ------------------------------------------
# Scenario 3: First alt fails quality, second works
#
# Call sequence:
#  Loop 0: ping(0)=FAIL → failover
#    Skip WiFi-Home (matches current)
#    Try WiFi-Office: nmcli up → success
#    Verify: ping(1)=FAIL → quality failed
#    Try WiFi-Backup: nmcli up → success
#    Verify: ping(2)=PASS → quality confirmed, break
# ------------------------------------------
test_first_alt_no_quality_second_works() {
    MOCK_PING_RESULTS="1 1 0"
    MOCK_PING_LATENCY="20"
    MOCK_CURL_SPEEDS="2000000"
    MOCK_NMCLI_ACTIVE="11111111-1111-1111-1111-111111111111:802-11-wireless"
    MOCK_NMCLI_ALL="11111111-1111-1111-1111-111111111111:WiFi-Home:802-11-wireless
22222222-2222-2222-2222-222222222222:WiFi-Office:802-11-wireless
33333333-3333-3333-3333-333333333333:WiFi-Backup:802-11-wireless"
    MOCK_NMCLI_WIFI_LIST="WiFi-Home
WiFi-Office
WiFi-Backup"
    MOCK_NMCLI_UP_FAIL=""
    MAX_SLEEP_CALLS=2

    run_scenario "multi_hop_switch"

    local ok=0
    assert_contains "Should detect network issue" \
        "$SCENARIO_OUTPUT" "Network issue detected" || ok=1
    assert_contains "Should try WiFi-Office" \
        "$SCENARIO_OUTPUT" "Attempting to switch to alternative network: WiFi-Office" || ok=1
    assert_contains "WiFi-Office fails quality" \
        "$SCENARIO_OUTPUT" "WiFi-Office connected locally, but failed quality checks" || ok=1
    assert_contains "Should try WiFi-Backup" \
        "$SCENARIO_OUTPUT" "Attempting to switch to alternative network: WiFi-Backup" || ok=1
    assert_contains "Quality confirmed on WiFi-Backup" \
        "$SCENARIO_OUTPUT" "Quality confirmed on WiFi-Backup" || ok=1
    assert_not_contains "Should NOT raise alarm" \
        "$SCENARIO_OUTPUT" "Raising alarm" || ok=1

    return $ok
}

# ------------------------------------------
# Scenario 4: All alternatives fail — alarm raised
# Ping always fails. nmcli up succeeds but quality checks fail.
# ------------------------------------------
test_all_alternatives_fail() {
    MOCK_PING_RESULTS="1"
    MOCK_PING_LATENCY="20"
    MOCK_CURL_SPEEDS="2000000"
    MOCK_NMCLI_ACTIVE="11111111-1111-1111-1111-111111111111:802-11-wireless"
    MOCK_NMCLI_ALL="11111111-1111-1111-1111-111111111111:WiFi-Home:802-11-wireless
22222222-2222-2222-2222-222222222222:WiFi-Office:802-11-wireless
33333333-3333-3333-3333-333333333333:WiFi-Backup:802-11-wireless"
    MOCK_NMCLI_WIFI_LIST="WiFi-Home
WiFi-Office
WiFi-Backup"
    MOCK_NMCLI_UP_FAIL=""
    MAX_SLEEP_CALLS=2

    run_scenario "all_fail"

    local ok=0
    assert_contains "Should detect network issue" \
        "$SCENARIO_OUTPUT" "Network issue detected" || ok=1
    assert_contains "WiFi-Office fails quality" \
        "$SCENARIO_OUTPUT" "WiFi-Office connected locally, but failed quality checks" || ok=1
    assert_contains "WiFi-Backup fails quality" \
        "$SCENARIO_OUTPUT" "WiFi-Backup connected locally, but failed quality checks" || ok=1
    assert_contains "Should raise alarm" \
        "$SCENARIO_OUTPUT" "All available connections exhausted" || ok=1
    assert_file_contains "Critical notification sent" \
        "$SCENARIO_STATE_DIR/notify_log" "CRITICAL NETWORK FAILURE" || ok=1
    assert_file_contains "Audio alarm played" \
        "$SCENARIO_STATE_DIR/paplay_log" "paplay" || ok=1

    return $ok
}

# ------------------------------------------
# Scenario 5: No alternative connections — alarm immediately
# Only the current (broken) connection in the list.
# ------------------------------------------
test_no_alternatives() {
    MOCK_PING_RESULTS="1"
    MOCK_PING_LATENCY="20"
    MOCK_CURL_SPEEDS="2000000"
    MOCK_NMCLI_ACTIVE="11111111-1111-1111-1111-111111111111:802-11-wireless"
    MOCK_NMCLI_ALL="11111111-1111-1111-1111-111111111111:WiFi-Home:802-11-wireless"
    MOCK_NMCLI_UP_FAIL=""
    MAX_SLEEP_CALLS=2

    run_scenario "no_alternatives"

    local ok=0
    assert_contains "Should detect network issue" \
        "$SCENARIO_OUTPUT" "Network issue detected" || ok=1
    assert_not_contains "Should NOT attempt any switch" \
        "$SCENARIO_OUTPUT" "Attempting to switch" || ok=1
    assert_contains "Should raise alarm" \
        "$SCENARIO_OUTPUT" "All available connections exhausted" || ok=1
    assert_file_contains "Critical notification sent" \
        "$SCENARIO_STATE_DIR/notify_log" "CRITICAL NETWORK FAILURE" || ok=1

    return $ok
}

# ------------------------------------------
# Scenario 6: nmcli connection up fails for all — alarm
# ------------------------------------------
test_nmcli_up_fails() {
    MOCK_PING_RESULTS="1"
    MOCK_PING_LATENCY="20"
    MOCK_CURL_SPEEDS="2000000"
    MOCK_NMCLI_ACTIVE="11111111-1111-1111-1111-111111111111:802-11-wireless"
    MOCK_NMCLI_ALL="11111111-1111-1111-1111-111111111111:WiFi-Home:802-11-wireless
22222222-2222-2222-2222-222222222222:WiFi-Office:802-11-wireless
33333333-3333-3333-3333-333333333333:WiFi-Backup:802-11-wireless"
    MOCK_NMCLI_WIFI_LIST="WiFi-Home
WiFi-Office
WiFi-Backup"
    MOCK_NMCLI_UP_FAIL="22222222-2222-2222-2222-222222222222,33333333-3333-3333-3333-333333333333"
    MAX_SLEEP_CALLS=2

    run_scenario "nmcli_up_fails"

    local ok=0
    assert_contains "Should detect network issue" \
        "$SCENARIO_OUTPUT" "Network issue detected" || ok=1
    assert_contains "WiFi-Office can't connect" \
        "$SCENARIO_OUTPUT" "Could not connect to WiFi-Office" || ok=1
    assert_contains "WiFi-Backup can't connect" \
        "$SCENARIO_OUTPUT" "Could not connect to WiFi-Backup" || ok=1
    assert_contains "Should raise alarm" \
        "$SCENARIO_OUTPUT" "All available connections exhausted" || ok=1
    assert_file_contains "Critical notification sent" \
        "$SCENARIO_STATE_DIR/notify_log" "CRITICAL NETWORK FAILURE" || ok=1

    return $ok
}

# ------------------------------------------
# Scenario 7: Colon in SSID — name parsed correctly
# Network name "Guest:5GHz" contains the nmcli delimiter character.
# ------------------------------------------
test_colon_in_ssid() {
    MOCK_PING_RESULTS="1 0"
    MOCK_PING_LATENCY="20"
    MOCK_CURL_SPEEDS="2000000"
    MOCK_NMCLI_ACTIVE="11111111-1111-1111-1111-111111111111:802-11-wireless"
    MOCK_NMCLI_ALL="11111111-1111-1111-1111-111111111111:WiFi-Home:802-11-wireless
44444444-4444-4444-4444-444444444444:Guest:5GHz:802-11-wireless"
    MOCK_NMCLI_WIFI_LIST="WiFi-Home
Guest:5GHz"
    MOCK_NMCLI_UP_FAIL=""
    MAX_SLEEP_CALLS=2

    run_scenario "colon_ssid"

    local ok=0
    assert_contains "Should attempt the colon-named network" \
        "$SCENARIO_OUTPUT" "Attempting to switch to alternative network: Guest:5GHz" || ok=1
    assert_contains "Should confirm quality with full name" \
        "$SCENARIO_OUTPUT" "Quality confirmed on Guest:5GHz" || ok=1
    assert_file_contains "Notification uses full name" \
        "$SCENARIO_STATE_DIR/notify_log" "Guest:5GHz" || ok=1

    return $ok
}

# ------------------------------------------
# Scenario 8: High latency triggers failover
# Ping succeeds (packets delivered) but latency exceeds threshold.
# ------------------------------------------
test_high_latency_triggers_failover() {
    MOCK_PING_RESULTS="0"
    MOCK_PING_LATENCY="300"         # 300ms, above 150ms threshold
    MOCK_CURL_SPEEDS="2000000"
    MOCK_NMCLI_ACTIVE="11111111-1111-1111-1111-111111111111:802-11-wireless"
    MOCK_NMCLI_ALL="11111111-1111-1111-1111-111111111111:WiFi-Home:802-11-wireless"
    MOCK_NMCLI_UP_FAIL=""
    MAX_SLEEP_CALLS=2

    run_scenario "high_latency"

    local ok=0
    assert_contains "Should detect light check failure" \
        "$SCENARIO_OUTPUT" "Light Check Failed" || ok=1
    assert_contains "Should trigger failover" \
        "$SCENARIO_OUTPUT" "Network issue detected" || ok=1

    return $ok
}

# ------------------------------------------
# Scenario 9: CLI argument --latency overrides default
# Latency is 200ms — above default 150, below override 250.
# With --latency 250 passed, the check should PASS.
# ------------------------------------------
test_cli_arg_override() {
    MOCK_PING_RESULTS="0"
    MOCK_PING_LATENCY="200"
    MOCK_CURL_SPEEDS="2000000"
    MOCK_NMCLI_ACTIVE="11111111-1111-1111-1111-111111111111:802-11-wireless"
    MOCK_NMCLI_ALL="11111111-1111-1111-1111-111111111111:WiFi-Home:802-11-wireless"
    MOCK_NMCLI_UP_FAIL=""
    MAX_SLEEP_CALLS=2

    run_scenario "cli_override" --latency 250

    local ok=0
    assert_not_contains "Should NOT trigger failover (latency under overridden threshold)" \
        "$SCENARIO_OUTPUT" "Network issue detected" || ok=1
    assert_not_contains "Should NOT show light check failure" \
        "$SCENARIO_OUTPUT" "Light Check Failed" || ok=1

    return $ok
}


# ==========================================================================
# MAIN
# ==========================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║          run.sh Network Switch Script — Test Suite                      ║${RESET}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}║  Mocking: ping, nmcli, curl, notify-send, paplay, sleep, head, mktemp  ║${RESET}"
echo -e "${BOLD}║  Script under test: run.sh (unmodified)                                 ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${RESET}"

setup_mocks

run_test "Network healthy — ping OK, no switch"                 test_network_healthy
run_test "Switch to first alternative — restored"               test_switch_to_first_alternative
run_test "First alt fails quality, second works"                test_first_alt_no_quality_second_works
run_test "All alternatives fail — alarm raised"                 test_all_alternatives_fail
run_test "No alternatives available — alarm raised"             test_no_alternatives
run_test "nmcli connection up fails — alarm raised"             test_nmcli_up_fails
run_test "Colon in SSID — name parsed correctly"                test_colon_in_ssid
run_test "High latency triggers failover"                       test_high_latency_triggers_failover
run_test "CLI argument --latency overrides default"             test_cli_arg_override

cleanup

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  RESULTS: $TOTAL_TESTS tests | ${GREEN}$PASS_COUNT passed${RESET} | ${RED}$FAIL_COUNT failed${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════${RESET}"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
