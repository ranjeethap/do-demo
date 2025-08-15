#!/bin/bash
# git.sh - helper for version bump and push

set -e

bump() {
    echo "Bumping app version..."
    NEW_TAG=$(date +%Y%m%d%H%M%S)
    echo $NEW_TAG > VERSION
    git add VERSION
    git commit -m "Bump version to $NEW_TAG"
}

push() {
    echo "Pushing changes to origin..."
    git push origin main
}

case "$1" in
    bump) bump ;;
    push) push ;;
    *) echo "Usage: $0 {bump|push}" ; exit 1 ;;
esac
