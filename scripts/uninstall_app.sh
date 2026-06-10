#!/bin/zsh

set -euo pipefail

/usr/bin/killall AIMeter 2>/dev/null || true
/usr/bin/sudo /bin/rm -rf "/Applications/AI Meter.app"
/usr/bin/sudo /usr/sbin/pkgutil --forget com.anthonylimo.aimeter.pkg >/dev/null \
    2>&1 || true

echo "AI Meter was removed from /Applications."
