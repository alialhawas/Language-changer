#!/bin/bash
set -euo pipefail

pkill -x Dodoma || true
rm -rf /Applications/Dodoma.app
tccutil reset Accessibility com.ali.dodoma || true
tccutil reset ListenEvent com.ali.dodoma || true

echo "Dodoma removed and privacy grants reset."
echo "The 'Dodoma Dev' code-signing certificate, its private key and its trust"
echo "setting remain in the login keychain. To remove those as well, run:"
echo "    security delete-identity -c \"Dodoma Dev\" -t \"\$HOME/Library/Keychains/login.keychain-db\""
