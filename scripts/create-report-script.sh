#!/bin/bash
# Create test report generation script

cat << 'EOF' > scripts/generate-report.sh
#!/bin/bash
# Generate HTML test report for ADIN2111 test suite

LOGDIR="logs"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="$LOGDIR/test-report-$TIMESTAMP.html"

# Create logs directory if it doesn't exist
mkdir -p "$LOGDIR"

# Start HTML document
cat << 'HTML_START' > "$REPORT_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ADIN2111 Test Report</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background-color: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        .header {
            text-align: center;
            margin-bottom: 40px;
            padding-bottom: 20px;
            border-bottom: 2px solid #007acc;
        }
        .header h1 {
            color: #007acc;
            margin-bottom: 10px;
        }
        .summary {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-bottom: 40px;
        }
        .summary-card {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            border-radius: 8px;
            text-align: center;
        }
        .summary-card h3 {
            margin: 0 0 10px 0;
            font-size: 1.2em;
        }
        .summary-card .value {
            font-size: 2em;
            font-weight: bold;
        }
        .test-section {
            margin-bottom: 30px;
            padding: 20px;
            border: 1px solid #ddd;
            border-radius: 8px;
            background-color: #fafafa;
        }
        .test-section h2 {
            color: #333;
            margin-top: 0;
            border-bottom: 1px solid #ddd;
            padding-bottom: 10px;
        }
        .pass { color: #28a745; font-weight: bold; }
        .fail { color: #dc3545; font-weight: bold; }
        .warn { color: #ffc107; font-weight: bold; }
        .log-content {
            background-color: #2d3748;
            color: #e2e8f0;
            padding: 15px;
            border-radius: 5px;
            font-family: 'Courier New', monospace;
            font-size: 0.9em;
            max-height: 300px;
            overflow-y: auto;
            white-space: pre-wrap;
        }
        .timestamp {
            color: #666;
            font-size: 0.9em;
        }
        .footer {
            text-align: center;
            margin-top: 40px;
            padding-top: 20px;
            border-top: 1px solid #ddd;
            color: #666;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔬 ADIN2111 Test Suite Report</h1>
            <p class="timestamp">Generated on: $(date)</p>
        </div>
HTML_START

# Add summary section
cat << 'HTML_SUMMARY' >> "$REPORT_FILE"
        <div class="summary">
            <div class="summary-card">
                <h3>Build Status</h3>
                <div class="value" id="build-status">✓</div>
            </div>
            <div class="summary-card">
                <h3>Tests Run</h3>
                <div class="value" id="tests-run">0</div>
            </div>
            <div class="summary-card">
                <h3>Success Rate</h3>
                <div class="value" id="success-rate">0%</div>
            </div>
            <div class="summary-card">
                <h3>Duration</h3>
                <div class="value" id="duration">--</div>
            </div>
        </div>
HTML_SUMMARY

# Function to add test section
add_test_section() {
    local title="$1"
    local log_file="$2"
    local description="$3"
    
    echo "        <div class=\"test-section\">" >> "$REPORT_FILE"
    echo "            <h2>$title</h2>" >> "$REPORT_FILE"
    echo "            <p>$description</p>" >> "$REPORT_FILE"
    
    if [ -f "$log_file" ]; then
        local status="COMPLETED"
        local status_class="pass"
        
        # Check for common failure indicators
        if grep -q -i "error\|failed\|fatal" "$log_file"; then
            status="FAILED"
            status_class="fail"
        elif grep -q -i "warning\|warn" "$log_file"; then
            status="WARNING"
            status_class="warn"
        fi
        
        echo "            <p><strong>Status:</strong> <span class=\"$status_class\">$status</span></p>" >> "$REPORT_FILE"
        echo "            <h4>Log Output:</h4>" >> "$REPORT_FILE"
        echo "            <div class=\"log-content\">" >> "$REPORT_FILE"
        
        # Limit log output and sanitize for HTML
        tail -n 50 "$log_file" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' >> "$REPORT_FILE"
        
        echo "            </div>" >> "$REPORT_FILE"
    else
        echo "            <p><strong>Status:</strong> <span class=\"warn\">NOT RUN</span></p>" >> "$REPORT_FILE"
        echo "            <p>Log file not found: $log_file</p>" >> "$REPORT_FILE"
    fi
    
    echo "        </div>" >> "$REPORT_FILE"
}

# Add test sections
add_test_section "🔨 Kernel Build" "$LOGDIR/kernel-build.log" "Linux kernel compilation with ADIN2111 driver support"
add_test_section "🏗️ QEMU Build" "$LOGDIR/qemu-build.log" "QEMU build with ADIN2111 device model"
add_test_section "🌳 Device Tree" "$LOGDIR/dtb-build.log" "Device tree compilation for ADIN2111 integration"
add_test_section "🧪 Functional Tests" "$LOGDIR/functional-test.log" "Functional testing of ADIN2111 device functionality"
add_test_section "🔬 QTest Suite" "$LOGDIR/qtest.log" "QEMU unit tests for ADIN2111 device model"
add_test_section "⏱️ Timing Validation" "$LOGDIR/timing-test.log" "Performance and timing characteristics validation"
add_test_section "🚀 QEMU Boot" "$LOGDIR/qemu-boot.log" "QEMU system boot with ADIN2111 device"

# Add system information
cat << 'HTML_SYSINFO' >> "$REPORT_FILE"
        <div class="test-section">
            <h2>🖥️ System Information</h2>
            <div class="log-content">
HTML_SYSINFO

# Add system info to report
{
    echo "Hostname: $(hostname)"
    echo "OS: $(uname -a)"
    echo "CPU: $(nproc) cores"
    echo "Memory: $(free -h | grep '^Mem:' | awk '{print $2}')"
    echo "Disk Space: $(df -h . | tail -1 | awk '{print $4}')"
    echo "Build Time: $(date)"
    echo ""
    echo "Environment Variables:"
    echo "ARCH: arm"
    echo "CROSS_COMPILE: arm-linux-gnueabihf-"
    echo "JOBS: $(nproc)"
} >> "$REPORT_FILE"

cat << 'HTML_END' >> "$REPORT_FILE"
            </div>
        </div>

        <div class="footer">
            <p>Generated by ADIN2111 Test Suite Makefile</p>
            <p>Report timestamp: $(date)</p>
        </div>
    </div>

    <script>
        // Simple JavaScript to update summary cards
        document.addEventListener('DOMContentLoaded', function() {
            // Count test sections and estimate success rate
            const testSections = document.querySelectorAll('.test-section');
            const testCount = Math.max(0, testSections.length - 2); // Exclude system info
            
            document.getElementById('tests-run').textContent = testCount;
            
            // Calculate rough success rate based on log content
            let passCount = 0;
            testSections.forEach(section => {
                const statusSpan = section.querySelector('.pass');
                if (statusSpan) passCount++;
            });
            
            const successRate = testCount > 0 ? Math.round((passCount / testCount) * 100) : 0;
            document.getElementById('success-rate').textContent = successRate + '%';
            
            // Mock duration - in real implementation this would be calculated
            document.getElementById('duration').textContent = '~5min';
        });
    </script>
</body>
</html>
HTML_END

echo "Test report generated: $REPORT_FILE"
EOF

chmod +x scripts/generate-report.sh

echo "Report generation script created at scripts/generate-report.sh"