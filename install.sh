#!/usr/bin/env bash
# NavaTunnel one-line installer — resilient multi-mirror download & auto-setup.
# روش استفاده: bash <(curl -fsSL https://raw.githubusercontent.com/admin6501/NavaTunnel/main/install.sh)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "اسکریپت را با دسترسی روت یا sudo اجرا کنید." >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Display NavaTunnel logo banner
clear 2>/dev/null || true
echo -e "\033[0;36m"
cat << 'EOF'
       NavaTunnel
EOF
echo -e "\033[0m"
echo -e "\033[0;36m==============================================================\033[0m"
echo -e "\033[1;32m     نصب‌کننده تونل معکوس NavaTunnel\033[0m"
echo -e "\033[0;36m==============================================================\033[0m"
echo -e "\033[0;33m[*] در حال دریافت اسکریپت اصلی مدیریت...\033[0m"

URLS=(
    "https://raw.githubusercontent.com/admin6501/NavaTunnel/main/NavaTunnel.sh"
    "https://mirror.ghproxy.com/https://raw.githubusercontent.com/admin6501/NavaTunnel/main/NavaTunnel.sh"
    "https://ghproxy.net/https://raw.githubusercontent.com/admin6501/NavaTunnel/main/NavaTunnel.sh"
    "https://fastly.jsdelivr.net/gh/admin6501/NavaTunnel@main/NavaTunnel.sh"
)

DOWNLOADED=0
for U in "${URLS[@]}"; do
    if curl -fsSL --connect-timeout 8 --max-time 40 "$U" -o "$TMP/NavaTunnel.sh" 2>/dev/null && [[ -s "$TMP/NavaTunnel.sh" ]]; then
        if bash -n "$TMP/NavaTunnel.sh" 2>/dev/null; then
            DOWNLOADED=1
            break
        fi
    fi
done

if [[ "$DOWNLOADED" -ne 1 ]]; then
    echo "دریافت NavaTunnel.sh از گیت‌هاب و نشانی‌های جایگزین ناموفق بود." >&2
    exit 1
fi

curl -fsSL --connect-timeout 8 --max-time 40 \
    "https://raw.githubusercontent.com/admin6501/NavaTunnel/main/NavaTunnel-traffic.sh" \
    -o "$TMP/NavaTunnel-traffic.sh"
bash -n "$TMP/NavaTunnel-traffic.sh"
chmod +x "$TMP/NavaTunnel.sh"
mkdir -p /usr/local/bin
install -m 755 "$TMP/NavaTunnel-traffic.sh" /usr/local/bin/NavaTunnel-traffic.sh
cp "$TMP/NavaTunnel.sh" /usr/local/bin/NavaTunnel.sh
cp "$TMP/NavaTunnel.sh" /usr/local/bin/NavaTunnel
chmod +x /usr/local/bin/NavaTunnel.sh /usr/local/bin/NavaTunnel
ln -sf /usr/local/bin/NavaTunnel.sh /usr/local/bin/gre.sh 2>/dev/null || true

bash /usr/local/bin/NavaTunnel "$@"

echo -e "\033[1;32mنصب NavaTunnel پایان یافت\033[0m"
echo ""

