#!/bin/bash
#############################################
# Simple Test Runner for repo-lock-manager.sh
#############################################

# Don't exit on error - we want to see all test results
set +e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT="${1:-./repo-lock-manager.sh}"
TEST_DIR="/tmp/simple-lock-test-$$"
REPO="test-repo"

PASSED=0
FAILED=0

echo "========================================"
echo "Simple Lock Manager Test"
echo "========================================"
echo "Script: $SCRIPT"
echo "Test dir: $TEST_DIR"
echo ""

# Setup
echo "Setting up..."
mkdir -p "$TEST_DIR/$REPO"
cp "$SCRIPT" "$TEST_DIR/test-script.sh"
sed -i 's|REPO_BASE="/srv/repo-copy"|REPO_BASE="'"$TEST_DIR"'"|g' "$TEST_DIR/test-script.sh"
chmod +x "$TEST_DIR/test-script.sh"
TEST_SCRIPT="$TEST_DIR/test-script.sh"
echo "Setup complete"
echo ""

# Helper functions
cleanup() {
    rm -rf "$TEST_DIR/$REPO/.jenkins-publish-lock" 2>/dev/null || true
}

test_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((PASSED++))
}

test_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    echo "  Output: $2"
    ((FAILED++))
}

echo "========================================"
echo "Running Tests"
echo "========================================"
echo ""

# TEST 1
echo "TEST 1: Check status when unlocked"
cleanup
OUTPUT=$("$TEST_SCRIPT" "$REPO" status 2>&1)
if echo "$OUTPUT" | grep -q "UNLOCKED"; then
    test_pass "Status shows UNLOCKED"
else
    test_fail "Status should show UNLOCKED" "$OUTPUT"
fi
echo ""

# TEST 2
echo "TEST 2: Acquire lock"
cleanup
OUTPUT=$("$TEST_SCRIPT" "$REPO" acquire "job1" "100" 2>&1)
if echo "$OUTPUT" | grep -q "Lock acquired successfully"; then
    test_pass "Lock acquired"
else
    test_fail "Lock should be acquired" "$OUTPUT"
fi
echo ""

# TEST 3
echo "TEST 3: Lock directory exists"
if [ -d "$TEST_DIR/$REPO/.jenkins-publish-lock" ]; then
    test_pass "Lock directory created"
else
    test_fail "Lock directory should exist" "Directory not found"
fi
echo ""

# TEST 4
echo "TEST 4: Lock info file exists"
if [ -f "$TEST_DIR/$REPO/.jenkins-publish-lock/lock.info" ]; then
    test_pass "Lock info file created"
else
    test_fail "Lock info file should exist" "File not found"
fi
echo ""

# TEST 5
echo "TEST 5: Lock info contains job details"
if [ -f "$TEST_DIR/$REPO/.jenkins-publish-lock/lock.info" ]; then
    CONTENT=$(cat "$TEST_DIR/$REPO/.jenkins-publish-lock/lock.info")
    if echo "$CONTENT" | grep -q "job1" && echo "$CONTENT" | grep -q "100"; then
        test_pass "Lock info has correct details"
    else
        test_fail "Lock info should contain job1 and 100" "$CONTENT"
    fi
else
    test_fail "Lock info file missing" "Cannot check contents"
fi
echo ""

# TEST 6
echo "TEST 6: Status shows locked"
OUTPUT=$("$TEST_SCRIPT" "$REPO" status 2>&1)
if echo "$OUTPUT" | grep -q "LOCKED"; then
    test_pass "Status shows LOCKED"
else
    test_fail "Status should show LOCKED" "$OUTPUT"
fi
echo ""

# TEST 7
echo "TEST 7: Status shows job details"
OUTPUT=$("$TEST_SCRIPT" "$REPO" status 2>&1)
if echo "$OUTPUT" | grep -q "job1" && echo "$OUTPUT" | grep -q "100"; then
    test_pass "Status shows job details"
else
    test_fail "Status should show job1 and 100" "$OUTPUT"
fi
echo ""

# TEST 8
echo "TEST 8: Release lock"
OUTPUT=$("$TEST_SCRIPT" "$REPO" release "job1" "100" 2>&1)
if echo "$OUTPUT" | grep -q "Lock released"; then
    test_pass "Lock released"
else
    test_fail "Lock should be released" "$OUTPUT"
fi
echo ""

# TEST 9
echo "TEST 9: Lock directory removed"
if [ ! -d "$TEST_DIR/$REPO/.jenkins-publish-lock" ]; then
    test_pass "Lock directory removed"
else
    test_fail "Lock directory should be removed" "Directory still exists"
fi
echo ""

# TEST 10
echo "TEST 10: Status unlocked after release"
OUTPUT=$("$TEST_SCRIPT" "$REPO" status 2>&1)
if echo "$OUTPUT" | grep -q "UNLOCKED"; then
    test_pass "Status shows UNLOCKED after release"
else
    test_fail "Status should show UNLOCKED" "$OUTPUT"
fi
echo ""

# TEST 11
echo "TEST 11: Second lock attempt waits (2 second test)"
cleanup
"$TEST_SCRIPT" "$REPO" acquire "job1" "200" > /dev/null 2>&1
OUTPUT=$(timeout 2 "$TEST_SCRIPT" "$REPO" acquire "job2" "201" 2>&1 || true)
if echo "$OUTPUT" | grep -q "Lock is currently held"; then
    test_pass "Second job waits for lock"
else
    test_fail "Should show waiting message" "$OUTPUT"
fi
cleanup
echo ""

# TEST 12
echo "TEST 12: Stale lock detection (5 second test)"
cleanup
"$TEST_SCRIPT" "$REPO" acquire "job1" "300" > /dev/null 2>&1
# Make lock old
LOCK_INFO="$TEST_DIR/$REPO/.jenkins-publish-lock/lock.info"
OLD_TIME=$(($(date +%s) - 1900))
sed -i "s/timestamp: .*/timestamp: $OLD_TIME/" "$LOCK_INFO"
# Try to acquire
OUTPUT=$("$TEST_SCRIPT" "$REPO" acquire "job2" "301" 2>&1)
if echo "$OUTPUT" | grep -q "stale" && echo "$OUTPUT" | grep -q "Lock acquired"; then
    test_pass "Stale lock detected and removed"
else
    test_fail "Should detect and remove stale lock" "$OUTPUT"
fi
cleanup
echo ""

# TEST 13
echo "TEST 13: Corrupted lock (no metadata)"
cleanup
mkdir -p "$TEST_DIR/$REPO/.jenkins-publish-lock"
OUTPUT=$("$TEST_SCRIPT" "$REPO" acquire "job1" "400" 2>&1)
if echo "$OUTPUT" | grep -q "Lock acquired successfully"; then
    test_pass "Corrupted lock handled"
else
    test_fail "Should handle corrupted lock" "$OUTPUT"
fi
cleanup
echo ""

# TEST 14
echo "TEST 14: Invalid operation"
OUTPUT=$("$TEST_SCRIPT" "$REPO" invalid-op 2>&1 || true)
if echo "$OUTPUT" | grep -q "Invalid operation"; then
    test_pass "Invalid operation rejected"
else
    test_fail "Should reject invalid operation" "$OUTPUT"
fi
echo ""

# TEST 15
echo "TEST 15: Missing parameters"
OUTPUT=$("$TEST_SCRIPT" "" "" 2>&1 || true)
if echo "$OUTPUT" | grep -q "Missing required parameters"; then
    test_pass "Missing parameters detected"
else
    test_fail "Should detect missing parameters" "$OUTPUT"
fi
echo ""

# Cleanup
echo "========================================"
echo "Cleaning up..."
rm -rf "$TEST_DIR"
echo "Done"
echo ""

# Summary
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "Tests passed: ${GREEN}$PASSED${NC}"
echo -e "Tests failed: ${RED}$FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    exit 1
fi