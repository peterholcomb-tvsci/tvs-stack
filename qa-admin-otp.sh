#!/usr/bin/env bash
# qa-admin-otp.sh — print a current TOTP 2FA code for the local 'qaadmin'
# Django admin user (created for VERCM QA). LOCAL DEV ONLY.
#
# Usage:  ./qa-admin-otp.sh
# The stack must be up (backend container running). Outputs a 6-digit code
# plus how many seconds it stays valid. Re-run for a fresh code.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

docker compose exec -T -w /opt/app/src backend python manage.py shell -c "
import time
from django_otp.plugins.otp_totp.models import TOTPDevice
from django_otp.oath import totp
d = TOTPDevice.objects.filter(user__username='qaadmin').first()
if not d:
    print('NO_DEVICE: qaadmin TOTP device not found (run vercm-1200-make-admin.py)')
else:
    code = str(totp(d.bin_key, step=d.step, t0=d.t0, digits=d.digits, drift=0)).zfill(d.digits)
    print(code, '(valid', d.step - (int(time.time()) % d.step), 'more seconds)')
" 2>/dev/null | grep -E '^[0-9]{6} |NO_DEVICE' | tail -1
