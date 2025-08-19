#!/bin/bash
# Generate changelog from git history

echo "# CHANGELOG"
echo ""
echo "## Latest Changes"
echo ""
git log --oneline -10
echo ""
echo "Generated on $(date)"
