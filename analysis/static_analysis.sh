#!/bin/bash
# ADIN2111 Static Code Analysis Script
# Author: Murray Kopit <murr2k@gmail.com>
# Phase 2: Comprehensive static analysis automation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DRIVER_DIR="$PROJECT_ROOT/drivers/net/ethernet/adi/adin2111"
ANALYSIS_DIR="$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== ADIN2111 Static Code Analysis ===${NC}"
echo "Project: $PROJECT_ROOT"
echo "Driver:  $DRIVER_DIR"
echo "Output:  $ANALYSIS_DIR"
echo ""

# Create output directory
mkdir -p "$ANALYSIS_DIR/reports"

# Function to print section headers
print_section() {
    echo -e "\n${YELLOW}=== $1 ===${NC}"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 1. CppCheck Analysis
print_section "CppCheck Analysis"
if command_exists cppcheck; then
    echo "Running cppcheck..."
    cppcheck --version
    
    # Run comprehensive cppcheck
    cppcheck \
        --enable=all \
        --inconclusive \
        --xml \
        --xml-version=2 \
        --suppress=missingIncludeSystem \
        --suppress=unusedFunction \
        "$DRIVER_DIR" \
        2> "$ANALYSIS_DIR/reports/cppcheck-full.xml"
    
    # Generate human-readable report
    cppcheck \
        --enable=all \
        --inconclusive \
        --suppress=missingIncludeSystem \
        --suppress=unusedFunction \
        "$DRIVER_DIR" \
        2> "$ANALYSIS_DIR/reports/cppcheck-summary.txt"
    
    echo -e "${GREEN}✓ CppCheck analysis complete${NC}"
    
    # Count issues
    if [ -f "$ANALYSIS_DIR/reports/cppcheck-full.xml" ]; then
        CPPCHECK_ERRORS=$(grep -c 'severity="error"' "$ANALYSIS_DIR/reports/cppcheck-full.xml" 2>/dev/null || true)
        CPPCHECK_WARNINGS=$(grep -c 'severity="warning"' "$ANALYSIS_DIR/reports/cppcheck-full.xml" 2>/dev/null || true)
        CPPCHECK_STYLE=$(grep -c 'severity="style"' "$ANALYSIS_DIR/reports/cppcheck-full.xml" 2>/dev/null || true)
        
        # Set to 0 if grep found nothing (empty result)
        [ -z "$CPPCHECK_ERRORS" ] && CPPCHECK_ERRORS=0
        [ -z "$CPPCHECK_WARNINGS" ] && CPPCHECK_WARNINGS=0
        [ -z "$CPPCHECK_STYLE" ] && CPPCHECK_STYLE=0
    else
        CPPCHECK_ERRORS=0
        CPPCHECK_WARNINGS=0
        CPPCHECK_STYLE=0
    fi
    
    echo "  Errors: $CPPCHECK_ERRORS"
    echo "  Warnings: $CPPCHECK_WARNINGS" 
    echo "  Style: $CPPCHECK_STYLE"
else
    echo -e "${RED}✗ CppCheck not found${NC}"
fi

# 2. Checkpatch Analysis
print_section "Linux Kernel Checkpatch Analysis"
if [ -f "$ANALYSIS_DIR/checkpatch.pl" ]; then
    echo "Running checkpatch.pl..."
    
    # Check all driver files
    for file in "$DRIVER_DIR"/*.c; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            echo "  Checking $filename..."
            
            perl "$ANALYSIS_DIR/checkpatch.pl" \
                --no-tree \
                --file "$file" \
                --terse > "$ANALYSIS_DIR/reports/checkpatch-$filename.txt" 2>&1 || true
        fi
    done
    
    # Combine all checkpatch results (exclude combined file to avoid circular reference)
    find "$ANALYSIS_DIR/reports" -name "checkpatch-*.c.txt" -exec cat {} \; > "$ANALYSIS_DIR/reports/checkpatch-combined.txt"
    
    echo -e "${GREEN}✓ Checkpatch analysis complete${NC}"
    
    # Count issues
    if [ -f "$ANALYSIS_DIR/reports/checkpatch-combined.txt" ]; then
        CHECKPATCH_ERRORS=$(grep -c "ERROR:" "$ANALYSIS_DIR/reports/checkpatch-combined.txt" 2>/dev/null || true)
        CHECKPATCH_WARNINGS=$(grep -c "WARNING:" "$ANALYSIS_DIR/reports/checkpatch-combined.txt" 2>/dev/null || true)
        
        # Set to 0 if grep found nothing (empty result)
        [ -z "$CHECKPATCH_ERRORS" ] && CHECKPATCH_ERRORS=0
        [ -z "$CHECKPATCH_WARNINGS" ] && CHECKPATCH_WARNINGS=0
    else
        CHECKPATCH_ERRORS=0
        CHECKPATCH_WARNINGS=0
    fi
    
    echo "  Errors: $CHECKPATCH_ERRORS"
    echo "  Warnings: $CHECKPATCH_WARNINGS"
else
    echo -e "${RED}✗ checkpatch.pl not found${NC}"
fi

# 3. Custom Kernel Driver Analysis
print_section "Custom Kernel Driver Analysis"

# Check for common kernel driver issues
echo "Running custom driver checks..."

# Initialize counters
CUSTOM_ISSUES=0

# Check for potential issues
check_file() {
    local file="$1"
    local basename=$(basename "$file")
    local report="$ANALYSIS_DIR/reports/custom-$basename.txt"
    
    echo "Custom analysis for $basename" > "$report"
    echo "===============================" >> "$report"
    echo "" >> "$report"
    
    # Check for missing error handling
    echo "Checking for missing error handling..." >> "$report"
    grep -n "= .*(" "$file" | grep -v "if\|while\|for\|return" | grep -v "err\|ret\|result" >> "$report" || true
    
    # Check for potential memory leaks
    echo "" >> "$report"
    echo "Checking for potential memory leaks..." >> "$report"
    grep -n "alloc\|kmalloc\|kzalloc" "$file" >> "$report" || true
    grep -n "free\|kfree" "$file" >> "$report" || true
    
    # Check for hardcoded values
    echo "" >> "$report"
    echo "Checking for hardcoded values..." >> "$report"
    grep -n "[0-9]\{3,\}" "$file" | grep -v "#define\|enum\|const" >> "$report" || true
    
    # Check for missing annotations
    echo "" >> "$report"
    echo "Checking for missing __iomem annotations..." >> "$report"
    grep -n "void \*" "$file" | grep -v "__iomem" >> "$report" || true
    
    # Count lines in report (excluding headers)
    local issues=$(wc -l < "$report")
    if [ "$issues" -gt 10 ]; then
        CUSTOM_ISSUES=$((CUSTOM_ISSUES + issues - 10))
    fi
}

# Run custom checks on all C files
for file in "$DRIVER_DIR"/*.c; do
    if [ -f "$file" ]; then
        check_file "$file"
    fi
done

echo -e "${GREEN}✓ Custom analysis complete${NC}"
echo "  Potential issues: $CUSTOM_ISSUES"

# 4. Summary Report
print_section "Analysis Summary"

cat > "$ANALYSIS_DIR/reports/summary.txt" << EOF
ADIN2111 Static Code Analysis Summary
====================================
Date: $(date)
Driver Path: $DRIVER_DIR

CppCheck Results:
  Errors: $CPPCHECK_ERRORS
  Warnings: $CPPCHECK_WARNINGS
  Style Issues: $CPPCHECK_STYLE

Checkpatch Results:
  Errors: $CHECKPATCH_ERRORS
  Warnings: $CHECKPATCH_WARNINGS

Custom Analysis:
  Potential Issues: $CUSTOM_ISSUES

Total Issues Found: $((CPPCHECK_ERRORS + CPPCHECK_WARNINGS + CHECKPATCH_ERRORS + CHECKPATCH_WARNINGS + CUSTOM_ISSUES))

Recommendations:
1. Fix all checkpatch errors (coding style violations)
2. Address cppcheck warnings and errors
3. Review custom analysis findings for potential improvements
4. Consider adding static analysis to CI pipeline

Files Analyzed:
EOF

# List analyzed files
for file in "$DRIVER_DIR"/*.c "$DRIVER_DIR"/*.h; do
    if [ -f "$file" ]; then
        echo "  $(basename "$file")" >> "$ANALYSIS_DIR/reports/summary.txt"
    fi
done

echo ""
echo -e "${GREEN}Analysis complete!${NC}"
echo "Reports saved to: $ANALYSIS_DIR/reports/"
echo ""

# Display summary
cat "$ANALYSIS_DIR/reports/summary.txt"

# Exit with error code if issues found
TOTAL_ISSUES=$((CPPCHECK_ERRORS + CHECKPATCH_ERRORS))
if [ "$TOTAL_ISSUES" -gt 0 ]; then
    echo -e "\n${RED}⚠️  Found $TOTAL_ISSUES critical issues that should be fixed${NC}"
    exit 1
else
    echo -e "\n${GREEN}✓ No critical issues found${NC}"
    exit 0
fi