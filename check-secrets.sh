#!/bin/bash
# Scan git diff for common secret patterns
# Usage: check-secrets.sh [--staged] [--recent N]
# --staged: scan staged changes (for pre-commit hook)
# --recent N: scan last N commits

set -e

PATTERNS=(
    "PRIVATE_KEY"
    "client_secret"
    "CLIENT_SECRET"
    "api_key"
    "API_KEY"
    "ANTHROPIC_API_KEY"
    "GITHUB_CLIENT_SECRET"
    "password\s*=\s*['\"][^'\"]{8,}"
    "secret\s*=\s*['\"][^'\"]{8,}"
    "token\s*=\s*['\"][^'\"]{8,}"
    "-----BEGIN.*PRIVATE KEY-----"
    "sk-[a-zA-Z0-9]{20,}"
    "ghp_[a-zA-Z0-9]{36}"
    "ghs_[a-zA-Z0-9]{36}"
)

if [[ "$1" == "--staged" ]]; then
    DIFF=$(git diff --cached)
elif [[ "$1" == "--recent" ]]; then
    N=${2:-3}
    DIFF=$(git log -p -${N} --no-merges)
else
    DIFF=$(git diff HEAD~1..HEAD 2>/dev/null || git diff --cached)
fi

FOUND=0
for pattern in "${PATTERNS[@]}"; do
    if echo "$DIFF" | grep -qE "^\+.*${pattern}" 2>/dev/null; then
        echo "WARNING: POSSIBLE SECRET DETECTED: pattern '$pattern'"
        echo "$DIFF" | grep -nE "^\+.*${pattern}" | head -5
        FOUND=1
    fi
done

if [[ $FOUND -eq 1 ]]; then
    echo ""
    echo "Secret scan failed. Review the above matches before committing."
    echo "If these are false positives, check your .gitignore and .env files."
    exit 1
fi

exit 0
