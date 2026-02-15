#!/bin/bash
# Pre-commit hook example for ai-orchestrator
# Install: cp scripts/pre-commit-example.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
#
# This hook runs secret scanning before each commit to prevent accidental leaks

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "Running pre-commit checks..."

# Check for .env files being committed
if git diff --cached --name-only | grep -qE '^.env$'; then
    echo -e "${RED}ERROR: .env file is staged for commit!${NC}"
    echo "Remove it from staging: git reset HEAD .env"
    exit 1
fi

# Check for common secret patterns in staged files
echo "Scanning for secrets..."

STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM)
if [ -z "$STAGED_FILES" ]; then
    exit 0
fi

# Scan staged content
SECRETS_FOUND=false

for file in $STAGED_FILES; do
    # Skip binary files and certain extensions
    if [[ "$file" =~ \.(png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ ]]; then
        continue
    fi
    
    # Check for secret patterns
    if git show :"$file" 2>/dev/null | grep -E '(api[_-]?key|secret|token|password|PRIVATE KEY|BEGIN [A-Z ]*PRIVATE KEY)' | grep -qvE '(example|placeholder|your-|dummy|test)'; then
        echo -e "${YELLOW}WARNING: Potential secret pattern in $file${NC}"
        SECRETS_FOUND=true
    fi
done

if [ "$SECRETS_FOUND" = true ]; then
    echo ""
    echo -e "${RED}Potential secrets detected in staged files!${NC}"
    echo "Review your changes carefully."
    echo "To bypass this check (NOT RECOMMENDED): git commit --no-verify"
    exit 1
fi

echo -e "${GREEN}Pre-commit checks passed!${NC}"
exit 0
