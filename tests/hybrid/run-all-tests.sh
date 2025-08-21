#!/bin/bash
# ADIN2111 Hybrid Driver Test Suite Runner
# Author: Murray Kopit
# Date: August 21, 2025

set -e

# Configuration
TEST_DIR=$(dirname "$0")
RESULTS_DIR="test-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="${RESULTS_DIR}/report_${TIMESTAMP}.html"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test list
TESTS=(
    "test-single-interface.sh:Single Interface Mode"
    "test-hardware-forwarding.sh:Hardware Forwarding"
    "test-mac-learning.py:MAC Learning Table"
    "test-statistics.sh:Statistics Tracking"
    "test-throughput.sh:Throughput Performance"
    "test-latency.sh:Latency Measurement"
)

# Results tracking
PASSED=0
FAILED=0
SKIPPED=0

# Create results directory
mkdir -p "$RESULTS_DIR"

# HTML report header
cat > "$REPORT_FILE" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>ADIN2111 Hybrid Driver Test Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #333; }
        .summary { 
            background: #f0f0f0; 
            padding: 15px; 
            border-radius: 5px;
            margin: 20px 0;
        }
        .test-result {
            margin: 10px 0;
            padding: 10px;
            border-left: 4px solid #ccc;
        }
        .passed { 
            border-left-color: #4CAF50;
            background: #f1f8f4;
        }
        .failed { 
            border-left-color: #f44336;
            background: #fef1f0;
        }
        .skipped { 
            border-left-color: #ff9800;
            background: #fff8f1;
        }
        .log {
            background: #f5f5f5;
            padding: 10px;
            margin-top: 10px;
            border-radius: 3px;
            font-family: monospace;
            font-size: 12px;
            white-space: pre-wrap;
            max-height: 300px;
            overflow-y: auto;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
        }
        th, td {
            border: 1px solid #ddd;
            padding: 8px;
            text-align: left;
        }
        th {
            background: #f0f0f0;
        }
        .timestamp {
            color: #666;
            font-size: 12px;
        }
    </style>
</head>
<body>
    <h1>ADIN2111 Hybrid Driver Test Report</h1>
    <p class="timestamp">Generated: $(date)</p>
    <div class="summary">
        <h2>Test Environment</h2>
        <table>
            <tr><th>Kernel Version</th><td>$(uname -r)</td></tr>
            <tr><th>Architecture</th><td>$(uname -m)</td></tr>
            <tr><th>QEMU Version</th><td>$(qemu-system-arm --version | head -1)</td></tr>
            <tr><th>Driver Mode</th><td>Single Interface Mode</td></tr>
        </table>
    </div>
    <h2>Test Results</h2>
EOF

# Print header
echo -e "${BLUE}=======================================${NC}"
echo -e "${BLUE}  ADIN2111 Hybrid Driver Test Suite${NC}"
echo -e "${BLUE}=======================================${NC}"
echo ""
echo "Test environment:"
echo "  Kernel: $(uname -r)"
echo "  Time: $(date)"
echo ""

# Run each test
for test_spec in "${TESTS[@]}"; do
    IFS=':' read -r test_file test_name <<< "$test_spec"
    test_path="${TEST_DIR}/${test_file}"
    log_file="${RESULTS_DIR}/${test_file%.sh}.log"
    
    echo -n "Running: $test_name... "
    
    # Check if test exists
    if [ ! -f "$test_path" ]; then
        echo -e "${YELLOW}SKIPPED${NC} (not found)"
        ((SKIPPED++))
        
        # Add to HTML report
        cat >> "$REPORT_FILE" << EOF
        <div class="test-result skipped">
            <h3>$test_name</h3>
            <p><strong>Status:</strong> SKIPPED - Test file not found</p>
        </div>
EOF
        continue
    fi
    
    # Make test executable
    chmod +x "$test_path"
    
    # Run test and capture output
    if timeout 60 "$test_path" > "$log_file" 2>&1; then
        echo -e "${GREEN}PASSED${NC}"
        ((PASSED++))
        status_class="passed"
        status_text="PASSED"
    else
        echo -e "${RED}FAILED${NC}"
        ((FAILED++))
        status_class="failed"
        status_text="FAILED"
    fi
    
    # Add to HTML report
    cat >> "$REPORT_FILE" << EOF
    <div class="test-result $status_class">
        <h3>$test_name</h3>
        <p><strong>Status:</strong> $status_text</p>
        <p><strong>Test File:</strong> $test_file</p>
        <details>
            <summary>View Log</summary>
            <div class="log">$(cat "$log_file" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</div>
        </details>
    </div>
EOF
done

# Calculate percentages
TOTAL=$((PASSED + FAILED + SKIPPED))
if [ $TOTAL -gt 0 ]; then
    PASS_RATE=$((PASSED * 100 / TOTAL))
else
    PASS_RATE=0
fi

# Print summary
echo ""
echo -e "${BLUE}=======================================${NC}"
echo -e "${BLUE}            Test Summary${NC}"
echo -e "${BLUE}=======================================${NC}"
echo -e "  ${GREEN}Passed:${NC}  $PASSED"
echo -e "  ${RED}Failed:${NC}  $FAILED"
echo -e "  ${YELLOW}Skipped:${NC} $SKIPPED"
echo -e "  Total:    $TOTAL"
echo -e "  Pass Rate: ${PASS_RATE}%"
echo ""

# Complete HTML report
cat >> "$REPORT_FILE" << EOF
    <div class="summary">
        <h2>Summary</h2>
        <table>
            <tr><th>Passed</th><td style="color: green;">$PASSED</td></tr>
            <tr><th>Failed</th><td style="color: red;">$FAILED</td></tr>
            <tr><th>Skipped</th><td style="color: orange;">$SKIPPED</td></tr>
            <tr><th>Total</th><td>$TOTAL</td></tr>
            <tr><th>Pass Rate</th><td>${PASS_RATE}%</td></tr>
        </table>
    </div>
    
    <h2>Performance Metrics</h2>
    <div id="performance">
        <!-- Performance graphs would go here -->
        <p>Performance metrics will be populated by individual test results.</p>
    </div>
    
    <div class="timestamp">
        <p>Report generated on $(hostname) at $(date)</p>
    </div>
</body>
</html>
EOF

echo "HTML report saved to: $REPORT_FILE"

# Generate JSON report for CI/CD
JSON_REPORT="${RESULTS_DIR}/report_${TIMESTAMP}.json"
cat > "$JSON_REPORT" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "environment": {
        "kernel": "$(uname -r)",
        "arch": "$(uname -m)",
        "hostname": "$(hostname)"
    },
    "summary": {
        "passed": $PASSED,
        "failed": $FAILED,
        "skipped": $SKIPPED,
        "total": $TOTAL,
        "pass_rate": $PASS_RATE
    },
    "tests": [
EOF

# Add test results to JSON
first=true
for test_spec in "${TESTS[@]}"; do
    IFS=':' read -r test_file test_name <<< "$test_spec"
    
    if [ "$first" = false ]; then
        echo "," >> "$JSON_REPORT"
    fi
    first=false
    
    # Determine status
    if [ -f "${RESULTS_DIR}/${test_file%.sh}.log" ]; then
        if grep -q "PASS" "${RESULTS_DIR}/${test_file%.sh}.log"; then
            status="passed"
        else
            status="failed"
        fi
    else
        status="skipped"
    fi
    
    echo -n "        {\"name\": \"$test_name\", \"file\": \"$test_file\", \"status\": \"$status\"}" >> "$JSON_REPORT"
done

cat >> "$JSON_REPORT" << EOF

    ]
}
EOF

echo "JSON report saved to: $JSON_REPORT"

# Exit with appropriate code
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi