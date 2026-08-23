#!/bin/bash
set -euo pipefail

tccutil reset Accessibility com.ali.dodoma || true
tccutil reset ListenEvent com.ali.dodoma || true

echo "Accessibility and Input Monitoring grants reset for com.ali.dodoma."
