#!/bin/bash
set -euo pipefail

pkill -x Dodoma || true
rm -rf /Applications/Dodoma.app
tccutil reset Accessibility com.ali.dodoma || true
tccutil reset ListenEvent com.ali.dodoma || true

echo "Dodoma removed and privacy grants reset."
