#!/usr/bin/env bash
# CI entry point. Modes:
#   check — pub get + gen-l10n (when l10n.yaml exists) + analyze + test
#           for every package
#   build — everything in `check`, plus the desktop_app Windows release
#           build
# The windows/ runner is committed (custom app_icon.ico included), so no
# bootstrap step is needed.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-check}"
if [ "$MODE" != "check" ] && [ "$MODE" != "build" ]; then
  echo "usage: $0 [check|build]" >&2
  exit 2
fi
FAIL=0
for p in packages/* apps/desktop_app; do
  echo "== $p =="
  (cd "$p" \
    && flutter pub get \
    && if [ -f l10n.yaml ]; then flutter gen-l10n; fi \
    && flutter analyze && flutter test) || FAIL=1
done
if [ "$MODE" = "build" ]; then
  echo "== apps/desktop_app: build windows (release) =="
  (cd apps/desktop_app && flutter build windows --release) || FAIL=1
fi
exit $FAIL
