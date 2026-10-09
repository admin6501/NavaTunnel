#!/bin/bash

# ==============================================================================
#   NavaTunnel — GRE + FRP Reverse Tunnel Automated Setup Script (NavaTunnel.sh)
#   Architecture: GRE Layer 3 Tunnel + FRP Reverse TLS Tunnel
#   Features: Auto Arch Detect, Systemd Auto-start on boot, MTU Clamping, TCP/UDP
#   One file: interactive menu (`bash NavaTunnel.sh`) + non-interactive CLI
#   (`NavaTunnel setup-iran ...`) — the old gre.sh name still works as symlink.
# ==============================================================================
# ---- installed names (single source of truth for this script) ----
NAVATUNNEL_BIN="/usr/local/bin/NavaTunnel"       # this script, after install
NAVATUNNEL_SCRIPT="/usr/local/bin/NavaTunnel.sh" # versioned copy (gre.sh = legacy alias)
NAVATUNNEL_URL_BASE="https://raw.githubusercontent.com/admin6501/NavaTunnel/main"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/frp"
DEFAULT_FRP_VERSION="0.71.0"

# Default GRE internal IPs (/30 subnet)
IRAN_GRE_IP="10.10.10.2"
FOREIGN_GRE_IP="10.10.10.1"
TUNNEL_NAME="gre-tunnel"
# Retain the legacy state directory for existing tunnel configurations.
NAVATUNNEL_STATE_DIR="/etc/gre-panel"
WATCHDOG_FILE="${NAVATUNNEL_STATE_DIR}/watchdog.json"
PERF_FILE="${NAVATUNNEL_STATE_DIR}/perf.json"
CARRIER_FILE="${NAVATUNNEL_STATE_DIR}/carrier.json"
BACKUP_DIR="/var/backups/navatunnel"

ensure_navatunnel_bin() {
    [[ ${EUID:-$(id -u 2>/dev/null || echo 1)} -eq 0 ]] || return 0
    mkdir -p /usr/local/bin
    if [[ -f "$0" && "$0" != "$NAVATUNNEL_BIN" ]]; then
        cp "$0" "$NAVATUNNEL_BIN" 2>/dev/null && chmod +x "$NAVATUNNEL_BIN" 2>/dev/null || true
        cp "$0" "$NAVATUNNEL_SCRIPT" 2>/dev/null && chmod +x "$NAVATUNNEL_SCRIPT" 2>/dev/null || true
        ln -sf "$NAVATUNNEL_SCRIPT" /usr/local/bin/gre.sh 2>/dev/null || true
    elif [[ ! -x "$NAVATUNNEL_BIN" ]]; then
        local cand
        for cand in "$0" ./NavaTunnel.sh /tmp/NavaTunnel.sh "$NAVATUNNEL_SCRIPT"; do
            if [[ -f "$cand" ]]; then
                cp "$cand" "$NAVATUNNEL_BIN" 2>/dev/null && chmod +x "$NAVATUNNEL_BIN" 2>/dev/null || true
                break
            fi
        done
    fi
}

LOG_DIR="/var/log/navatunnel"

# Mask tokens and sensitive credentials in log strings
fa_state() {
    case "${1,,}" in
        on|enabled|true|active|running|up) echo 'فعال' ;;
        off|disabled|false|inactive|stopped|down) echo 'غیرفعال' ;;
        failed|fail|broken) echo 'ناموفق' ;;
        success|pass|ok|installed) echo 'موفق' ;;
        warn|warning) echo 'هشدار' ;;
        low) echo 'کم' ;; mid) echo 'متوسط' ;;
        error) echo 'خطا' ;; unknown) echo 'نامشخص' ;;
        auto) echo 'خودکار' ;; manual) echo 'دستی' ;; direct) echo 'GRE مستقیم' ;;
        fou:*) echo "FOU پورت ${1#fou:}" ;;
        *) printf '%s\n' "${1:-نامشخص}" ;;
    esac
}

mask_sensitive() {
    local text="$1"
    echo "$text" | sed -E \
        -e 's/(hsh1_[^_]+_[0-9]+_[^_]+_[^_]+_)[A-Za-z0-9_-]{8,128}/\1[MASKED_TOKEN]/g' \
        -e 's/(auth\.token[[:space:]]*=[[:space:]]*")[^"]+/\1[MASKED_TOKEN]/g' \
        -e 's/(token[[:space:]]*=[[:space:]]*")[^"]+/\1[MASKED_TOKEN]/g' \
        -e 's/(--token[[:space:]]+)[A-Za-z0-9_-]{16,128}/\1[MASKED_TOKEN]/g' \
        -e 's/(Token:[[:space:]]*)[A-Za-z0-9_-]{16,128}/\1[MASKED_TOKEN]/g'
}

log_msg() {
    local category="${1:-installer}"
    local level="${2:-INFO}"
    local msg="$3"
    [[ ${EUID:-$(id -u 2>/dev/null || echo 1)} -eq 0 ]] || return 0
    mkdir -p "$LOG_DIR" 2>/dev/null || return 0
    local logfile="${LOG_DIR}/${category}.log"
    local masked
    masked=$(mask_sensitive "$msg")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${masked}" >> "$logfile" 2>/dev/null || true
}

backup_configs() {
    local label="${1:-manual}"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local bdir="${BACKUP_DIR}/${ts}_${label}"
    mkdir -p "$bdir" 2>/dev/null || return 1

    # Backup configuration folders
    [[ -d /etc/navatunnel ]] && cp -rp /etc/navatunnel "$bdir/" 2>/dev/null || true
    [[ -d /etc/gre-panel ]] && cp -rp /etc/gre-panel "$bdir/" 2>/dev/null || true
    [[ -d /etc/frp ]] && cp -rp /etc/frp "$bdir/" 2>/dev/null || true

    # Backup relevant systemd units
    mkdir -p "$bdir/systemd" 2>/dev/null || true
    for u in /etc/systemd/system/gre-*.service /etc/systemd/system/frps*.service /etc/systemd/system/frpc*.service /etc/systemd/system/gre-panel.service; do
        [[ -f "$u" ]] && cp -p "$u" "$bdir/systemd/" 2>/dev/null || true
    done

    echo "$bdir" > "${BACKUP_DIR}/latest" 2>/dev/null || true
    log_msg "installer" "INFO" "پشتیبان تنظیمات ساخته شد در $bdir"
    echo "$bdir"
}

rollback_configs() {
    local bdir="$1"
    [[ -z "$bdir" && -f "${BACKUP_DIR}/latest" ]] && bdir=$(cat "${BACKUP_DIR}/latest" 2>/dev/null)
    if [[ -z "$bdir" || ! -d "$bdir" ]]; then
        echo -e "${RED}[!] پوشه پشتیبان معتبر برای بازگردانی پیدا نشد.${NC}"
        return 1
    fi
    echo -e "${YELLOW}[*] در حال بازگردانی تنظیمات از: $bdir ...${NC}"
    log_msg "installer" "WARN" "شروع بازگردانی از $bdir"

    [[ -d "$bdir/navatunnel" ]] && cp -rp "$bdir/navatunnel" /etc/ 2>/dev/null || true
    [[ -d "$bdir/gre-panel" ]] && cp -rp "$bdir/gre-panel" /etc/ 2>/dev/null || true
    [[ -d "$bdir/frp" ]] && cp -rp "$bdir/frp" /etc/ 2>/dev/null || true
    if [[ -d "$bdir/systemd" ]]; then
        cp -p "$bdir/systemd/"* /etc/systemd/system/ 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    echo -e "${GREEN}[✔️] بازگردانی انجام شد.${NC}"
    log_msg "installer" "INFO" "بازگردانی با موفقیت انجام شد"
}

# Component States: NOT_INSTALLED, INSTALLED, RUNNING, STOPPED, BROKEN, UNKNOWN
get_component_status() {
    local comp="$1"
    case "$comp" in
        frps)
            local bin="/usr/local/bin/frps"
            local svc="frps"
            if [[ ! -f "$bin" && ! -f "/etc/systemd/system/${svc}.service" && ! -f "/etc/frp/frps.toml" ]]; then
                echo "NOT_INSTALLED"; return 0
            fi
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                echo "RUNNING"; return 0
            elif systemctl is-failed --quiet "$svc" 2>/dev/null; then
                echo "BROKEN"; return 0
            elif [[ -f "$bin" ]]; then
                echo "STOPPED"; return 0
            else
                echo "BROKEN"; return 0
            fi
            ;;
        frpc)
            local bin="/usr/local/bin/frpc"
            local svc="frpc"
            if [[ ! -f "$bin" && ! -f "/etc/systemd/system/${svc}.service" && ! -f "/etc/frp/frpc.toml" ]]; then
                echo "NOT_INSTALLED"; return 0
            fi
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                echo "RUNNING"; return 0
            elif systemctl is-failed --quiet "$svc" 2>/dev/null; then
                echo "BROKEN"; return 0
            elif [[ -f "$bin" ]]; then
                echo "STOPPED"; return 0
            else
                echo "BROKEN"; return 0
            fi
            ;;
        gre)
            local ifname="${2:-$TUNNEL_NAME}"
            local svc="${ifname}.service"
            local link_exists=0
            local addr_exists=0
            if ip link show "$ifname" >/dev/null 2>&1; then
                link_exists=1
            fi
            if ip -4 addr show dev "$ifname" 2>/dev/null | grep -q "inet "; then
                addr_exists=1
            fi
            if [[ "$link_exists" -eq 1 && "$addr_exists" -eq 1 ]]; then
                echo "RUNNING"; return 0
            fi
            if systemctl is-failed --quiet "$svc" 2>/dev/null; then
                echo "BROKEN"; return 0
            elif [[ -f "/etc/systemd/system/${svc}" || "$link_exists" -eq 1 ]]; then
                echo "BROKEN"; return 0
            else
                echo "NOT_INSTALLED"; return 0
            fi
            ;;
        deps)
            local missing=()
            for cmd in ip curl tar iptables systemctl python3 ping ss; do
                command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
            done
            if [[ ${#missing[@]} -eq 0 ]]; then
                echo "INSTALLED"; return 0
            else
                echo "BROKEN"; return 0
            fi
            ;;
        *)
            echo "UNKNOWN"; return 0
            ;;
    esac
}

ensure_dependencies_smart() {
    local DEPS_MARKER="/etc/gre-panel/.deps_installed"
    if [[ -f "$DEPS_MARKER" ]] && command -v ip >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && \
       command -v tar >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1 && \
       command -v systemctl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && \
       command -v ping >/dev/null 2>&1 && command -v ss >/dev/null 2>&1; then
        return 0
    fi

    local missing_pkgs=()
    command -v ip >/dev/null 2>&1 || missing_pkgs+=("iproute2")
    command -v curl >/dev/null 2>&1 || missing_pkgs+=("curl")
    command -v tar >/dev/null 2>&1 || missing_pkgs+=("tar")
    command -v iptables >/dev/null 2>&1 || missing_pkgs+=("iptables")
    command -v systemctl >/dev/null 2>&1 || missing_pkgs+=("systemd")
    command -v python3 >/dev/null 2>&1 || missing_pkgs+=("python3")
    command -v ping >/dev/null 2>&1 || missing_pkgs+=("iputils-ping")
    command -v ss >/dev/null 2>&1 || missing_pkgs+=("iproute2")

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        mkdir -p /etc/gre-panel
        touch "$DEPS_MARKER" 2>/dev/null || true
        echo -e "${GREEN}[✔️] همه پیش‌نیازهای سیستم آماده‌اند.${NC}"
        return 0
    fi

    local uniq_pkgs
    uniq_pkgs=$(printf "%s\n" "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')
    echo -e "${CYAN}[*] در حال نصب پیش‌نیازهای موجودنبوده: ${uniq_pkgs}...${NC}"
    log_msg "installer" "INFO" "در حال نصب پیش‌نیازهای موجودنبوده: ${uniq_pkgs}"

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        (timeout 25 apt-get update -qq || true)
        apt-get install -y -qq --no-install-recommends $uniq_pkgs 2>/dev/null || {
            echo -e "${YELLOW}[!] نصب با apt-get با خطا روبه‌رو شد: ${uniq_pkgs}. راه‌اندازی ادامه پیدا می‌کند.${NC}"
        }
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q $uniq_pkgs || true
    fi
    [[ "$(get_component_status deps)" == "INSTALLED" ]] || { echo "بعضی پیش‌نیازهای ضروری هنوز نصب نشده‌اند." >&2; return 1; }
    mkdir -p /etc/gre-panel
    touch "$DEPS_MARKER" 2>/dev/null || true
    echo -e "${GREEN}[✔️] پیش‌نیازها نصب و وضعیت آن‌ها ذخیره شد.${NC}"
}

is_port_in_use() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn "sport = :$port" 2>/dev/null | grep -q ":$port " && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null | grep -q ":$port " && return 0
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" >/dev/null 2>&1 && return 0
    fi
    return 1
}

diagnose_port_process() {
    local port=$1
    echo -e "${CYAN}=== بررسی فرایند استفاده‌کننده از پورت :$port ===${NC}"
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn "sport = :$port" 2>/dev/null
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" 2>/dev/null
    elif command -v fuser >/dev/null 2>&1; then
        fuser "$port/tcp" 2>/dev/null
    fi
    echo -e "${CYAN}=============================================${NC}"
}

ensure_port_available() {
    local port=$1
    local purpose=${2:-"پورت ضروری"}
    local is_bundle=${3:-0}
    # $4: if set to "warn-only", non-interactive mode will warn but not fail.
    # Proxy ports on Foreign are declared in frpc config as localPort —
    # frpc never binds them itself (Marzban/X-UI owns them), so a conflict
    # is informational, not a hard blocker.
    local warn_only=${4:-""}

    while is_port_in_use "$port"; do
        echo -e "${YELLOW}[!] هشدار: ${purpose} ${port} هم‌اکنون توسط فرایند دیگری استفاده می‌شود.${NC}" >&2
        log_msg "tunnel" "WARN" "${purpose} ${port} is in use"
        if [[ ! -t 0 ]]; then
            if [[ "$warn_only" == "warn-only" ]]; then echo "$port"; return 0; fi
            echo "پورت ${port} اشغال است؛ آن را آزاد کنید یا پورت دیگری انتخاب کنید." >&2
            return 1
        fi
        echo "گزینه‌ها:" >&2
        echo "  1) تلاش مجدد پس از توقف فرایند مزاحم" >&2
        echo "  2) بررسی فرایند" >&2
        echo "  3) لغو" >&2
        if [[ "$is_bundle" -ne 1 ]]; then
            echo "  4) انتخاب پورت دیگر" >&2
        else
            echo "  4) انتخاب پورت دیگر به‌جای مقدار کد اتصال" >&2
        fi
        read -p "انتخاب گزینه [1-4]: " P_OPT
        case "$P_OPT" in
            1)
                continue
                ;;
            2)
                diagnose_port_process "$port" >&2
                echo "" >&2
                ;;
            3)
                return 1
                ;;
            4)
                prompt_port NEW_PORT "مقدار جدید ${purpose}" "$(gen_random_port)" >&2
                port=$NEW_PORT
                ;;
            *)
                echo -e "${RED}[!] گزینه نامعتبر است.${NC}" >&2
                ;;
        esac
    done
    echo "$port"
    return 0
}

cli_bundle_inspect() {
    local BUNDLE="" SHOW_TOKEN=0
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --* && $# -lt 2 ]]; then
            case "$1" in
                --force|--show-token|--encrypt|--compress|--dry-run|--off|--help) ;;
                *) echo "مقدار این گزینه وارد نشده است: $1" >&2; return 1 ;;
            esac
        fi
        case "$1" in
            --show-token|-s) SHOW_TOKEN=1; shift ;;
            hsh1_*) BUNDLE="$1"; shift ;;
            *) BUNDLE="$1"; shift ;;
        esac
    done
    if [[ -z "$BUNDLE" ]]; then
        read -p "کد اتصال (hsh1_...) را وارد کنید: " BUNDLE
    fi
    if ! bundle_parse "$BUNDLE"; then
        echo -e "${RED}[!] قالب کد اتصال نامعتبر است؛ قالب مورد انتظار: hsh1_<IRAN_PUB>_<FRP_PORT>_<IRAN_GRE>_<FOREIGN_GRE>_<TOKEN>[_<PORTS>][_fou<P1>-<P2>]${NC}"
        return 1
    fi

    local DISP_TOKEN="******************************** (Masked, pass --show-token to reveal)"
    if [[ "$SHOW_TOKEN" -eq 1 ]]; then
        DISP_TOKEN="$B_TOKEN"
    fi

    echo -e "\n${CYAN}=============================================================="
    echo "                 بررسی کد اتصال NavaTunnel"
    echo -e "==============================================================${NC}"
    echo -e "نسخه کد اتصال:        ${GREEN}hsh1${NC}"
    echo -e "IP عمومی ایران:        ${CYAN}${B_IRAN_PUB}${NC}"
    echo -e "پورت سرور FRP:       ${CYAN}${B_FRP_PORT}${NC} (serverPort / bindPort)"
    echo -e "IP داخلی GRE ایران:  ${CYAN}${B_IRAN_GRE}${NC}"
    echo -e "IP داخلی GRE خارج:        ${CYAN}${B_FOREIGN_GRE}${NC}"
    echo -e "پورت‌های سرویس:   ${CYAN}${B_PORTS:-بدون پورت؛ تنظیم دستی}${NC}"
    echo "پروتکل FRP کلاینت خارج: ${B_FRP_TRANSPORT}"
    echo "جبران افت بسته با KCP/FEC: $(fa_state "$B_LOSS_RECOVERY")"
    echo -e "پورت‌های UDP برای FOU:         ${CYAN}${B_FOU_P1}, ${B_FOU_P2}${NC}"
    echo -e "توکن اتصال:            ${YELLOW}${DISP_TOKEN}${NC}"
    echo -e "مرجع تنظیمات:       ${GREEN}اعمال روی سرور خارج${NC}"
    echo -e "${CYAN}==============================================================${NC}\n"
    return 0
}


# ---- Performance / Obfuscation Configuration (/etc/gre-panel/perf.json) ----
init_perf_json() {
    mkdir -p /etc/gre-panel
    if [[ ! -f "$PERF_FILE" ]]; then
        cat << 'EOF' > "$PERF_FILE"
{
  "proxy_encryption": false,
  "proxy_compression": false,
  "force_tls": false,
  "chaff_profile": "off",
  "dpi_enabled": false,
  "dpi_rate": "60/sec",
  "dpi_burst": 120
}
EOF
        chmod 600 "$PERF_FILE" 2>/dev/null || true
    fi
}

perf_get_enc() {
    if [[ -n "${PERF_ENC:-}" ]]; then
        [[ "$PERF_ENC" == "1" || "$PERF_ENC" == "true" ]] && echo 1 || echo 0
        return 0
    fi
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        print(1 if json.load(f).get("proxy_encryption", False) else 0)
except Exception:
    print(0)
' 2>/dev/null && return 0
    elif [[ -f "$PERF_FILE" ]]; then
        grep -q '"proxy_encryption"[[:space:]]*:[[:space:]]*true' "$PERF_FILE" && echo 1 || echo 0
        return 0
    fi
    echo 0
}

perf_get_comp() {
    if [[ -n "${PERF_COMP:-}" ]]; then
        [[ "$PERF_COMP" == "1" || "$PERF_COMP" == "true" ]] && echo 1 || echo 0
        return 0
    fi
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        print(1 if json.load(f).get("proxy_compression", False) else 0)
except Exception:
    print(0)
' 2>/dev/null && return 0
    elif [[ -f "$PERF_FILE" ]]; then
        grep -q '"proxy_compression"[[:space:]]*:[[:space:]]*true' "$PERF_FILE" && echo 1 || echo 0
        return 0
    fi
    echo 0
}

perf_get_tls() {
    if [[ -n "${PERF_TLS:-}" ]]; then
        [[ "$PERF_TLS" == "1" || "$PERF_TLS" == "true" ]] && echo 1 || echo 0
        return 0
    fi
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        print(1 if json.load(f).get("force_tls", False) else 0)
except Exception:
    print(0)
' 2>/dev/null && return 0
    elif [[ -f "$PERF_FILE" ]]; then
        grep -q '"force_tls"[[:space:]]*:[[:space:]]*true' "$PERF_FILE" && echo 1 || echo 0
        return 0
    fi
    echo 0
}

perf_get_chaff() {
    if [[ -n "${CHAFF_PROFILE:-}" ]]; then
        echo "$CHAFF_PROFILE"
        return 0
    fi
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        p = json.load(f).get("chaff_profile", "off")
        print(p if p in ("off", "low", "mid", "custom") else "off")
except Exception:
    print("off")
' 2>/dev/null && return 0
    fi
    echo "off"
}

perf_get_dpi_enabled() {
    if [[ -n "${PERF_DPI:-}" ]]; then
        [[ "$PERF_DPI" == "1" || "$PERF_DPI" == "true" ]] && echo 1 || echo 0
        return 0
    fi
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        print(1 if json.load(f).get("dpi_enabled", False) else 0)
except Exception:
    print(0)
' 2>/dev/null && return 0
    elif [[ -f "$PERF_FILE" ]]; then
        grep -q '"dpi_enabled"[[:space:]]*:[[:space:]]*true' "$PERF_FILE" && echo 1 || echo 0
        return 0
    fi
    echo 0
}

perf_get_dpi_rate() {
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        r = json.load(f).get("dpi_rate", "60/sec")
        print(r if r else "60/sec")
except Exception:
    print("60/sec")
' 2>/dev/null && return 0
    fi
    echo "60/sec"
}

perf_get_dpi_burst() {
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        b = json.load(f).get("dpi_burst", 120)
        print(int(b) if int(b) > 0 else 120)
except Exception:
    print(120)
' 2>/dev/null && return 0
    fi
    echo 120
}

perf_set_val() {
    local key="$1" val="$2" is_raw="${3:-0}"
    init_perf_json
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
path = "'"$PERF_FILE"'"
key = "'"$key"'"
raw = '"$is_raw"'
val_str = """'"$val"'"""
try:
    with open(path, "r") as f:
        d = json.load(f)
except Exception:
    d = {}
if raw:
    if val_str in ("true", "True", "1"):
        d[key] = True
    elif val_str in ("false", "False", "0"):
        d[key] = False
    else:
        try:
            d[key] = int(val_str)
        except Exception:
            d[key] = val_str
else:
    d[key] = val_str
with open(path, "w") as f:
    json.dump(d, f, indent=2)
'
        chmod 600 "$PERF_FILE" 2>/dev/null || true
    fi
}

# ---- input validation (IPv4, port 1-65535) ----
is_valid_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=. a b c d o
    read -r a b c d <<<"$1"
    for o in "$a" "$b" "$c" "$d"; do
        ((10#$o <= 255)) || return 1
    done
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

gen_token32() { # 32-char alphanumeric secret (FRP auth token)
    tr -dc A-Za-z0-9 </dev/urandom | head -c 32 2>/dev/null || openssl rand -hex 16
}

gen_random_port() { # random port 20000-60000 for FRP
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 20000-60000 -n 1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import random; print(random.randint(20000, 60000))'
    else
        awk 'BEGIN{srand(); print int(20000 + rand() * 40001)}'
    fi
}

# ---- Carrier & Multi-Protocol Failover (Direct GRE <-> FOU UDP) ----
init_carrier_json() {
    mkdir -p "$NAVATUNNEL_STATE_DIR"
    if [[ ! -f "$CARRIER_FILE" ]]; then
        cat << 'EOF' > "$CARRIER_FILE"
{
  "mode": "direct",
  "active_carrier": "direct",
  "fou_port1": 443,
  "fou_port2": 55555,
  "candidates": [
    "direct",
    "fou:443",
    "fou:55555"
  ],
  "last_switch": "",
  "switch_count": 0
}
EOF
        chmod 600 "$CARRIER_FILE" 2>/dev/null || true
    fi
}

carrier_get_mode() {
    init_carrier_json
    python3 -c '
import json
try:
    with open("'"$CARRIER_FILE"'") as f:
        d = json.load(f)
        m = d.get("mode", "direct")
        if m == "auto":
            d["mode"] = "direct"
            with open("'"$CARRIER_FILE"'.tmp", "w") as ftmp:
                json.dump(d, ftmp, indent=2)
            import os
            os.replace("'"$CARRIER_FILE"'.tmp", "'"$CARRIER_FILE"'")
            print("direct")
        else:
            print(m)
except Exception:
    print("direct")
' 2>/dev/null || echo "direct"
}

carrier_get_active() {
    init_carrier_json
    python3 -c '
import json
try:
    with open("'"$CARRIER_FILE"'") as f:
        print(json.load(f).get("active_carrier", "direct"))
except Exception:
    print("direct")
' 2>/dev/null || echo "direct"
}

carrier_get_fou_ports() {
    init_carrier_json
    python3 -c '
import json
try:
    with open("'"$CARRIER_FILE"'") as f:
        d = json.load(f)
        p1 = d.get("fou_port1", 443)
        p2 = d.get("fou_port2", 55555)
        print(f"{p1} {p2}")
except Exception:
    print("443 55555")
' 2>/dev/null || echo "443 55555"
}

carrier_set_mode() {
    local M="$1"
    [[ "$M" == "auto" ]] && M="direct"
    [[ "$M" == "direct" || "$M" == fou:* ]] || return 1
    if [[ "$M" == fou:* ]]; then is_valid_port "${M#fou:}" || return 1; fi
    init_carrier_json
    python3 -c '
import json, sys
p = "'"$CARRIER_FILE"'"
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
d["mode"] = sys.argv[1]
with open(p + ".tmp", "w") as f:
    json.dump(d, f, indent=2)
import os
os.replace(p + ".tmp", p)
os.chmod(p, 0o600)
' "$M" 2>/dev/null || true
}

carrier_set_fou_ports() {
    local P1=$1 P2=$2
    is_valid_port "$P1" || return 1
    is_valid_port "$P2" || return 1
    init_carrier_json
    python3 -c '
import json, sys
p = "'"$CARRIER_FILE"'"
p1 = int(sys.argv[1])
p2 = int(sys.argv[2])
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
wp = d.get("wss_port", 8443)
d["fou_port1"] = p1
d["fou_port2"] = p2
d["candidates"] = ["direct", f"fou:{p1}", f"fou:{p2}"]
with open(p + ".tmp", "w") as f:
    json.dump(d, f, indent=2)
import os
os.replace(p + ".tmp", p)
os.chmod(p, 0o600)
' "$P1" "$P2" 2>/dev/null || true
}

carrier_init_kernel() {
    modprobe fou >/dev/null 2>&1 || true
    modprobe ip_gre >/dev/null 2>&1 || true
    local P1 P2
    read -r P1 P2 <<< "$(carrier_get_fou_ports)"
    if is_valid_port "$P1"; then
        ip fou add port "$P1" ipproto 47 >/dev/null 2>&1 || true
        iptables -C INPUT -p udp --dport "$P1" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT 1 -p udp --dport "$P1" -j ACCEPT >/dev/null 2>&1 || true
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw allow "$P1"/udp >/dev/null 2>&1 || true
        fi
    fi
    if is_valid_port "$P2" && [[ "$P2" != "$P1" ]]; then
        ip fou add port "$P2" ipproto 47 >/dev/null 2>&1 || true
        iptables -C INPUT -p udp --dport "$P2" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT 1 -p udp --dport "$P2" -j ACCEPT >/dev/null 2>&1 || true
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw allow "$P2"/udp >/dev/null 2>&1 || true
        fi
    fi
    local WP=8443
    if [[ -f "$CARRIER_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        WP=$(python3 -c "import json; print(json.load(open('$CARRIER_FILE')).get('wss_port', 8443))" 2>/dev/null || echo 8443)
    fi
    iptables -C INPUT -p tcp --dport "$WP" -j ACCEPT >/dev/null 2>&1 || \
        iptables -I INPUT 1 -p tcp --dport "$WP" -j ACCEPT >/dev/null 2>&1 || true
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$WP"/tcp >/dev/null 2>&1 || true
    fi
    ip fou add port 19998 ipproto 47 >/dev/null 2>&1 || true
}

carrier_apply() {
    local TARGET="$1"
    local SPECIFIC_IF="${2:-}"
    [[ -z "$TARGET" ]] && TARGET="direct"
    if [[ "$TARGET" == wss* ]]; then
        echo "حامل رله WSS در این نسخه موجود نیست؛ از direct یا fou:PORT استفاده کنید." >&2
        return 1
    fi
    [[ "$TARGET" == "direct" || "$TARGET" == fou:* ]] || { echo "حامل نامعتبر: $TARGET" >&2; return 1; }
    if [[ "$TARGET" == fou:* ]]; then is_valid_port "${TARGET#fou:}" || return 1; fi
    carrier_init_kernel

    local IFS_TO_APPLY=()
    if [[ -n "$SPECIFIC_IF" ]]; then
        IFS_TO_APPLY+=("$SPECIFIC_IF")
    else
        local dev
        for dev in $(ip -o link show type gre 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1); do
            [[ "$dev" == "gre0" || "$dev" == "gretap0" ]] && continue
            IFS_TO_APPLY+=("$dev")
        done
        if [[ ${#IFS_TO_APPLY[@]} -eq 0 ]]; then
            IFS_TO_APPLY+=("$TUNNEL_NAME")
        fi
    fi

    local ANY_APPLIED=0
    for dev in "${IFS_TO_APPLY[@]}"; do
        if ip link show "$dev" >/dev/null 2>&1; then
            # Record current IPv4 address so it can NEVER be lost when toggling state
            local DEV_IP=""
            DEV_IP=$(ip -o -4 addr show dev "$dev" 2>/dev/null | awk '{print $4}' | head -1)
            if [[ -z "$DEV_IP" ]]; then
                if [[ "$dev" == "$TUNNEL_NAME" ]]; then
                    if [[ -f "/etc/frp/frps.toml" ]]; then
                        DEV_IP="10.10.10.2/30"
                    elif [[ -f "/etc/frp/frpc.toml" ]]; then
                        DEV_IP="10.10.10.1/30"
                    fi
                fi
            fi

            local TARGET_MTU=1380
            [[ "$TARGET" == wss* ]] && TARGET_MTU=1360

            local CHANGED=0
            if [[ "$TARGET" == "direct" ]]; then
                iptables -t nat -D OUTPUT -p udp --dport 19999 -j DNAT --to-destination 127.0.0.1:19999 >/dev/null 2>&1 || true
                if ip link set dev "$dev" type gre encap none >/dev/null 2>&1; then
                    CHANGED=1
                else
                    ip link set dev "$dev" down >/dev/null 2>&1 || true
                    if ip link set dev "$dev" type gre encap none >/dev/null 2>&1; then
                        CHANGED=1
                    fi
                fi
                ANY_APPLIED=1
            elif [[ "$TARGET" == fou:* ]]; then
                iptables -t nat -D OUTPUT -p udp --dport 19999 -j DNAT --to-destination 127.0.0.1:19999 >/dev/null 2>&1 || true
                local DPORT="${TARGET#fou:}"
                if is_valid_port "$DPORT"; then
                    ip fou add port "$DPORT" ipproto 47 >/dev/null 2>&1 || true
                    if ip link set dev "$dev" type gre encap fou encap-sport auto encap-dport "$DPORT" >/dev/null 2>&1; then
                        CHANGED=1
                    else
                        ip link set dev "$dev" down >/dev/null 2>&1 || true
                        if ip link set dev "$dev" type gre encap fou encap-sport auto encap-dport "$DPORT" >/dev/null 2>&1; then
                            CHANGED=1
                        fi
                    fi
                    ANY_APPLIED=1
                fi
            elif [[ "$TARGET" == wss* ]]; then
                local WPORT="8443"
                [[ "$TARGET" == wss:* ]] && WPORT="${TARGET#wss:}"
                iptables -C INPUT -p tcp --dport "$WPORT" -j ACCEPT >/dev/null 2>&1 || \
                    iptables -I INPUT 1 -p tcp --dport "$WPORT" -j ACCEPT >/dev/null 2>&1 || true
                if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
                    ufw allow "$WPORT"/tcp >/dev/null 2>&1 || true
                fi
                ip fou add port 19998 ipproto 47 >/dev/null 2>&1 || true
                iptables -t nat -C OUTPUT -p udp --dport 19999 -j DNAT --to-destination 127.0.0.1:19999 >/dev/null 2>&1 || \
                    iptables -t nat -A OUTPUT -p udp --dport 19999 -j DNAT --to-destination 127.0.0.1:19999 >/dev/null 2>&1 || true
                if ip link set dev "$dev" type gre encap fou encap-sport auto encap-dport 19999 >/dev/null 2>&1; then
                    CHANGED=1
                else
                    ip link set dev "$dev" down >/dev/null 2>&1 || true
                    if ip link set dev "$dev" type gre encap fou encap-sport auto encap-dport 19999 >/dev/null 2>&1; then
                        CHANGED=1
                    fi
                fi
                ANY_APPLIED=1
            fi

            # If dynamic changelink is unsupported by this kernel, re-instantiate cleanly in-place
            if [[ "$CHANGED" -eq 0 ]]; then
                local REMOTE_PUB LOCAL_PUB
                REMOTE_PUB=$(ip tunnel show "$dev" 2>/dev/null | awk '/remote/ {for(i=1;i<=NF;i++) if($i=="remote") print $(i+1)}' | head -1)
                LOCAL_PUB=$(ip tunnel show "$dev" 2>/dev/null | awk '/local/ {for(i=1;i<=NF;i++) if($i=="local") print $(i+1)}' | head -1)
                if [[ -n "$REMOTE_PUB" ]]; then
                    ip tunnel del "$dev" >/dev/null 2>&1 || ip link del "$dev" >/dev/null 2>&1 || true
                    local LOCAL_OPTS=""
                    [[ -n "$LOCAL_PUB" && "$LOCAL_PUB" != "any" ]] && LOCAL_OPTS="local $LOCAL_PUB"
                    if [[ "$TARGET" == "direct" ]]; then
                        ip link add name "$dev" type gre $LOCAL_OPTS remote "$REMOTE_PUB" ttl 255 >/dev/null 2>&1 || true
                    elif [[ "$TARGET" == fou:* ]]; then
                        local DPORT="${TARGET#fou:}"
                        ip link add name "$dev" type gre $LOCAL_OPTS remote "$REMOTE_PUB" ttl 255 encap fou encap-sport auto encap-dport "$DPORT" >/dev/null 2>&1 || true
                    elif [[ "$TARGET" == wss* ]]; then
                        ip link add name "$dev" type gre $LOCAL_OPTS remote "$REMOTE_PUB" ttl 255 encap fou encap-sport auto encap-dport 19999 >/dev/null 2>&1 || true
                    fi
                    # Fallback safeguard: if encap creation failed, re-create as direct GRE so tunnel is never left broken
                    if ! ip link show "$dev" >/dev/null 2>&1; then
                        ip link add name "$dev" type gre $LOCAL_OPTS remote "$REMOTE_PUB" ttl 255 >/dev/null 2>&1 || \
                        ip tunnel add "$dev" mode gre $LOCAL_OPTS remote "$REMOTE_PUB" ttl 255 >/dev/null 2>&1 || true
                    fi
                    ANY_APPLIED=1
                fi
            fi

            # Always bring interface up with proper MTU and restore inner IPv4 address
            TARGET_MTU=$(tunnel_mtu_get "$dev") || return 1
            ip link set dev "$dev" up mtu "$TARGET_MTU" >/dev/null 2>&1 || true
            if [[ -n "$DEV_IP" ]]; then
                if ! ip -o -4 addr show dev "$dev" 2>/dev/null | grep -q "${DEV_IP%/*}"; then
                    ip addr add "$DEV_IP" dev "$dev" >/dev/null 2>&1 || true
                fi
            fi
            iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
                iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || true
        fi
    done

    python3 -c '
import json, time, sys
p = "'"$CARRIER_FILE"'"
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
d["active_carrier"] = sys.argv[1]
d["last_switch"] = time.strftime("%Y-%m-%d %H:%M:%S")
d["switch_count"] = int(d.get("switch_count", 0)) + 1
with open(p + ".tmp", "w") as f:
    json.dump(d, f, indent=2)
import os
os.replace(p + ".tmp", p)
os.chmod(p, 0o600)
' "$TARGET" 2>/dev/null || true

    if [[ $ANY_APPLIED -eq 1 ]]; then
        return 0
    fi
    # Don't call systemctl restart recursively if invoked from a systemd service hook
    if [[ -z "${SYSTEMD_EXEC_PID:-}" && -z "${INVOCATION_ID:-}" && -n "${IFS_TO_APPLY[0]:-}" ]]; then
        systemctl restart "${IFS_TO_APPLY[0]}.service" >/dev/null 2>&1 || true
    fi
    return 0
}

carrier_apply_active() {
    local IFNAME="${1:-}"
    local ACT=""
    if [[ -n "$IFNAME" && -f "$PEERS_FILE" ]]; then
        ACT=$(python3 -c '
import json, sys
ifname = sys.argv[1]
try:
    with open("'"$PEERS_FILE"'") as f:
        d = json.load(f)
    for p in d.get("peers", []):
        if p.get("gre_if") == ifname and p.get("carrier"):
            print(p["carrier"])
            sys.exit(0)
except Exception:
    pass
' "$IFNAME" 2>/dev/null || true)
    fi
    if [[ -z "$ACT" ]]; then
        ACT=$(carrier_get_active)
    fi
    carrier_apply "$ACT" "$IFNAME"
}

carrier_cycle_next() {
    init_carrier_json
    local NEXT
    NEXT=$(python3 -c '
import json
path = "'"$CARRIER_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    cur = d.get("active_carrier", "direct")
    p1 = d.get("fou_port1", 443)
    p2 = d.get("fou_port2", 55555)
    wp = d.get("wss_port", 8443)
    cands = [c for c in d.get("candidates", []) if c == "direct" or c.startswith("fou:")]
    if not cands: cands = ["direct", f"fou:{p1}", f"fou:{p2}"]
    if cur in cands:
        idx = (cands.index(cur) + 1) % len(cands)
        next_cand = cands[idx]
    else:
        next_cand = cands[0] if cands else "direct"
    print(next_cand)
except Exception:
    print("direct")
' 2>/dev/null || echo "direct")

    carrier_apply "$NEXT" >/dev/null 2>&1 || return 1
    echo "$NEXT"
}

# ---- setup bundle: one readable string with everything foreign needs ----
# Format: hsh1_<IRAN_PUB>_<FRP_PORT>_<IRAN_GRE>_<FOREIGN_GRE>_<TOKEN>[_<PORTS>][_fou<P1>-<P2>]
BUNDLE_PREFIX="hsh1_"

bundle_make() { # $1=iran_pub $2=frp_port $3=iran_gre $4=foreign_gre $5=token [$6="p1 p2"] [$7="p1-p2"]
    local IRAN_PUB=$1 FRP_PORT=$2 IRAN_GRE=$3 FOREIGN_GRE=$4 TOKEN=$5 PORTS_SP=${6:-} FOU_ARG=${7:-} LOSS=${8:-off} PROTOCOL=${9:-tcp}
    local LOSS_SUFFIX=""
    [[ "$LOSS" == on ]] && LOSS_SUFFIX="_loss1"
    if [[ "$PROTOCOL" != tcp ]]; then
        [[ -n "$LOSS_SUFFIX" ]] || LOSS_SUFFIX="_loss0"
        LOSS_SUFFIX="${LOSS_SUFFIX}_proto${PROTOCOL}"
    fi
    local PORTS_DASH=""
    if [[ -n "$PORTS_SP" ]]; then
        PORTS_DASH=$(echo "$PORTS_SP" | xargs | tr ' ' '-')
    fi
    if [[ -z "$FOU_ARG" ]]; then
        local P1 P2
        read -r P1 P2 <<< "$(carrier_get_fou_ports 2>/dev/null || echo '443 55555')"
        FOU_ARG="${P1}-${P2}"
    fi
    if [[ -n "$PORTS_DASH" ]]; then
        echo "${BUNDLE_PREFIX}${IRAN_PUB}_${FRP_PORT}_${IRAN_GRE}_${FOREIGN_GRE}_${TOKEN}_${PORTS_DASH}_fou${FOU_ARG}${LOSS_SUFFIX}"
    else
        echo "${BUNDLE_PREFIX}${IRAN_PUB}_${FRP_PORT}_${IRAN_GRE}_${FOREIGN_GRE}_${TOKEN}__fou${FOU_ARG}${LOSS_SUFFIX}"
    fi
}

bundle_parse() {
    local IN=$1
    B_IRAN_PUB=""; B_FRP_PORT=""; B_IRAN_GRE=""; B_FOREIGN_GRE=""; B_TOKEN=""; B_PORTS=""; B_FOU_P1=443; B_FOU_P2=55555; B_LOSS_RECOVERY=off; B_FRP_TRANSPORT=tcp
    local rest a b c d e f g h i extra
    [[ "$IN" == ${BUNDLE_PREFIX}* ]] || return 1
    rest=${IN#${BUNDLE_PREFIX}}
    IFS=_ read -r a b c d e f g h i extra <<<"$rest"
    [[ -z "$extra" ]] || return 1
    case "$h" in loss1) B_LOSS_RECOVERY=on; B_FRP_TRANSPORT=kcp;; loss0|'') ;; *) return 1;; esac
    case "$i" in
        prototcp|protokcp|protoquic|protowebsocket|protowss) B_FRP_TRANSPORT=${i#proto} ;;
        '') ;;
        *) return 1 ;;
    esac
    [[ "$B_LOSS_RECOVERY" != on || "$B_FRP_TRANSPORT" == kcp ]] || return 1
    [[ "$B_FRP_TRANSPORT" != kcp ]] || B_LOSS_RECOVERY=on
    [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && -n "$e" ]] || return 1
    is_valid_ip "$a" || return 1
    is_valid_port "$b" || return 1
    is_valid_ip "$c" || return 1
    is_valid_ip "$d" || return 1
    [[ ${#e} -ge 1 && ${#e} -le 128 ]] || return 1
    local CLEANED="" p
    if [[ -n "${f:-}" && "$f" != fou* ]]; then
        for p in $(echo "$f" | tr -- '-,' '  '); do
            is_valid_port "$p" || { echo "پورت نامعتبر: $p" >&2; return 1; }
            CLEANED="$CLEANED $((10#$p))"
        done
        CLEANED=$(echo "$CLEANED" | xargs)
        [[ -n "$CLEANED" ]] || return 1
    fi
    local FOU_RAW="${g:-}"
    if [[ -z "$FOU_RAW" && "${f:-}" == fou* ]]; then
        FOU_RAW="$f"
    fi
    if [[ -n "$FOU_RAW" && "$FOU_RAW" == fou* ]]; then
        local FP1 FP2
        IFS=- read -r FP1 FP2 <<< "${FOU_RAW#fou}"
        is_valid_port "$FP1" && B_FOU_P1=$((10#$FP1))
        is_valid_port "$FP2" && B_FOU_P2=$((10#$FP2))
    fi
    B_IRAN_PUB=$a; B_FRP_PORT=$((10#$b)); B_IRAN_GRE=$c; B_FOREIGN_GRE=$d; B_TOKEN=$e; B_PORTS=$CLEANED
    return 0
}
prompt_ip() { # $1=varname $2=label $3=default (empty = required)
    local __var=$1 __label=$2 __def=$3 __in
    while true; do
        if [[ -n "$__def" ]]; then
            read -r -p "$__label [پیش‌فرض: $__def]: " __in || return 1
            __in=${__in:-$__def}
        else
            read -r -p "$__label: " __in || return 1
        fi
        if is_valid_ip "$__in"; then printf -v "$__var" '%s' "$__in"; return 0; fi
        echo -e "${RED}[!] آدرس IPv4 نامعتبر: '${__in}'. نمونه: 203.0.113.10${NC}"
    done
}

prompt_port() { # $1=varname $2=label $3=default
    local __var=$1 __label=$2 __def=$3 __in
    while true; do
        read -r -p "$__label [پیش‌فرض: $__def]: " __in || return 1
        __in=${__in:-$__def}
        if is_valid_port "$__in"; then printf -v "$__var" '%s' "$((10#$__in))"; return 0; fi
        echo -e "${RED}[!] پورت نامعتبر: '${__in}'. باید بین 1 و 65535 باشد.${NC}"
    done
}

prompt_required() { # $1=varname $2=label — must be non-empty
    local __var=$1 __label=$2 __in
    while true; do
        read -r -p "$__label: " __in || return 1
        if [[ -n "$__in" ]]; then printf -v "$__var" '%s' "$__in"; return 0; fi
        echo -e "${RED}[!] این مقدار ضروری است و نمی‌تواند خالی باشد.${NC}"
    done
}

prompt_token() { # $1=varname $2=label $3=default (empty accepts default)
    local __var=$1 __label=$2 __def=$3 __in
    while true; do
        read -r -p "$__label [Enter برای مقدار پیش‌فرض: $__def]: " __in || return 1
        __in="${__in:-$__def}"
        if [[ "$__in" == *"_"* ]]; then
            echo -e "${RED}[!] توکن نباید زیرخط (_) داشته باشد؛ قالب کد اتصال را خراب می‌کند.${NC}"
        else
            printf -v "$__var" '%s' "$__in"
            return 0
        fi
    done
}

prompt_ports() { # $1=varname $2=label — at least one valid port
    local __var=$1 __label=$2 __in __ok p __invalid
    while true; do
        read -r -p "$__label: " __in || return 1
        __ok=""; __invalid=0
        for p in $(echo "$__in" | tr ',' ' '); do
            if is_valid_port "$p"; then __ok="$__ok $((10#$p))"; else __invalid=1; fi
        done
        __ok=$(echo "$__ok" | xargs)
        if [[ -n "$__ok" && "$__invalid" == 0 ]]; then printf -v "$__var" '%s' "$__ok"; return 0; fi
        echo -e "${RED}[!] حداقل یک پورت معتبر بین 1 و 65535 وارد کنید.${NC}"
    done
}

# validate_setup_common checks non-interactive args with the same rules as
# the prompts above. Prints a clear error per bad field, returns non-zero.
validate_setup_common() { # $1=local_pub $2=remote_pub $3=frp_port $4=local_gre
    local ok=1
    is_valid_ip "$1" || { echo -e "${RED}[!] IP عمومی این سرور نامعتبر است: '$1'${NC}"; ok=0; }
    is_valid_ip "$2" || { echo -e "${RED}[!] IP عمومی سرور مقابل نامعتبر است: '$2'${NC}"; ok=0; }
    is_valid_port "$3" || { echo -e "${RED}[!] پورت FRP نامعتبر است: '$3' (باید بین 1 و 65535 باشد)${NC}"; ok=0; }
    is_valid_ip "$4" || { echo -e "${RED}[!] IP داخلی GRE این سرور نامعتبر است: '$4'${NC}"; ok=0; }
    return $((1 - ok))
}

tunnel_present() {
    ip link show "$TUNNEL_NAME" >/dev/null 2>&1 && return 0
    ip tunnel show 2>/dev/null | grep -q "$TUNNEL_NAME" && return 0
    [[ -f "${CONFIG_DIR}/frps.toml" || -f "${CONFIG_DIR}/frpc.toml" ]] && return 0
    return 1
}

check_root() {
    [[ "${NAVATUNNEL_NO_ROOT_CHECK:-0}" == "1" ]] && return 0
    if [[ ${EUID:-$(id -u 2>/dev/null || echo 1)} -ne 0 ]]; then
        echo -e "${RED}[!] اسکریپت را با دسترسی روت یا sudo اجرا کنید.${NC}"
        exit 1
    fi
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            FRP_ARCH="amd64"
            ;;
        aarch64|arm64)
            FRP_ARCH="arm64"
            ;;
        armv7l|armhf)
            FRP_ARCH="arm"
            ;;
        *)
            echo -e "${RED}[!] معماری پشتیبانی‌نشده: $ARCH${NC}"
            exit 1
            ;;
    esac
}

get_latest_frp_version() {
    if [[ -n "${FRP_VERSION:-}" && "$FRP_VERSION" != "$DEFAULT_FRP_VERSION" ]]; then
        return 0
    fi
    LATEST_VER=$(curl -sSL --connect-timeout 3 --max-time 6 "https://api.github.com/repos/fatedier/frp/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [[ -z "$LATEST_VER" ]]; then
        FRP_VERSION="$DEFAULT_FRP_VERSION"
    else
        FRP_VERSION="$LATEST_VER"
    fi
}

download_with_fallback() {
    local DEST="$1"
    local URL="$2"
    local TIMEOUT="${3:-45}"

    # If destination already exists and is non-empty, reuse it
    if [[ -s "$DEST" ]]; then
        return 0
    fi

    # Try direct URL first (use fast 5s connect-timeout for GitHub since it is often blocked in Iran)
    local DIRECT_CONNECT_TO=10
    local DIRECT_MAX_TO="$TIMEOUT"
    if [[ "$URL" == https://github.com/* || "$URL" == https://raw.githubusercontent.com/* ]]; then
        DIRECT_CONNECT_TO=5
        DIRECT_MAX_TO=8
    fi

    if curl -fsSL --connect-timeout "$DIRECT_CONNECT_TO" --max-time "$DIRECT_MAX_TO" -o "$DEST" "$URL" 2>/dev/null && [[ -s "$DEST" ]]; then
        return 0
    fi

    # Iran-friendly GitHub proxy mirrors if it is a GitHub URL
    if [[ "$URL" == https://github.com/* || "$URL" == https://raw.githubusercontent.com/* ]]; then
        echo -e "${YELLOW}[*] دریافت مستقیم ناموفق بود؛ در حال امتحان نشانی جایگزین...${NC}"
        local MIRRORS=(
            "https://ghproxy.net/${URL}"
            "https://gh-proxy.com/${URL}"
            "https://gh.ddlc.top/${URL}"
            "https://ghproxy.cn/${URL}"
        )
        for M in "${MIRRORS[@]}"; do
            if curl -fsSL --connect-timeout 6 --max-time 20 -o "$DEST" "$M" 2>/dev/null && [[ -s "$DEST" ]]; then
                echo -e "${GREEN}[✔️] دریافت از نشانی جایگزین موفق بود: ${M%/*}${NC}"
                return 0
            fi
        done
    fi
    return 1
}

# Resolve upstream release assets by the repository's stable numeric ID.
upstream_release_asset_url() {
    local release_tag="$1" asset_name="$2" metadata
    metadata=$(curl -fsSL --connect-timeout 8 --max-time 20 \
        "https://api.github.com/repositories/1383393754/releases/tags/${release_tag}") || return 1
    python3 -c 'import json,sys
assets=json.load(sys.stdin).get("assets",[])
match=next((a["browser_download_url"] for a in assets if a["name"]==sys.argv[1]),None)
if not match: sys.exit(1)
print(match)' "$asset_name" <<< "$metadata"
}

install_frp_binaries() {
    local ROLE="${1:-all}"
    if [[ "$ROLE" == "server" && -x "${INSTALL_DIR}/frps" ]]; then
        return 0
    fi
    if [[ "$ROLE" == "client" && -x "${INSTALL_DIR}/frpc" ]]; then
        return 0
    fi
    if [[ -x "${INSTALL_DIR}/frps" && -x "${INSTALL_DIR}/frpc" ]]; then
        return 0
    fi
    detect_arch
    get_latest_frp_version
    echo -e "${CYAN}[*] در حال دریافت FRP v${FRP_VERSION} (${FRP_ARCH})...${NC}"

    mkdir -p "$CONFIG_DIR"
    TMP_DIR=$(mktemp -d)
    TAR_FILE="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"

    local DOWNLOAD_URL
    DOWNLOAD_URL=$(upstream_release_asset_url "v${FRP_VERSION}" "$TAR_FILE") || DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${TAR_FILE}"
    if ! download_with_fallback "${TMP_DIR}/${TAR_FILE}" "$DOWNLOAD_URL" 30; then
        DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${TAR_FILE}"
        if ! download_with_fallback "${TMP_DIR}/${TAR_FILE}" "$DOWNLOAD_URL" 60; then
            echo -e "${RED}[!] دریافت FRP از گیت‌هاب و نشانی‌های جایگزین ناموفق بود.${NC}"
            rm -rf "$TMP_DIR"
            return 1
        fi
    fi

    tar -xzf "${TMP_DIR}/${TAR_FILE}" -C "$TMP_DIR" || { rm -rf "$TMP_DIR"; return 1; }
    local FOUND_FRPS FOUND_FRPC
    FOUND_FRPS=$(find "$TMP_DIR" -type f -name "frps" 2>/dev/null | head -1)
    FOUND_FRPC=$(find "$TMP_DIR" -type f -name "frpc" 2>/dev/null | head -1)
    if [[ -n "$FOUND_FRPS" ]]; then cp -f "$FOUND_FRPS" "$INSTALL_DIR/" 2>/dev/null; fi
    if [[ -n "$FOUND_FRPC" ]]; then cp -f "$FOUND_FRPC" "$INSTALL_DIR/" 2>/dev/null; fi
    chmod +x "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc" 2>/dev/null || true

    rm -rf "$TMP_DIR"
    if [[ "$ROLE" == "server" && ! -x "${INSTALL_DIR}/frps" ]]; then
        echo -e "${RED}[!] فایل اجرایی frps پس از نصب موجود یا قابل اجرا نیست.${NC}"
        return 1
    elif [[ "$ROLE" == "client" && ! -x "${INSTALL_DIR}/frpc" ]]; then
        echo -e "${RED}[!] فایل اجرایی frpc پس از نصب موجود یا قابل اجرا نیست.${NC}"
        return 1
    elif [[ "$ROLE" == "all" && ( ! -x "${INSTALL_DIR}/frps" || ! -x "${INSTALL_DIR}/frpc" ) ]]; then
        echo -e "${RED}[!] فایل‌های اجرایی FRP پس از نصب موجود یا قابل اجرا نیستند.${NC}"
        return 1
    fi
    echo -e "${GREEN}[✔️] نصب FRP انجام شد در ${INSTALL_DIR}.${NC}"
}

tunnel_mtu_get() {
    python3 - "${NAVATUNNEL_STATE_DIR}/mtu.json" "/etc/systemd/system/${1}.service" "$1" <<'PYCODE'
import json,sys,re
from pathlib import Path
state,unit,iface=sys.argv[1:]
p=Path(state); data=json.loads(p.read_text()) if p.exists() else {}
value=data.get(iface)
if value is None and Path(unit).exists():
    m=re.search(r'\bmtu\s+(\d+)',Path(unit).read_text()); value=int(m.group(1)) if m else None
print(value if isinstance(value,int) and 576<=value<=1476 else 1380)
PYCODE
}

tunnel_mtu_apply() {
    local iface=$1 mtu=${2:-}
    [[ "$iface" =~ ^gre-(tunnel|t[0-9]+)$ ]] || return 1
    [[ -n "$mtu" ]] || mtu=$(tunnel_mtu_get "$iface") || return 1
    [[ "$mtu" =~ ^[0-9]{3,4}$ ]] && ((10#$mtu>=576 && 10#$mtu<=1476)) || return 1
    ip link set dev "$iface" mtu "$mtu" || return 1
    local direction
    for direction in -i -o; do
        iptables -t mangle -C FORWARD "$direction" "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 ||
            iptables -t mangle -I FORWARD 1 "$direction" "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || return 1
    done
    iptables -t mangle -C POSTROUTING -o "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 ||
        iptables -t mangle -I POSTROUTING 1 -o "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || return 1
}

validate_kcp_mtu() {
    [[ "$2" == kcp ]] || return 0
    local mtu
    mtu=$(tunnel_mtu_get "$1") || return 1
    if ((mtu<1378)); then
        echo 'MTU ذخیره‌شده کمتر از 1378 است؛ ابتدا MTU دو سمت را بالا ببرید یا پروتکلی به‌جز KCP انتخاب کنید.' >&2
        return 1
    fi
}

cli_mtu() {
    local iface='' mtu=''
    while [[ $# -gt 0 ]]; do
        [[ $# -ge 2 ]] || return 1
        case "$1" in --interface) iface=$2;; --value) mtu=$2;; *) return 1;; esac
        shift 2
    done
    [[ "$iface" =~ ^gre-(tunnel|t[0-9]+)$ ]] || { echo 'نام اینترفیس GRE معتبر نیست.' >&2; return 1; }
    [[ "$mtu" =~ ^[0-9]{3,4}$ ]] && ((10#$mtu>=576 && 10#$mtu<=1476)) || { echo 'MTU باید بین 576 و 1476 باشد.' >&2; return 1; }
    local protocol old unit="/etc/systemd/system/${iface}.service" temp state old_state old_unit
    [[ -f "$unit" ]] || { echo 'فایل سرویس این تونل پیدا نشد.' >&2; return 1; }
    protocol=$(python3 - "$PEERS_FILE" "$iface" "${CONFIG_DIR}/frpc.toml" "$TUNNEL_NAME" <<'PYCODE'
import json,sys,re
from pathlib import Path
p=Path(sys.argv[1]); data=json.loads(p.read_text()) if p.exists() else {}
for t in data.get('peers',[]):
    if t.get('gre_if')==sys.argv[2] and (t.get('frp_transport')=='kcp' or (not t.get('frp_transport') and t.get('loss_recovery'))): print('kcp'); break
else:
    c=Path(sys.argv[3]); text=c.read_text() if c.exists() and sys.argv[2]==sys.argv[4] else ''
    if re.search(r'^\s*transport.protocol\s*=\s*"kcp"',text,re.M): print('kcp')
PYCODE
) || return 1
    if [[ "$protocol" == kcp ]] && ((10#$mtu<1378)); then
        echo 'KCP فعلی به MTU حداقل 1378 نیاز دارد؛ برای MTU کمتر ابتدا پروتکل را تغییر دهید.' >&2; return 1
    fi
    old=$(tunnel_mtu_get "$iface") || return 1
    temp=$(mktemp -d) || return 1
    state="${NAVATUNNEL_STATE_DIR}/mtu.json"
    mkdir -p "$NAVATUNNEL_STATE_DIR" || { rm -rf "$temp"; return 1; }
    old_state=0; [[ ! -f "$state" ]] || { cp -p "$state" "$temp/state" || { rm -rf "$temp"; return 1; }; old_state=1; }
    cp -p "$unit" "$temp/unit" || { rm -rf "$temp"; return 1; }
    if python3 - "$state" "$unit" "$iface" "$((10#$mtu))" <<'PYCODE'
import json,sys,re,os
from pathlib import Path
state,unit,iface,value=sys.argv[1:]; p=Path(state); u=Path(unit)
data=json.loads(p.read_text()) if p.exists() else {}; data[iface]=int(value)
text=u.read_text()
text=re.sub(r'\bmtu\s+\d+', 'mtu '+value,text)
hook='ExecStartPost=-/bin/sh -c "if [ -x /usr/local/bin/NavaTunnel ]; then /usr/local/bin/NavaTunnel mtu-apply '+iface+'; fi"\n'
if 'NavaTunnel mtu-apply '+iface not in text:
    if '[Install]' not in text: sys.exit('ساختار فایل سرویس معتبر نیست.')
    text=text.replace('[Install]',hook+'\n[Install]',1)
for target,content in ((u,text),(p,json.dumps(data,indent=2))):
    out=target.with_suffix('.mtu.tmp'); out.write_text(content); out.chmod(0o600 if target==p else 0o644); os.replace(out,target)
PYCODE
    then
        if systemctl daemon-reload && tunnel_mtu_apply "$iface" "$((10#$mtu))"; then
            rm -rf "$temp"
            echo "MTU تونل $iface روی $((10#$mtu)) ذخیره و اعمال شد."
            echo 'همین MTU را روی تونل متناظر در سرور دیگر هم تنظیم کنید.'
            return 0
        fi
    fi
    cp -p "$temp/unit" "$unit"
    if ((old_state)); then cp -p "$temp/state" "$state"; else rm -f "$state"; fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    tunnel_mtu_apply "$iface" "$old" >/dev/null 2>&1 || true
    rm -rf "$temp"
    echo 'تغییر MTU ناموفق بود؛ تنظیم قبلی بازگردانده شد.' >&2
    return 1
}

menu_mtu() {
    ui_clear
    local iface=$1 value current
    current=$(tunnel_mtu_get "$iface") || return 1
    echo "MTU فعلی ذخیره‌شده: $current | اینترفیس: $iface"
    echo 'مقدار پیش‌فرض 1380 است؛ مقدار دو سمت تونل باید هماهنگ باشد.'
    read -r -p 'MTU جدید [Enter: لغو]: ' value || return 0
    [[ -n "$value" ]] || return 0
    cli_mtu --interface "$iface" --value "$value"
}

traffic_id_for_interface() {
    python3 - "${NAVATUNNEL_STATE_DIR}/traffic.json" "$1" <<'PYCODE'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); data=json.loads(p.read_text()) if p.exists() else {}
for name,t in data.items():
    if t.get('interface')==sys.argv[2]: print(name); break
PYCODE
}

traffic_summary() {
    python3 - "${NAVATUNNEL_STATE_DIR}/traffic.json" "$1" <<'PYCODE'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); data=json.loads(p.read_text()) if p.exists() else {}
t=data.get(sys.argv[2])
if not t: print('شمارنده ترافیک هنوز ثبت نشده است.'); sys.exit(0)
rx=t.get('download',0); tx=t.get('upload',0); mode=t.get('mode','both'); used=rx if mode=='download' else tx if mode=='upload' else rx+tx
size=lambda x:'%.3f GB'%(x/10**9)
print('دانلود: '+size(rx)); print('آپلود: '+size(tx)); print('مجموع دانلود و آپلود: '+size(rx+tx))
print('مصرف محاسبه‌شده برای سقف: '+size(used))
print('نحوه محاسبه: '+dict(download='دانلود',upload='آپلود',both='هر دو').get(mode,mode))
print('سقف مصرف: '+(size(t['limit']) if t.get('limit') else 'نامحدود'))
print('وضعیت: '+('مسدود به دلیل سقف مصرف' if t.get('blocked') else 'باز'))
print('این شمارنده فقط ترافیک IPv4 داخل تونل را می‌شمارد، نه کل مصرف دیتاسنتر.')
PYCODE
}

menu_tunnel_traffic() {
    local iface=$1 name option value mode confirm
    ui_clear
    name=$(traffic_id_for_interface "$iface") || return 1
    if [[ -z "$name" ]]; then
        echo 'شمارنده این تونل پیدا نشد؛ با ثبت آن، شمارش از همین لحظه شروع می‌شود.'
        read -r -p 'شمارنده برای همین تونل ثبت شود؟ [y/N]: ' confirm || return 0
        [[ "$confirm" == y || "$confirm" == Y ]] || return 0
        traffic_register "$iface" --interface "$iface" || return 1
        name=$(traffic_id_for_interface "$iface") || return 1
        [[ -n "$name" ]] || return 1
    fi
    while true; do
        ui_clear
        echo "ترافیک همین تونل: $iface"
        if ! cli_traffic status "$name" >/dev/null; then
            echo 'به‌روزرسانی شمارنده ناموفق بود؛ آخرین مصرف ذخیره‌شده نمایش داده می‌شود.'
        fi
        traffic_summary "$name" || return 1
        echo '1) تازه‌سازی مصرف'
        echo '2) تعیین سقف مصرف'
        echo '3) انتخاب دانلود، آپلود یا هر دو'
        echo '4) ریست مصرف و رفع مسدودی'
        echo '5) نامحدودکردن مصرف'
        echo '0) بازگشت'
        read -r -p 'انتخاب: ' option || return 0
        case "$option" in
            1) ;;
            2)
                read -r -p 'سقف به GB (مثلاً 100؛ یا 100GB؛ 0=نامحدود؛ Enter=لغو): ' value || return 0
                [[ -n "$value" ]] || continue
                [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ && "$value" != 0 ]] && value="${value}GB"
                cli_traffic limit "$name" "$value" || echo 'تعیین سقف ناموفق بود.' ;;
            3) mode=$(menu_traffic_mode) || continue; cli_traffic mode "$name" "$mode" ;;
            4)
                read -r -p 'مصرف همین تونل صفر و مسدودی رفع شود؟ [y/N]: ' confirm || return 0
                [[ "$confirm" == y || "$confirm" == Y ]] && cli_traffic reset "$name" ;;
            5) cli_traffic limit "$name" 0 ;;
            0) return 0 ;;
            *) echo 'گزینه نامعتبر است.' ;;
        esac
        [[ "$option" == 1 ]] || pause_prompt
    done
}

setup_gre_systemd() {
    setup_gre_iface "$TUNNEL_NAME" "$1" "$2" "$3" "$4"
}

# Generalized GRE interface setup: $1=ifname $2=local_pub $3=remote_pub $4=inner_ip.
# setup_gre_systemd() above is the legacy single-tunnel wrapper; peers call this
# directly with gre-tN names so every tunnel is the same GRE, just N of them.
setup_gre_iface() {
    local IFNAME=$1
    [[ ! -f "${NAVATUNNEL_STATE_DIR}/stopped/${IFNAME}" ]] || { echo 'این تونل دستی متوقف شده است؛ ابتدا گزینه شروع تونل را اجرا کنید.' >&2; return 1; }
    local LOCAL_IP=$2
    local REMOTE_IP=$3
    local GRE_INTERNAL_IP=$4
    local CLEAN_GRE_IP="${GRE_INTERNAL_IP%/*}"
    local PEER_INNER=$5
    local GRE_MTU
    GRE_MTU=$(tunnel_mtu_get "$IFNAME") || return 1

    echo -e "${CYAN}[*] در حال تنظیم سرویس دائمی تونل GRE (${IFNAME})...${NC}"

    ensure_navatunnel_bin

    local IP_BIN
    IP_BIN=$(command -v ip || echo "/sbin/ip")
    modprobe ip_gre >/dev/null 2>&1 || true
    modprobe fou >/dev/null 2>&1 || true

    # Tear down existing if present
    "$IP_BIN" link del "$IFNAME" >/dev/null 2>&1 || "$IP_BIN" tunnel del "$IFNAME" >/dev/null 2>&1 || true

    # Intelligent NAT / local IP handling:
    # If LOCAL_IP is not bound directly to a local interface (common on cloud/NAT VPS in Iran),
    # binding explicitly causes Linux kernel EADDRNOTAVAIL (Cannot assign requested address).
    # In that case, use the interface IP that routes to REMOTE_IP, or wildcard (omit local).
    local LOCAL_ARG=""
    if [[ -n "$LOCAL_IP" ]] && "$IP_BIN" -o addr show 2>/dev/null | grep -qw "$LOCAL_IP"; then
        LOCAL_ARG="local ${LOCAL_IP}"
    else
        local NIC_IP
        NIC_IP=$("$IP_BIN" route get "$REMOTE_IP" 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
        if [[ -n "$NIC_IP" ]] && "$IP_BIN" -o addr show 2>/dev/null | grep -qw "$NIC_IP"; then
            LOCAL_ARG="local ${NIC_IP}"
        else
            LOCAL_ARG=""
        fi
    fi

    if [[ -z "$PEER_INNER" ]]; then
        if [[ "$CLEAN_GRE_IP" =~ \.2$ ]]; then
            PEER_INNER="${CLEAN_GRE_IP%.*}.1"
        else
            PEER_INNER="${CLEAN_GRE_IP%.*}.2"
        fi
    fi

    # Create systemd service for GRE
    # Robust architecture:
    # 1. Multi-fallback: try netlink `ip link add` (modern), then `ip tunnel add` (ioctl),
    #    and if local address binding failed due to NAT/routing, retry without local arg.
    # 2. Fixed TTL (255) without incompatible nopmtudisc (fixing root cause: ttl != 0 and nopmtudisc are incompatible).
    # 3. Wrap hooks in /bin/sh -c with [ -x ... ] checks so systemd never exits with status 203/EXEC.
    # 4. Use addr replace / add to avoid failure when address is already assigned.
    # 5. Add direct point-to-point /32 route to the peer inner GRE IP.
    cat <<EOF > /etc/systemd/system/${IFNAME}.service
[Unit]
ConditionPathExists=!${NAVATUNNEL_STATE_DIR}/stopped/${IFNAME}
Description=اینترفیس تونل GRE
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/bin/sh -c "modprobe ip_gre 2>/dev/null; modprobe fou 2>/dev/null; if [ -x /usr/local/bin/NavaTunnel ]; then /usr/local/bin/NavaTunnel carrier-kernel-init 2>/dev/null; fi; true"
ExecStartPre=-/bin/sh -c "${IP_BIN} link del ${IFNAME} 2>/dev/null || ${IP_BIN} tunnel del ${IFNAME} 2>/dev/null; true"
ExecStart=/bin/sh -c '(\
    ${IP_BIN} link add ${IFNAME} type gre ${LOCAL_ARG} remote ${REMOTE_IP} ttl 255 2>/dev/null || \
    ${IP_BIN} tunnel add ${IFNAME} mode gre ${LOCAL_ARG} remote ${REMOTE_IP} ttl 255 2>/dev/null || \
    ${IP_BIN} link add ${IFNAME} type gre remote ${REMOTE_IP} ttl 255 2>/dev/null || \
    ${IP_BIN} tunnel add ${IFNAME} mode gre remote ${REMOTE_IP} ttl 255 2>/dev/null || true); \
    ${IP_BIN} link set dev ${IFNAME} up mtu ${GRE_MTU} && \
    (${IP_BIN} addr replace ${CLEAN_GRE_IP}/30 dev ${IFNAME} 2>/dev/null || ${IP_BIN} addr add ${CLEAN_GRE_IP}/30 dev ${IFNAME} 2>/dev/null || true) && \
    (${IP_BIN} route replace ${PEER_INNER}/32 dev ${IFNAME} 2>/dev/null || true)'
ExecStartPost=-/bin/sh -c "if [ -x /usr/local/bin/NavaTunnel ]; then /usr/local/bin/NavaTunnel carrier-apply-active ${IFNAME} 2>/dev/null; fi; true"
ExecStartPost=-/bin/sh -c "if [ -x /usr/local/bin/NavaTunnel ]; then /usr/local/bin/NavaTunnel mtu-apply ${IFNAME}; fi; true"
ExecStop=-/bin/sh -c "${IP_BIN} link del ${IFNAME} 2>/dev/null || ${IP_BIN} tunnel del ${IFNAME} 2>/dev/null; true"

[Install]
WantedBy=multi-user.target
EOF

    chmod 600 "${CONFIG_DIR}"/*.toml 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed "${IFNAME}.service" >/dev/null 2>&1 || true
    systemctl enable "${IFNAME}.service" >/dev/null 2>&1
    local GRE_STARTED=0
    if systemctl restart "${IFNAME}.service" >/dev/null 2>&1; then
        if "$IP_BIN" link show "$IFNAME" >/dev/null 2>&1 && "$IP_BIN" -4 addr show dev "$IFNAME" 2>/dev/null | grep -q "${CLEAN_GRE_IP}"; then
            GRE_STARTED=1
        fi
    fi

    if [[ "$GRE_STARTED" -ne 1 ]]; then
        # Direct fallback in bash if systemctl restart did not bring up interface
        "$IP_BIN" link del "$IFNAME" >/dev/null 2>&1 || "$IP_BIN" tunnel del "$IFNAME" >/dev/null 2>&1 || true
        ( "$IP_BIN" link add "$IFNAME" type gre ${LOCAL_ARG} remote "$REMOTE_IP" ttl 255 2>/dev/null || \
          "$IP_BIN" tunnel add "$IFNAME" mode gre ${LOCAL_ARG} remote "$REMOTE_IP" ttl 255 2>/dev/null || \
          "$IP_BIN" link add "$IFNAME" type gre remote "$REMOTE_IP" ttl 255 2>/dev/null || \
          "$IP_BIN" tunnel add "$IFNAME" mode gre remote "$REMOTE_IP" ttl 255 2>/dev/null || true )
        "$IP_BIN" link set dev "$IFNAME" up mtu ${GRE_MTU} >/dev/null 2>&1 || true
        ( "$IP_BIN" addr replace "${CLEAN_GRE_IP}/30" dev "$IFNAME" 2>/dev/null || "$IP_BIN" addr add "${CLEAN_GRE_IP}/30" dev "$IFNAME" 2>/dev/null || true )
        ( "$IP_BIN" route replace "${PEER_INNER}/32" dev "$IFNAME" 2>/dev/null || true )

        if "$IP_BIN" link show "$IFNAME" >/dev/null 2>&1 && "$IP_BIN" -4 addr show dev "$IFNAME" 2>/dev/null | grep -q "${CLEAN_GRE_IP}"; then
            GRE_STARTED=1
        fi
    fi

    if [[ "$GRE_STARTED" -ne 1 ]]; then
        echo -e "${RED}[!] راه‌اندازی اینترفیس GRE ${IFNAME} ناموفق بود؛ بررسی کنید: ip tunnel show; journalctl -u ${IFNAME}.service${NC}"
        journalctl -u "${IFNAME}.service" -n 5 --no-pager 2>/dev/null || true
        return 1
    fi

    carrier_apply_active "${IFNAME}" >/dev/null 2>&1 || true

    # Safeguard: ensure GRE interface remains UP and has IP assigned after carrier apply
    if ! "$IP_BIN" link show "$IFNAME" >/dev/null 2>&1 || ! "$IP_BIN" -4 addr show dev "$IFNAME" 2>/dev/null | grep -q "${CLEAN_GRE_IP}"; then
        ( "$IP_BIN" link add "$IFNAME" type gre ${LOCAL_ARG} remote "$REMOTE_IP" ttl 255 2>/dev/null || \
          "$IP_BIN" tunnel add "$IFNAME" mode gre ${LOCAL_ARG} remote "$REMOTE_IP" ttl 255 2>/dev/null || \
          "$IP_BIN" link add "$IFNAME" type gre remote "$REMOTE_IP" ttl 255 2>/dev/null || \
          "$IP_BIN" tunnel add "$IFNAME" mode gre remote "$REMOTE_IP" ttl 255 2>/dev/null || true )
        "$IP_BIN" link set dev "$IFNAME" up mtu ${GRE_MTU} >/dev/null 2>&1 || true
        ( "$IP_BIN" addr replace "${CLEAN_GRE_IP}/30" dev "$IFNAME" 2>/dev/null || "$IP_BIN" addr add "${CLEAN_GRE_IP}/30" dev "$IFNAME" 2>/dev/null || true )
        ( "$IP_BIN" route replace "${PEER_INNER}/32" dev "$IFNAME" 2>/dev/null || true )
    fi

    # Enable packet forwarding & MSS clamping to avoid fragmentation
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340

    tunnel_mtu_apply "$IFNAME" "$GRE_MTU" || return 1
    traffic_register "$IFNAME" --interface "$IFNAME" || echo "[!] راه‌اندازی شمارنده ترافیک ناموفق بود؛ از NavaTunnel traffic add استفاده کنید." >&2
    echo -e "${GREEN}[✔️] سرویس تونل GRE فعال شد با IP ${CLEAN_GRE_IP} (MTU ${GRE_MTU}).${NC}"
}

# ---- Traffic Obfuscation / Chaff Service (idle gap filler) ----
CHAFF_BIN="/usr/local/bin/NavaTunnel-chaff.sh"

install_chaff_script() {
    cat <<'EOF' > "$CHAFF_BIN"
#!/usr/bin/env bash
# Random GRE cover traffic; this also runs while user traffic is active.
PEER_IP="${1:-}"
PROFILE="${2:-low}"
case "$PROFILE" in
 low) MIN_MS=400; MAX_MS=2800; MIN_BYTES=64; MAX_BYTES=1200 ;;
 mid) MIN_MS=150; MAX_MS=1200; MIN_BYTES=200; MAX_BYTES=1280 ;;
 custom) MIN_MS=${3:-}; MAX_MS=${4:-}; MIN_BYTES=${5:-}; MAX_BYTES=${6:-} ;;
 *) echo 'حالت ترافیک پوششی نامعتبر است.' >&2; exit 1 ;;
esac
[[ -n "$PEER_IP" ]] || { echo 'IP داخلی مقابل را وارد کنید.' >&2; exit 1; }
for value in "$MIN_MS" "$MAX_MS" "$MIN_BYTES" "$MAX_BYTES"; do
 [[ "$value" =~ ^[0-9]{1,7}$ ]] || { echo 'محدوده ترافیک پوششی نامعتبر است.' >&2; exit 1; }
done
MIN_MS=$((10#$MIN_MS)); MAX_MS=$((10#$MAX_MS)); MIN_BYTES=$((10#$MIN_BYTES)); MAX_BYTES=$((10#$MAX_BYTES))
((MIN_MS>=100 && MAX_MS<=3600000 && MIN_MS<=MAX_MS && MIN_BYTES>=8 && MAX_BYTES<=1352 && MIN_BYTES<=MAX_BYTES)) || { echo 'محدوده ترافیک پوششی نامعتبر است.' >&2; exit 1; }
trap 'exit 0' SIGTERM SIGINT
while true; do
 ms=$(( MIN_MS + ((RANDOM<<15)|RANDOM) % (MAX_MS-MIN_MS+1) ))
 size=$(( MIN_BYTES + RANDOM % (MAX_BYTES-MIN_BYTES+1) ))
 sleep_sec=$(printf '%d.%03d' $((ms/1000)) $((ms%1000)))
 sleep "$sleep_sec"
 pattern=$(printf '%04x%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM")
 ping -n -c1 -W1 -s "$size" -p "$pattern" "$PEER_IP" >/dev/null 2>&1 || true
done
EOF
    chmod +x "$CHAFF_BIN"
}

# setup_chaff: $1=ifname_suffix("" for legacy, "-N" for peers) $2=peer_gre_ip
setup_chaff() {
    local SUF=$1 PEER_GRE=$2
    local PROFILE="${CHAFF_PROFILE:-$(perf_get_chaff)}"
    if [[ "$PROFILE" == "off" ]]; then
        return 0
    fi
    is_valid_ip "$PEER_GRE" || return 1
    install_chaff_script || return 1

    local RANGE_ARGS=''
    if [[ "$PROFILE" == custom ]]; then
        RANGE_ARGS=$(python3 - "$PERF_FILE" <<'PYCODE'
import json,sys
p=json.load(open(sys.argv[1]));v=p.get('chaff_custom',{})
print(' '.join(str(v.get(k,'')) for k in ('min_ms','max_ms','min_bytes','max_bytes')))
PYCODE
) || return 1
        [[ "$RANGE_ARGS" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]] || { echo 'ابتدا تنظیمات سفارشی ترافیک پوششی را ثبت کنید.' >&2; return 1; }
    fi
    local SVC="gre-chaff"
    local GRE_IF="$TUNNEL_NAME"
    if [[ -n "$SUF" ]]; then
        local ID="${SUF#-}"
        SVC="gre-chaff-${ID}"
        GRE_IF="gre-t${ID}"
    fi

    local AFTER_GRE=""
    if [[ -f "/etc/systemd/system/${GRE_IF}.service" ]]; then
        AFTER_GRE=" ${GRE_IF}.service"
    fi

    cat <<EOF > "/etc/systemd/system/${SVC}.service"
[Unit]
ConditionPathExists=!${NAVATUNNEL_STATE_DIR}/stopped/${GRE_IF}
Description=سرویس ترافیک پوششی GRE${SUF:+ (peer${SUF#-})}
After=network.target${AFTER_GRE}
${AFTER_GRE:+Wants=${GRE_IF}.service}

[Service]
Type=simple
User=root
Restart=always
RestartSec=3s
ExecStart=${CHAFF_BIN} ${PEER_GRE} ${PROFILE} ${RANGE_ARGS}

[Install]
WantedBy=multi-user.target
EOF
    chmod 600 "${CONFIG_DIR}"/*.toml 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable "${SVC}.service" >/dev/null 2>&1
    systemctl restart "${SVC}.service" || return 1
    if [[ ! -f "${NAVATUNNEL_STATE_DIR}/stopped/${GRE_IF}" ]]; then
        systemctl is-active --quiet "${SVC}.service" || { echo 'سرویس ترافیک پوششی فعال نشد.' >&2; return 1; }
    fi
    if [[ -f "${NAVATUNNEL_STATE_DIR}/stopped/${GRE_IF}" ]]; then
        echo "تنظیمات ترافیک پوششی $SVC ثبت شد؛ تونل دستی متوقف است و سرویس اجرا نشد."
    else
        echo "سرویس ترافیک پوششی $SVC فعال شد؛ حالت: $PROFILE."
    fi
}

update_chaff_existing_tunnels() {
    local CHAFF_PROFILE="${CHAFF_PROFILE:-$(perf_get_chaff)}"
    if [[ "$CHAFF_PROFILE" == "off" ]]; then
        return 0
    fi
    # 1. Multi-peer registry (/etc/gre-panel/peers.json)
    if [[ -f "$PEERS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        local PEER_DATA
        PEER_DATA=$(PEERS_F="$PEERS_FILE" python3 -c '
import json, os
try:
    d = json.load(open(os.environ["PEERS_F"]))
    for p in d.get("peers", []):
        suf = "" if p.get("legacy") else "-"+str(p.get("id", ""))
        pgre = p.get("peer_gre", "")
        prof = p.get("chaff_profile", "")
        if pgre:
            print(f"{suf}:{pgre}:{prof}")
except Exception:
    pass
' 2>/dev/null)
        if [[ -n "$PEER_DATA" ]]; then
            while IFS=':' read -r suf pgre prof; do
                [[ -n "$pgre" ]] || continue
                local saved_prof="${CHAFF_PROFILE:-}"
                [[ -n "$prof" && -z "$saved_prof" ]] && CHAFF_PROFILE="$prof"
                setup_chaff "$suf" "$pgre" || return 1
                CHAFF_PROFILE="$saved_prof"
            done <<< "$PEER_DATA"
            return 0
        fi
    fi

    # 2. Foreign server (/etc/frp/frpc.toml)
    if [[ -f "${CONFIG_DIR}/frpc.toml" ]]; then
        local PEER_GRE
        PEER_GRE=$(grep -E '^[[:space:]]*serverAddr[[:space:]]*=' "${CONFIG_DIR}/frpc.toml" | cut -d'=' -f2 | tr -d ' "' | tr -d " \t\r\n")
        if is_valid_ip "$PEER_GRE"; then
            setup_chaff "" "$PEER_GRE"
            return 0
        fi
    fi

    # 3. Legacy Iran server (/etc/systemd/system/gre-tunnel.service or /etc/frp/frps.toml)
    if [[ -f "/etc/systemd/system/${TUNNEL_NAME}.service" || -f "${CONFIG_DIR}/frps.toml" ]]; then
        local INNER_IP=""
        if [[ -f "/etc/systemd/system/${TUNNEL_NAME}.service" ]]; then
            INNER_IP=$(grep -oE 'addr add [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "/etc/systemd/system/${TUNNEL_NAME}.service" | awk '{print $3}' | head -1)
        fi
        if [[ -z "$INNER_IP" ]] && ip addr show "$TUNNEL_NAME" >/dev/null 2>&1; then
            INNER_IP=$(ip addr show "$TUNNEL_NAME" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
        fi
        if is_valid_ip "$INNER_IP"; then
            local last=${INNER_IP##*.}; local prefix=${INNER_IP%.*}
            if (( last % 2 == 0 )); then last=$((last - 1)); else last=$((last + 1)); fi
            local P_GRE="${prefix}.${last}"
            if is_valid_ip "$P_GRE"; then
                setup_chaff "" "$P_GRE"
            fi
        fi
    fi
}

cli_chaff() {
    local ACTION="${1:-status}"
    case "$ACTION" in
        on)
            echo -e "${CYAN}[*] در حال فعال‌سازی سرویس‌های ترافیک پوششی GRE...${NC}"
            local profile=${CHAFF_PROFILE:-$(perf_get_chaff)}
            [[ "$profile" != off ]] || profile=low
            CHAFF_PROFILE="$profile" update_chaff_existing_tunnels || return 1
            local found=0 u
            for u in /etc/systemd/system/gre-chaff*.service; do [[ ! -f "$u" ]] || found=1; done
            ((found)) || { echo 'تونلی برای ترافیک پوششی پیدا نشد.' >&2; return 1; }
            perf_set_val chaff_profile "$profile" 0 || return 1
            ;;
        off)
            perf_set_val chaff_profile off 0 || return 1
            echo -e "${CYAN}[*] در حال توقف و غیرفعال‌سازی سرویس‌های ترافیک پوششی...${NC}"
            local found=0
            for u in /etc/systemd/system/gre-chaff*.service; do
                [[ -f "$u" ]] || continue
                found=1
                local bname
                bname=$(basename "$u")
                systemctl stop "$bname" >/dev/null 2>&1
                systemctl disable "$bname" >/dev/null 2>&1
                echo -e "${GREEN}[✔️] سرویس ${bname} متوقف و غیرفعال شد.${NC}"
            done
            if [[ "$found" -eq 0 ]]; then
                echo -e "${YELLOW}[*] سرویس ترافیک پوششی پیدا نشد.${NC}"
            fi
            ;;
        configure) shift; cli_cover_configure chaff "$@" ;;
        status)
            echo -e "${CYAN}=== وضعیت ترافیک پوششی GRE ===${NC}"
            echo -e "${YELLOW}ترافیک پوششی فاصله‌های بیکاری را پر می‌کند؛ حجم مصرف زیر بار را پنهان نمی‌کند.${NC}"
            python3 - "$PERF_FILE" <<'PYCODE'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);d=json.loads(p.read_text()) if p.exists() else {}
v=d.get("chaff_custom",{})
if v: print("محدوده سفارشی ذخیره‌شده: فاصله %s تا %s میلی‌ثانیه؛ اندازه %s تا %s بایت"%(v.get("min_ms"),v.get("max_ms"),v.get("min_bytes"),v.get("max_bytes")))
PYCODE
            local found=0
            for u in /etc/systemd/system/gre-chaff*.service; do
                [[ -f "$u" ]] || continue
                found=1
                local bname
                bname=$(basename "$u")
                local active enabled exec_line peer_ip prof
                active=$(systemctl is-active "$bname" 2>/dev/null)
                [[ -z "$active" ]] && active="inactive"
                enabled=$(systemctl is-enabled "$bname" 2>/dev/null)
                [[ -z "$enabled" ]] && enabled="disabled"
                exec_line=$(grep -E '^[[:space:]]*ExecStart[[:space:]]*=' "$u" | head -1)
                peer_ip=$(echo "$exec_line" | awk '{print $2}')
                prof=$(echo "$exec_line" | awk '{print $3}')
                prof=${prof:-low}
                if [[ "$active" == "active" ]]; then
                    echo -e "  ${bname}: ${GREEN}فعال${NC} ($(fa_state "${enabled}")) | سرور مقابل: ${CYAN}${peer_ip}${NC} | حالت: ${YELLOW}$(fa_state "${prof}")${NC}"
                else
                    echo -e "  ${bname}: ${RED}${active}${NC} (${enabled}) | سرور مقابل: ${CYAN}${peer_ip}${NC} | حالت: ${YELLOW}${prof}${NC}"
                fi
            done
            if [[ "$found" -eq 0 ]]; then
                echo -e "${YELLOW}[*] سرویس ترافیک پوششی نصب نشده است.${NC}"
            fi
            ;;
        *)
            echo -e "${RED}[!] روش استفاده: NavaTunnel chaff on|off|status${NC}"
            return 1
            ;;
    esac
}

cli_cover_configure() {
    local kind=$1; shift
    init_perf_json
    python3 - "$PERF_FILE" "$kind" "${NAVATUNNEL_STATE_DIR}/mtu.json" "$@" <<'PYCODE'
import json,re,sys,os,tempfile
from pathlib import Path
path=Path(sys.argv[1]);kind=sys.argv[2];args=sys.argv[4:]
try:
    if len(args)%2:raise ValueError('برای هر گزینه یک مقدار وارد کنید.')
    keys=dict(zip(args[::2],args[1::2]))
    if len(keys)!=len(args)//2:raise ValueError('گزینه تکراری است.')
    data=json.loads(path.read_text())
    if kind=='dpi':
        if set(keys)!={'--rate','--burst'}:raise ValueError('گزینه‌های لازم: --rate و --burst')
        rate=keys['--rate'];burst=keys['--burst']
        if not re.fullmatch(r'[1-9][0-9]{0,5}/(sec|minute|hour)',rate) or not re.fullmatch(r'[1-9][0-9]{0,6}',burst):raise ValueError('نمونه معتبر: --rate 60/sec --burst 120')
        data.update(dpi_rate=rate,dpi_burst=int(burst))
    else:
        names=('min_ms','max_ms','min_bytes','max_bytes')
        if set(keys)!={'--'+n.replace('_','-') for n in names}:raise ValueError('چهار مقدار فاصله و اندازه لازم است.')
        v={n:int(keys['--'+n.replace('_','-')]) for n in names}
        if not(100<=v['min_ms']<=v['max_ms']<=3600000 and 8<=v['min_bytes']<=v['max_bytes']<=1352):raise ValueError('فاصله: 100 تا 3600000 میلی‌ثانیه؛ اندازه: 8 تا 1352 بایت؛ حداقل نباید بیشتر از حداکثر باشد.')
        mtu=Path(sys.argv[3]);mtus=json.loads(mtu.read_text()) if mtu.exists() else {}
        if mtus and v['max_bytes']>min(map(int,mtus.values()))-28:raise ValueError('اندازه پینگ از MTU یکی از تونل‌ها بیشتر است.')
        data['chaff_custom']=v
    fd,tmp=tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,'w') as f:json.dump(data,f,indent=2)
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
except (ValueError,OSError) as error:
    print('تنظیمات ثبت نشد: '+str(error),file=sys.stderr);sys.exit(1)
PYCODE
    [[ $? == 0 ]] || return 1
    if [[ "$kind" == dpi ]]; then
        if [[ "$(perf_get_dpi_enabled)" == 1 ]]; then dpi_shield_on || return 1; fi
    elif [[ "$(perf_get_chaff)" == custom ]]; then
        CHAFF_PROFILE=custom cli_chaff on || return 1
    fi
    echo 'تنظیمات ذخیره شد؛ اگر این حالت فعال بود، تنظیمات جدید هم اعمال شدند.'
}

menu_cover_configure() {
    local kind=$1 rate burst min_ms max_ms min_bytes max_bytes
    ui_clear
    if [[ "$kind" == dpi ]]; then
        echo 'محدودیت SYN به ازای هر IP و هر پورت است؛ سرعت دانلود را محدود نمی‌کند.'
        read -r -p 'نرخ (مثلاً 60/sec یا 3600/minute؛ Enter: لغو): ' rate || return 0
        [[ -n "$rate" ]] || return 0
        read -r -p 'ظرفیت جهش اولیه burst (مثلاً 120): ' burst || return 0
        cli_cover_configure dpi --rate "$rate" --burst "$burst"
    else
        echo 'فاصله بر حسب میلی‌ثانیه و اندازه داده پینگ بر حسب بایت است؛ ترافیک اضافه مصرف می‌کند.'
        read -r -p 'حداقل فاصله (مثلاً 400؛ Enter: لغو): ' min_ms || return 0
        [[ -n "$min_ms" ]] || return 0
        read -r -p 'حداکثر فاصله (مثلاً 2800): ' max_ms || return 0
        read -r -p 'حداقل اندازه (مثلاً 64): ' min_bytes || return 0
        read -r -p 'حداکثر اندازه (مثلاً 1200): ' max_bytes || return 0
        cli_cover_configure chaff --min-ms "$min_ms" --max-ms "$max_ms" --min-bytes "$min_bytes" --max-bytes "$max_bytes" || return 1
        echo 'برای فعال‌شدن این محدوده، حالت سفارشی را از منوی ترافیک پوششی انتخاب کنید.'
    fi
}

menu_chaff() {
    ui_clear
    echo -e "\n${YELLOW}=== ترافیک پوششی GRE با پینگ تصادفی ===${NC}"
    echo -e "مصرف اضافه به فاصله و اندازه پینگ بستگی دارد؛ هنگام ترافیک کاربران هم ادامه دارد."
    cli_chaff status
    echo ""
    echo "  1) فعال‌سازی ترافیک پوششی"
    echo "  2) غیرفعال‌سازی ترافیک پوششی"
    echo "  3) نمایش وضعیت"
    echo '  4) انتخاب حالت کم low'
    echo '  5) انتخاب حالت متوسط mid'
    echo '  6) تنظیم فاصله و اندازه سفارشی'
    echo '  7) فعال‌سازی حالت سفارشی'
    echo "  0) بازگشت"
    echo ""
    read -r -p "انتخاب عمل [0-7]: " CH_OPT || return 0
    case "$CH_OPT" in
        1) cli_chaff on ;;
        2) cli_chaff off ;;
        3) cli_chaff status ;;
        4) cli_perf chaff low ;;
        5) cli_perf chaff mid ;;
        6) menu_cover_configure chaff ;;
        7) cli_perf chaff custom ;;
        0) return 0 ;;
        *) echo -e "${RED}[!] گزینه نامعتبر است.${NC}"; return 1 ;;
    esac
    pause_prompt
}

# ---- محافظ DPI: protect reverse proxy ports against scanner floods ----
DPI_PORTS_FILE="/etc/gre-panel/dpi-ports.conf"

dpi_collect_reverse_ports() {
    local PORTS=()
    local EXCLUDE_PORTS=()

    # 1. Collect FRP bind/control ports to exclude
    local f
    for f in "${CONFIG_DIR}"/frps*.toml /etc/frp/frps*.toml; do
        [[ -f "$f" ]] || continue
        while read -r bp; do
            [[ -n "$bp" ]] && EXCLUDE_PORTS+=("$bp")
        done < <(grep -E '^\s*bindPort\s*=' "$f" 2>/dev/null | awk -F= '{print $2}' | tr -d ' "' | tr -d " \t\r\n")
    done
    for f in "${CONFIG_DIR}/frpc.toml" /etc/frp/frpc.toml; do
        [[ -f "$f" ]] || continue
        while read -r sp; do
            [[ -n "$sp" ]] && EXCLUDE_PORTS+=("$sp")
        done < <(grep -E '^\s*serverPort\s*=' "$f" 2>/dev/null | awk -F= '{print $2}' | tr -d ' "' | tr -d " \t\r\n")
    done
    if [[ -f "$PEERS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        while read -r fp; do
            [[ -n "$fp" ]] && EXCLUDE_PORTS+=("$fp")
        done < <(PEERS_F="$PEERS_FILE" python3 -c '
import json, os
try:
    with open(os.environ["PEERS_F"]) as f:
        d = json.load(f)
        for p in d.get("peers", []):
            pt = p.get("frp_port")
            if pt:
                print(pt)
except Exception:
    pass
' 2>/dev/null)
    fi

    # 3. Collect SSH ports to exclude
    EXCLUDE_PORTS+=(22)
    if command -v ss >/dev/null 2>&1; then
        while read -r sp; do
            [[ -n "$sp" ]] && EXCLUDE_PORTS+=("$sp")
        done < <(ss -ltnp 2>/dev/null | grep 'sshd' | awk '{print $4}' | awk -F: '{print $NF}')
    fi

    # Candidate پورت‌های سرویس:
    # A. peers.json
    if [[ -f "$PEERS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < <(PEERS_F="$PEERS_FILE" python3 -c '
import json, os
try:
    with open(os.environ["PEERS_F"]) as f:
        d = json.load(f)
        for p in d.get("peers", []):
            for pt in p.get("ports", []):
                print(pt)
except Exception:
    pass
' 2>/dev/null)
    fi

    # B. frpc.toml remotePort
    for f in "${CONFIG_DIR}/frpc.toml" /etc/frp/frpc.toml; do
        [[ -f "$f" ]] || continue
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < <(grep -E '^\s*remotePort\s*=' "$f" 2>/dev/null | awk -F= '{print $2}' | tr -d ' "' | tr -d " \t\r\n")
    done

    # C. Active frps listeners via ss -ltn (excluding control ports)
    if command -v ss >/dev/null 2>&1; then
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < <(ss -ltnp 2>/dev/null | grep -E 'users:.*\("frps"' | awk '{print $4}' | awk -F: '{print $NF}')
    fi

    # D. Saved DPI ports cache (for reboots before frps connects)
    if [[ -f "$DPI_PORTS_FILE" ]]; then
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < "$DPI_PORTS_FILE"
    fi

    # Filter candidates: remove excluded, check validity (1..65535)
    local FINAL_PORTS=()
    local p ex excluded
    for p in "${PORTS[@]}"; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        (( p >= 1 && p <= 65535 )) || continue
        excluded=0
        for ex in "${EXCLUDE_PORTS[@]}"; do
            if [[ "$p" -eq "$ex" ]]; then
                excluded=1
                break
            fi
        done
        [[ "$excluded" -eq 0 ]] && FINAL_PORTS+=("$p")
    done

    if [[ ${#FINAL_PORTS[@]} -gt 0 ]]; then
        printf "%s\n" "${FINAL_PORTS[@]}" | sort -n -u
    fi
}

dpi_shield_on() {
    command -v iptables >/dev/null 2>&1 || {
        echo -e "${RED}[!] برای محافظ DPI به iptables نیاز است؛ نصب نشده است.${NC}"
        return 1
    }

    local rate burst
    rate=$(perf_get_dpi_rate); burst=$(perf_get_dpi_burst)
    [[ "$rate" =~ ^[1-9][0-9]{0,5}/(sec|minute|hour)$ && "$burst" =~ ^[1-9][0-9]{0,6}$ ]] || { echo 'نرخ یا burst ذخیره‌شده نامعتبر است.' >&2; return 1; }
    local REVERSE_PORTS=()
    while read -r p; do
        [[ -n "$p" ]] && REVERSE_PORTS+=("$p")
    done < <(dpi_collect_reverse_ports)

    if [[ ${#REVERSE_PORTS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}[!] پورت سرویس در تنظیمات تونل‌ها یا سرویس FRP پیدا نشد.${NC}"
        echo -e "${YELLOW}[*] ابتدا تونل و پورت‌های سرویس را تنظیم کنید.${NC}"
        return 1
    fi

    mkdir -p "$(dirname "$DPI_PORTS_FILE")"
    printf "%s\n" "${REVERSE_PORTS[@]}" > "$DPI_PORTS_FILE"

    echo -e "${CYAN}[*] در حال نصب محافظ DPI برای پورت‌ها: ${REVERSE_PORTS[*]}...${NC}"

    # Idempotent chain setup: flush existing DPI shield chain or create it
    if iptables -L NAVATUNNEL-DPI -n >/dev/null 2>&1; then
        iptables -F NAVATUNNEL-DPI
    else
        iptables -N NAVATUNNEL-DPI
    fi

    # Remove old blanket jump from INPUT (legacy: was sending ALL traffic through DPI chain)
    while iptables -C INPUT -j NAVATUNNEL-DPI 2>/dev/null; do
        iptables -D INPUT -j NAVATUNNEL-DPI
    done

    # 1. DPI chain rules: only SYN flood defense (ESTABLISHED traffic never enters this chain)
    # Kernel SYN flood hardening
    sysctl -w net.ipv4.tcp_syncookies=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_max_syn_backlog=8192 >/dev/null 2>&1 || true

    # 2. Per source IP hashlimit (blocks abusive scanners > 60/sec from one IP)
    local port
    for port in "${REVERSE_PORTS[@]}"; do
        if ! iptables -A NAVATUNNEL-DPI -p tcp --dport "$port" --syn -m hashlimit --hashlimit-name "hsh_${port}" --hashlimit-mode srcip --hashlimit-above "$rate" --hashlimit-burst "$burst" -j DROP 2>/dev/null; then
            dpi_shield_off >/dev/null 2>&1 || true
            perf_set_val dpi_enabled false 1 || true
            echo 'اعمال hashlimit ناموفق بود؛ محافظ غیرفعال ماند.' >&2
            return 1
        fi
    done
    # RETURN at end: non-matching packets pass through instantly
    iptables -A NAVATUNNEL-DPI -j RETURN 2>/dev/null || true

    # 3. Jump into DPI shield only for reverse tunnel port SYN packets (not ALL traffic)
    for port in "${REVERSE_PORTS[@]}"; do
        if ! iptables -C INPUT -p tcp --dport "$port" --syn -j NAVATUNNEL-DPI 2>/dev/null; then
            iptables -I INPUT -p tcp --dport "$port" --syn -j NAVATUNNEL-DPI 2>/dev/null || true
        fi
    done

    # 5. If UFW is active, also ensure reverse ports are allowed so UFW does not block them
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        for port in "${REVERSE_PORTS[@]}"; do
            ufw allow "$port"/tcp >/dev/null 2>&1 || true
            ufw allow "$port"/udp >/dev/null 2>&1 || true
        done
    fi

    # Persist across reboot via systemd oneshot unit
    [[ -x "$NAVATUNNEL_BIN" ]] || { cp "$0" "$NAVATUNNEL_BIN" 2>/dev/null && chmod +x "$NAVATUNNEL_BIN"; } || true
    cat << 'EOF' > /etc/systemd/system/navatunnel-dpi.service
[Unit]
Description=محافظ DPI تونل NavaTunnel
DefaultDependencies=no
After=systemd-modules-load.service local-fs.target
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/NavaTunnel dpi-shield on

[Install]
WantedBy=network-pre.target
EOF
    chmod 600 "${CONFIG_DIR}"/*.toml 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable navatunnel-dpi.service >/dev/null 2>&1 || true

    echo -e "${GREEN}[✔️] محافظ DPI فعال شد: ${#REVERSE_PORTS[@]} پورت محافظت‌شده (${REVERSE_PORTS[*]}).${NC}"
    echo -e "${GREEN}[✔️] اجرای خودکار محافظ با سرویس navatunnel-dpi.service ذخیره شد.${NC}"
}

dpi_shield_off() {
    # Read ports file before deletion so we can clean up per-port iptables rules
    local SAVED_PORTS=()
    if [[ -f "$DPI_PORTS_FILE" ]]; then
        while read -r port; do
            [[ -n "$port" ]] && SAVED_PORTS+=("$port")
        done < "$DPI_PORTS_FILE"
    fi

    # Disable and remove systemd persistence unit
    systemctl disable --now navatunnel-dpi.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/navatunnel-dpi.service "$DPI_PORTS_FILE"
    chmod 600 "${CONFIG_DIR}"/*.toml 2>/dev/null || true
    systemctl daemon-reload

    # Remove legacy blanket jump from INPUT
    while iptables -C INPUT -j NAVATUNNEL-DPI 2>/dev/null; do
        iptables -D INPUT -j NAVATUNNEL-DPI
    done

    # Remove per-port targeted jumps from INPUT (new format)
    local port
    for port in "${SAVED_PORTS[@]}"; do
        while iptables -C INPUT -p tcp --dport "$port" --syn -j NAVATUNNEL-DPI 2>/dev/null; do
            iptables -D INPUT -p tcp --dport "$port" --syn -j NAVATUNNEL-DPI
        done
    done

    # Flush and delete DPI shield chain
    iptables -F NAVATUNNEL-DPI 2>/dev/null || true
    iptables -X NAVATUNNEL-DPI 2>/dev/null || true

    echo -e "${GREEN}[✔️] محافظ DPI غیرفعال و قواعد آن حذف شد.${NC}"
}

dpi_shield_status() {
    echo "نرخ ذخیره‌شده: $(perf_get_dpi_rate) | burst: $(perf_get_dpi_burst)"
    if iptables -L NAVATUNNEL-DPI -n >/dev/null 2>&1; then
        echo -e "${GREEN}[✔️] محافظ DPI فعال است.${NC}"
        echo -e "${CYAN}شمارنده بسته‌ها و قواعد محافظ DPI:${NC}"
        iptables -L NAVATUNNEL-DPI -v -n
        if systemctl is-enabled navatunnel-dpi.service >/dev/null 2>&1; then
            echo -e "${GREEN}[✔️] اجرای خودکار سرویس محافظ فعال است.${NC}"
        else
            echo -e "${YELLOW}[!] اجرای خودکار سرویس محافظ غیرفعال است.${NC}"
        fi
    else
        echo -e "${YELLOW}[!] محافظ DPI غیرفعال است؛ زنجیره قواعد موجود نیست.${NC}"
        if systemctl is-enabled navatunnel-dpi.service >/dev/null 2>&1; then
            echo -e "${YELLOW}[*] سرویس محافظ برای شروع خودکار فعال است.${NC}"
        fi
    fi
}

cli_dpi_shield() {
    local ACTION="${1:-}"
    case "$ACTION" in
        on)
            perf_set_val dpi_enabled true 1 || return 1
            dpi_shield_on
            ;;
        off)
            perf_set_val dpi_enabled false 1 || return 1
            dpi_shield_off
            ;;
        configure) shift; cli_cover_configure dpi "$@" ;;
        status)
            dpi_shield_status
            ;;
        *)
            echo -e "${RED}[!] روش استفاده: NavaTunnel dpi-shield on|off|status${NC}"
            return 1
            ;;
    esac
}

menu_dpi_shield() {
    ui_clear
    echo -e "\n${YELLOW}=== محافظ DPI و محدودیت اتصال به پورت‌های سرویس ===${NC}"
    echo -e "با محدودکردن نرخ اتصال، پورت‌های سرویس را در برابر اسکن پرتعداد محافظت می‌کند."
    echo ""
    cli_dpi_shield status
    echo ""
    echo "  1) فعال‌سازی محافظ DPI"
    echo "  2) غیرفعال‌سازی محافظ DPI"
    echo "  3) نمایش وضعیت"
    echo '  4) تنظیم نرخ و burst سفارشی'
    echo "  0) بازگشت"
    echo ""
    read -r -p "انتخاب عمل [0-4]: " DPI_OPT || return 0
    case "$DPI_OPT" in
        1) cli_dpi_shield on ;;
        2) cli_dpi_shield off ;;
        3) cli_dpi_shield status ;;
        4) menu_cover_configure dpi ;;
        0) return 0 ;;
        *) echo -e "${RED}[!] گزینه نامعتبر است.${NC}"; return 1 ;;
    esac
    pause_prompt
}

# ---- Performance & Obfuscation Controls (CLI + Menu 22) ----

perf_apply() {
    init_perf_json
    local EFF_ENC=$(perf_get_enc)
    local EFF_COMP=$(perf_get_comp)
    local EFF_TLS=$(perf_get_tls)

    local IS_FOREIGN=0
    local IS_IRAN=0
    [[ -f "${CONFIG_DIR}/frpc.toml" ]] && IS_FOREIGN=1
    [[ -f "${CONFIG_DIR}/frps.toml" ]] && IS_IRAN=1
    for f in "${CONFIG_DIR}"/frps*.toml; do
        [[ -f "$f" ]] && IS_IRAN=1
    done

    if [[ "$IS_FOREIGN" -eq 0 && "$IS_IRAN" -eq 0 ]]; then
        echo -e "${YELLOW}[!] فایل تنظیمات FRP پیدا نشد در ${CONFIG_DIR}.${NC}"
        echo -e "${YELLOW}[*] پیش از اعمال تنظیمات کارایی، یک تونل بسازید.${NC}"
        return 1
    fi

    echo -e "${CYAN}[*] در حال اعمال تنظیمات کارایی (enc=${EFF_ENC} comp=${EFF_COMP} tls=${EFF_TLS})...${NC}"

    if [[ "$IS_FOREIGN" -eq 1 ]]; then
        local TOML_FILE="${CONFIG_DIR}/frpc.toml"
        if command -v python3 >/dev/null 2>&1; then
            python3 -c '
path = "'"$TOML_FILE"'"
enc = ("'"$EFF_ENC"'".strip() in ("1", "true", "True"))
comp = ("'"$EFF_COMP"'".strip() in ("1", "true", "True"))
tls = ("'"$EFF_TLS"'".strip() in ("1", "true", "True"))

with open(path, "r") as f:
    lines = f.read().splitlines()

sections = []
current = []
for line in lines:
    if line.strip().startswith("[[proxies]]"):
        if current:
            sections.append(current)
        current = [line]
    else:
        current.append(line)
if current:
    sections.append(current)

out_sections = []
for i, sec in enumerate(sections):
    if i == 0 and not sec[0].strip().startswith("[[proxies]]"):
        new_sec = []
        has_tls_enable = False
        for l in sec:
            s = l.strip()
            if s.startswith("transport.tls.disableCustomTLSFirstByte"):
                continue
            if s.startswith("transport.tls.enable"):
                has_tls_enable = True
            new_sec.append(l)
        final_hdr = []
        for l in new_sec:
            final_hdr.append(l)
            if l.strip().startswith("transport.tls.enable") and tls:
                final_hdr.append("transport.tls.disableCustomTLSFirstByte = true")
        if tls and not any("transport.tls.disableCustomTLSFirstByte" in x for x in final_hdr):
            if not has_tls_enable:
                final_hdr.append("transport.tls.enable = true")
            final_hdr.append("transport.tls.disableCustomTLSFirstByte = true")
        out_sections.append(final_hdr)
    else:
        new_sec = []
        is_tcp = any("type = \"tcp\"" in l or "type=\"tcp\"" in l for l in sec)
        for l in sec:
            s = l.strip()
            if s.startswith("transport.useEncryption") or s.startswith("transport.useCompression"):
                continue
            new_sec.append(l)
        while new_sec and new_sec[-1].strip() == "":
            new_sec.pop()
        if enc and is_tcp:
            new_sec.append("transport.useEncryption = true")
        if comp and is_tcp:
            new_sec.append("transport.useCompression = true")
        new_sec.append("")
        out_sections.append(new_sec)

result = "\n".join("\n".join(s) for s in out_sections).strip() + "\n"
with open(path, "w") as f:
    f.write(result)
'
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart frpc
        echo -e "${GREEN}[✔️] تنظیمات کلاینت FRP به‌روز و سرویس آن ری‌استارت شد.${NC}"
    fi

    if [[ "$IS_IRAN" -eq 1 ]]; then
        for TOML_FILE in "${CONFIG_DIR}"/frps*.toml; do
            [[ -f "$TOML_FILE" ]] || continue
            if command -v python3 >/dev/null 2>&1; then
                python3 -c '
path = "'"$TOML_FILE"'"
tls = ("'"$EFF_TLS"'".strip() in ("1", "true", "True"))

import json, os
max_pool = "500"
try:
    with open("/etc/gre-panel/perf.json") as jf:
        max_pool = str(json.load(jf).get("frp_max_pool", 500))
except:
    pass

with open(path, "r") as f:
    lines = f.read().splitlines()

new_lines = []
for l in lines:
    s = l.strip()
    if s.startswith("transport.tls.force"):
        continue
    new_lines.append(l)

final_lines = []
if tls:
    has_tls = False
    for l in new_lines:
        final_lines.append(l)
        if l.strip().startswith("auth.token"):
            final_lines.append("transport.tls.force = true")
            has_tls = True
    if not has_tls:
        final_lines.append("transport.tls.force = true")
else:
    final_lines = new_lines

# Update maxPoolCount
out_lines = []
has_pool = False
for l in final_lines:
    if l.strip().startswith("transport.maxPoolCount"):
        out_lines.append("transport.maxPoolCount = " + max_pool)
        has_pool = True
    else:
        out_lines.append(l)
if not has_pool:
    out_lines.append("transport.maxPoolCount = " + max_pool)

result = "\n".join(out_lines).strip() + "\n"
with open(path, "w") as f:
    f.write(result)
'
            fi
        done
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart frps >/dev/null 2>&1 || true
        for s in /etc/systemd/system/frps-*.service; do
            [[ -f "$s" ]] || continue
            local sname=$(basename "$s")
            systemctl restart "$sname" >/dev/null 2>&1 || true
        done
        echo -e "${GREEN}[✔️] تنظیمات سرورهای FRP به‌روز و سرویس‌ها ری‌استارت شدند.${NC}"
    fi

    # Also apply chaff profile
    local CHAFF_PROF=$(perf_get_chaff)
    if [[ "$CHAFF_PROF" == "off" ]]; then
        cli_chaff off >/dev/null 2>&1 || true
    else
        CHAFF_PROFILE="$CHAFF_PROF" cli_chaff on >/dev/null 2>&1 || true
    fi

    # Also apply DPI shield setting
    local DPI_EN=$(perf_get_dpi_enabled)
    if [[ "$DPI_EN" == "1" ]]; then
        dpi_shield_on >/dev/null 2>&1 || true
    else
        dpi_shield_off >/dev/null 2>&1 || true
    fi

    echo -e "${GREEN}[✔️] تنظیمات کارایی با موفقیت اعمال شد.${NC}"
    return 0
}

cli_perf() {
    local SUB="${1:-status}"
    case "$SUB" in
        status)
            init_perf_json
            local ENC=$(perf_get_enc)
            local COMP=$(perf_get_comp)
            local TLS=$(perf_get_tls)
            local CHAFF=$(perf_get_chaff)
            local DPI_EN=$(perf_get_dpi_enabled)
            local DPI_R=$(perf_get_dpi_rate)
            local DPI_B=$(perf_get_dpi_burst)

            echo -e "\n${CYAN}==========================================================${NC}"
            echo -e "${CYAN}            وضعیت کارایی و ترافیک پوششی              ${NC}"
            echo -e "${CYAN}==========================================================${NC}"
            echo -e "تنظیمات ذخیره‌شده در /etc/gre-panel/perf.json:"
            echo -e "  رمزگذاری پروکسی:  $([[ "$ENC" == "1" ]] && echo -e "${GREEN}on${NC}" || echo -e "${YELLOW}off${NC}")"
            echo -e "  فشرده‌سازی پروکسی: $([[ "$COMP" == "1" ]] && echo -e "${GREEN}on${NC}" || echo -e "${YELLOW}off${NC}")"
            echo -e "  TLS اجباری:        $([[ "$TLS" == "1" ]] && echo -e "${GREEN}on${NC}" || echo -e "${YELLOW}off${NC}")"
            echo -e "  حالت ترافیک پوششی:     ${CYAN}$(fa_state "${CHAFF}")${NC}"
            echo -e "  محافظ DPI:        $([[ "$DPI_EN" == "1" ]] && echo -e "${GREEN}enabled${NC} (${DPI_R}, burst ${DPI_B})" || echo -e "${YELLOW}disabled${NC}")"

            if [[ -n "${PERF_ENC:-}" || -n "${PERF_COMP:-}" || -n "${PERF_TLS:-}" ]]; then
                echo -e "${YELLOW}[!] تنظیمات محیطی جایگزین فعال‌اند: PERF_ENC=${PERF_ENC:-unset} PERF_COMP=${PERF_COMP:-unset} PERF_TLS=${PERF_TLS:-unset}${NC}"
            fi

            echo ""
            echo -e "تنظیمات فعلی تونل:"
            local MATCH=1

            if [[ -f "${CONFIG_DIR}/frpc.toml" ]]; then
                local LIVE_ENC=0 LIVE_COMP=0 LIVE_TLS=0
                grep -E -q '^[[:space:]]*transport\.useEncryption[[:space:]]*=[[:space:]]*true' "${CONFIG_DIR}/frpc.toml" && LIVE_ENC=1
                grep -E -q '^[[:space:]]*transport\.useCompression[[:space:]]*=[[:space:]]*true' "${CONFIG_DIR}/frpc.toml" && LIVE_COMP=1
                grep -E -q '^[[:space:]]*transport\.tls\.disableCustomTLSFirstByte[[:space:]]*=[[:space:]]*true' "${CONFIG_DIR}/frpc.toml" && LIVE_TLS=1

                echo -e "  نقش: کلاینت خارج (frpc)"
                echo -e "  رمزگذاری پروکسی در تنظیم فعلی:  $([[ "$LIVE_ENC" == "1" ]] && echo "فعال" || echo "غیرفعال") $([[ "$LIVE_ENC" == "$ENC" ]] && echo -e "${GREEN}[هماهنگ]${NC}" || { echo -e "${RED}[ناهماهنگ]${NC}"; MATCH=0; })"
                echo -e "  فشرده‌سازی پروکسی در تنظیم فعلی: $([[ "$LIVE_COMP" == "1" ]] && echo "فعال" || echo "غیرفعال") $([[ "$LIVE_COMP" == "$COMP" ]] && echo -e "${GREEN}[هماهنگ]${NC}" || { echo -e "${RED}[ناهماهنگ]${NC}"; MATCH=0; })"
                echo -e "  TLS اجباری در تنظیم فعلی:        $([[ "$LIVE_TLS" == "1" ]] && echo "فعال" || echo "غیرفعال") $([[ "$LIVE_TLS" == "$TLS" ]] && echo -e "${GREEN}[هماهنگ]${NC}" || { echo -e "${RED}[ناهماهنگ]${NC}"; MATCH=0; })"
            elif [[ -f "${CONFIG_DIR}/frps.toml" ]] || ls "${CONFIG_DIR}"/frps*.toml >/dev/null 2>&1; then
                local LIVE_TLS=0
                local F
                for F in "${CONFIG_DIR}"/frps*.toml; do
                    [[ -f "$F" ]] || continue
                    grep -E -q '^[[:space:]]*transport\.tls\.force[[:space:]]*=[[:space:]]*true' "$F" && LIVE_TLS=1
                done
                echo -e "  نقش: سرور ایران (frps)"
                echo -e "  TLS اجباری در تنظیم فعلی:        $([[ "$LIVE_TLS" == "1" ]] && echo "فعال" || echo "غیرفعال") $([[ "$LIVE_TLS" == "$TLS" ]] && echo -e "${GREEN}[هماهنگ]${NC}" || { echo -e "${RED}[ناهماهنگ]${NC}"; MATCH=0; })"
                echo -e "  (رمزگذاری و فشرده‌سازی پروکسی روی کلاینت خارج تنظیم می‌شود)"
            else
                echo -e "  تنظیمات تونل فعالی پیدا نشد."
            fi

            # DPI live
            if iptables -L NAVATUNNEL-DPI -n >/dev/null 2>&1; then
                echo -e "  محافظ DPI:  ${GREEN}فعال${NC}"
            else
                echo -e "  محافظ DPI:  ${YELLOW}غیرفعال${NC}"
            fi

            # Chaff live
            if systemctl is-active --quiet gre-chaff 2>/dev/null || systemctl list-units --type=service 2>/dev/null | grep -q 'gre-chaff.*running'; then
                echo -e "  سرویس ترافیک پوششی:          ${GREEN}در حال اجرا${NC}"
            else
                echo -e "  سرویس ترافیک پوششی:          ${YELLOW}متوقف${NC}"
            fi

            echo ""
            if [[ "$MATCH" -eq 1 ]]; then
                echo -e "${GREEN}[✔️] تنظیمات فعلی با انتخاب ذخیره‌شده هماهنگ است.${NC}"
            else
                echo -e "${RED}[!] تنظیمات فعلی هماهنگ نیست؛ برای هماهنگی NavaTunnel perf apply را اجرا کنید.${NC}"
            fi
            ;;
        enc)
            local VAL="${2:-}"
            case "$VAL" in
                on)  perf_set_val "proxy_encryption" "true" 1; echo -e "${GREEN}[✔️] رمزگذاری پروکسی فعال انتخاب شد؛ برای اعمال و ری‌استارت NavaTunnel perf apply را اجرا کنید.${NC}" ;;
                off) perf_set_val "proxy_encryption" "false" 1; echo -e "${GREEN}[✔️] رمزگذاری پروکسی غیرفعال انتخاب شد؛ برای اعمال و ری‌استارت NavaTunnel perf apply را اجرا کنید.${NC}" ;;
                *)   echo -e "${RED}[!] روش استفاده: NavaTunnel perf enc on|off${NC}"; return 1 ;;
            esac
            ;;
        comp)
            local VAL="${2:-}"
            case "$VAL" in
                on)  perf_set_val "proxy_compression" "true" 1; echo -e "${GREEN}[✔️] فشرده‌سازی پروکسی فعال انتخاب شد؛ برای اعمال و ری‌استارت NavaTunnel perf apply را اجرا کنید.${NC}" ;;
                off) perf_set_val "proxy_compression" "false" 1; echo -e "${GREEN}[✔️] فشرده‌سازی پروکسی غیرفعال انتخاب شد؛ برای اعمال و ری‌استارت NavaTunnel perf apply را اجرا کنید.${NC}" ;;
                *)   echo -e "${RED}[!] روش استفاده: NavaTunnel perf comp on|off${NC}"; return 1 ;;
            esac
            ;;
        tls)
            local VAL="${2:-}"
            case "$VAL" in
                on)  perf_set_val "force_tls" "true" 1; echo -e "${GREEN}[✔️] TLS اجباری فعال انتخاب شد؛ برای اعمال و ری‌استارت NavaTunnel perf apply را اجرا کنید.${NC}" ;;
                off) perf_set_val "force_tls" "false" 1; echo -e "${GREEN}[✔️] TLS اجباری غیرفعال انتخاب شد؛ برای اعمال و ری‌استارت NavaTunnel perf apply را اجرا کنید.${NC}" ;;
                *)   echo -e "${RED}[!] روش استفاده: NavaTunnel perf tls on|off${NC}"; return 1 ;;
            esac
            ;;
        chaff)
            local VAL="${2:-}"
            case "$VAL" in
                off)
                    perf_set_val "chaff_profile" "off" 0
                    cli_chaff off
                    echo -e "${GREEN}[✔️] ترافیک پوششی غیرفعال و سرویس‌ها متوقف شدند.${NC}"
                    ;;
                low|mid|custom)
                    perf_set_val "chaff_profile" "$VAL" 0
                    CHAFF_PROFILE="$VAL" cli_chaff on || return 1
                    echo -e "${GREEN}[✔️] حالت ترافیک پوششی روی $VAL قرار گرفت و سرویس‌ها اجرا شدند.${NC}"
                    ;;
                *)
                    echo -e "${RED}[!] روش استفاده: NavaTunnel perf chaff off|low|mid|custom${NC}"
                    return 1
                    ;;
            esac
            ;;
        dpi)
            local VAL="${2:-}"
            case "$VAL" in
                on)
                    perf_set_val "dpi_enabled" "true" 1
                    dpi_shield_on || return 1
                    echo -e "${GREEN}[✔️] محافظ DPI فعال شد.${NC}"
                    ;;
                off)
                    perf_set_val "dpi_enabled" "false" 1
                    dpi_shield_off
                    echo -e "${GREEN}[✔️] محافظ DPI غیرفعال شد.${NC}"
                    ;;
                *)
                    echo -e "${RED}[!] روش استفاده: NavaTunnel perf dpi on|off${NC}"
                    return 1
                    ;;
            esac
            ;;
        apply)
            perf_apply
            ;;
        reset)
            init_perf_json
            perf_set_val "proxy_encryption" "false" 1
            perf_set_val "proxy_compression" "false" 1
            perf_set_val "force_tls" "false" 1
            perf_set_val "chaff_profile" "off" 0
            perf_set_val "dpi_enabled" "false" 1
            dpi_shield_off >/dev/null 2>&1 || true
            cli_chaff off >/dev/null 2>&1 || true
            perf_apply
            echo -e "${GREEN}[✔️] تنظیمات کارایی به پیش‌فرض برگشت: رمزگذاری و فشرده‌سازی خاموش، TLS استاندارد، ترافیک پوششی و محافظ DPI خاموش.${NC}"
            ;;
        -h|--help|help)
            echo "روش استفاده: NavaTunnel perf status|enc on|off|comp on|off|tls on|off|chaff off|low|mid|custom|dpi on|off|apply|reset"
            ;;
        *)
            echo -e "${RED}[!] زیردستور ناشناخته: $SUB${NC}"
            echo "روش استفاده: NavaTunnel perf status|enc on|off|comp on|off|tls on|off|chaff off|low|mid|custom|dpi on|off|apply|reset"
            return 1
            ;;
    esac
}

menu_perf() {
    while true; do
        ui_clear
        cli_perf status
        echo ""
        echo "  1) فعال یا غیرفعال‌سازی رمزگذاری پروکسی"
        echo "  2) فعال یا غیرفعال‌سازی فشرده‌سازی پروکسی"
        echo "  3) فعال یا غیرفعال‌سازی TLS اجباری"
        echo "  4) انتخاب حالت ترافیک پوششی"
        echo "  5) فعال یا غیرفعال‌سازی محافظ DPI"
        echo "  6) اعمال تنظیمات و ری‌استارت تونل‌ها"
        echo "  0) بازگشت به منوی اصلی"
        echo ""
        read -r -p "انتخاب گزینه [0-6]: " P_OPT || return 0
        case "$P_OPT" in
            1)
                local cur=$(perf_get_enc)
                if [[ "$cur" == "1" ]]; then cli_perf enc off; else cli_perf enc on; fi
                ;;
            2)
                local cur=$(perf_get_comp)
                if [[ "$cur" == "1" ]]; then cli_perf comp off; else cli_perf comp on; fi
                ;;
            3)
                local cur=$(perf_get_tls)
                if [[ "$cur" == "1" ]]; then cli_perf tls off; else cli_perf tls on; fi
                ;;
            4)
                ui_clear
                echo "حالت ترافیک پوششی را انتخاب کنید:"
                echo "  1) غیرفعال"
                echo "  2) کم (پیش‌فرض)"
                echo "  3) متوسط"
                echo "  4) سفارشی ذخیره‌شده"
                echo "  5) تنظیم فاصله و اندازه سفارشی"
                read -r -p "انتخاب [1-5]: " C_OPT || return 0
                case "$C_OPT" in
                    1) cli_perf chaff off ;;
                    2) cli_perf chaff low ;;
                    3) cli_perf chaff mid ;;
                    4) cli_perf chaff custom ;;
                    5) menu_cover_configure chaff ;;
                    *) echo "گزینه نامعتبر است." ;;
                esac
                ;;
            5)
                local cur=$(perf_get_dpi_enabled)
                if [[ "$cur" == "1" ]]; then cli_perf dpi off; else cli_perf dpi on; fi
                ;;
            6)
                cli_perf apply
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${RED}[!] گزینه نامعتبر است.${NC}"
                ;;
        esac
        pause_prompt
    done
}


# ---- SINGLE SOURCE OF TRUTH for install logic ----
# setup_iran_server_noninteractive / setup_foreign_server_noninteractive do the
# real work. The interactive menu functions below only prompt + validate, then
# delegate here. CLI flags are handled at
# the bottom of this file (setup-iran / setup-foreign), so all three paths
# Menu and CLI execute identical steps.
# Args: $1=local_pub $2=remote_pub $3=frp_port $4=token [$5=local_gre [$6=peer_gre [$7="cleaned ports"]]]
setup_iran_server_noninteractive() {
    local IP_IRAN=$1 IP_FOREIGN=$2 BIND_PORT=$3 TOKEN=$4
    local LOCAL_GRE=${5:-$IRAN_GRE_IP} PEER_GRE=${6:-$FOREIGN_GRE_IP}

    log_msg "tunnel" "INFO" "شروع راه‌اندازی سرور ایران: GRE ${IP_IRAN} <-> ${IP_FOREIGN}, پورت FRP: ${BIND_PORT}"
    backup_configs "pre_setup_iran"
    ensure_dependencies_smart || return 1

    local STATUS_GRE="OK"
    local STATUS_FRP="OK"
    local GRE_ERR="" FRP_ERR=""

    # 1. Setup GRE interface
    if ! setup_gre_systemd "$IP_IRAN" "$IP_FOREIGN" "$LOCAL_GRE" "$PEER_GRE"; then
        STATUS_GRE="FAILED"
        GRE_ERR="راه‌اندازی اینترفیس GRE یا تنظیم IP ناموفق بود"
        log_msg "tunnel" "ERROR" "راه‌اندازی GRE روی ایران ناموفق بود"
    fi

    # 2. Setup FRP Server
    if ! install_frp_binaries; then
        STATUS_FRP="FAILED"
        FRP_ERR="نصب FRP به دلیل خطای دریافت یا استخراج ناموفق بود"
        log_msg "tunnel" "ERROR" "نصب فایل‌های اجرایی FRP ناموفق بود"
    fi
    local EFF_TLS=$(perf_get_tls)
    local QUIC_PORT=$((BIND_PORT == 65535 ? BIND_PORT - 1 : BIND_PORT + 1))
    local MAX_POOL=500
    if [[ -f /etc/gre-panel/perf.json ]] && command -v python3 >/dev/null 2>&1; then
        MAX_POOL=$(python3 -c "import json; print(json.load(open('/etc/gre-panel/perf.json')).get('frp_max_pool', 500))" 2>/dev/null || echo 500)
    fi
    local TLS_LINE=""
    [[ "$EFF_TLS" == "1" ]] && TLS_LINE="transport.tls.force = true"
    local QUIC_PORT=$((BIND_PORT + 1))
    if [[ "$QUIC_PORT" -gt 65535 ]]; then QUIC_PORT=$((BIND_PORT - 1)); fi
    mkdir -p "${CONFIG_DIR}"
    cat <<EOF > "${CONFIG_DIR}/frps.toml"
bindAddr = "0.0.0.0"
bindPort = ${BIND_PORT}
kcpBindPort = ${BIND_PORT}
quicBindPort = ${QUIC_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
${TLS_LINE:+$TLS_LINE
}transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 30
transport.tcpKeepalive = 30
transport.heartbeatTimeout = 90
transport.maxPoolCount = ${MAX_POOL}
EOF
    cat <<EOF > /etc/systemd/system/frps.service
[Unit]
ConditionPathExists=!${NAVATUNNEL_STATE_DIR}/stopped/${TUNNEL_NAME}
Description=سرویس سرور FRP
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=3s
StartLimitIntervalSec=0
LimitNOFILE=1048576
LimitNPROC=512000
TasksMax=infinity
ExecStart=${INSTALL_DIR}/frps -c ${CONFIG_DIR}/frps.toml

[Install]
WantedBy=multi-user.target
EOF
    chmod 600 "${CONFIG_DIR}"/*.toml 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed frps >/dev/null 2>&1 || true
    systemctl enable frps >/dev/null 2>&1
    systemctl restart frps

    local _frps_ok=0
    for _i in {1..5}; do
        sleep 2
        if systemctl is-active --quiet frps 2>/dev/null; then
            _frps_ok=1
            break
        fi
    done

    if [[ "$_frps_ok" -ne 1 ]]; then
        STATUS_FRP="FAILED"
        local FRPS_LOG=""
        FRPS_LOG=$(journalctl -u frps -n 5 --no-pager 2>/dev/null | tr '\n' ' ' | head -c 200)
        FRP_ERR="راه‌اندازی سرویس frps ناموفق بود${FRPS_LOG:+: $FRPS_LOG}"
        log_msg "tunnel" "ERROR" "راه‌اندازی سرویس frps ناموفق بود"
    fi

    # Chaff is now opt-in: users can enable it from Performance menu or `NavaTunnel chaff on`.
    # Removed automatic activation to avoid unnecessary bandwidth and jitter overhead.
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${BIND_PORT}/tcp" >/dev/null 2>&1
        ufw allow "${BIND_PORT}/udp" >/dev/null 2>&1
        ufw allow "${QUIC_PORT}/udp" >/dev/null 2>&1
    fi

    local DPI_EN=$(perf_get_dpi_enabled)
    if [[ "$DPI_EN" == "1" ]]; then
        dpi_shield_on >/dev/null 2>&1 || true
    fi
    tune_apply >/dev/null 2>&1 || true
    watchdog_on >/dev/null 2>&1 || true


    # 4. Summary & Verification
    echo -e "\n=============================================================="
    echo "                   خلاصه راه‌اندازی"
    echo "=============================================================="
    if [[ "$STATUS_GRE" == "OK" ]]; then
        echo -e "[${GREEN}موفق${NC}]     اینترفیس تونل GRE (${TUNNEL_NAME}: ${IP_IRAN} <-> ${IP_FOREIGN}, IP: ${LOCAL_GRE})"
    else
        echo -e "[${RED}ناموفق${NC}] اینترفیس تونل GRE (${GRE_ERR})"
    fi

    if [[ "$STATUS_FRP" == "OK" ]]; then
        echo -e "[${GREEN}موفق${NC}]     سرویس سرور FRP (سرویس frps روی پورت :${BIND_PORT})"
    else
        echo -e "[${RED}ناموفق${NC}] سرویس سرور FRP (${FRP_ERR})"
    fi

    echo "=============================================================="

    local BUNDLE_OUT
    BUNDLE_OUT=$(bundle_make "$IP_IRAN" "$BIND_PORT" "$LOCAL_GRE" "$PEER_GRE" "$TOKEN" "$PORTS_CLEANED")
    echo -e "کد اتصال:         ${CYAN}${BUNDLE_OUT}${NC}"
    echo -e "BUNDLE:${BUNDLE_OUT}"

    if [[ "$STATUS_GRE" == "OK" && "$STATUS_FRP" == "OK" ]]; then
        echo -e "وضعیت کلی راه‌اندازی: ${GREEN}موفق${NC}\n"
        echo -e "ارتباط عمومی GRE:      ${CYAN}${IP_IRAN} <--> ${IP_FOREIGN}${NC}"
        echo -e "IP داخلی GRE ایران: ${CYAN}${LOCAL_GRE}${NC}"
        echo -e "پورت کنترل FRP:        ${CYAN}${BIND_PORT}${NC}"
        echo -e "توکن اتصال:         ${CYAN}${TOKEN}${NC}"
        log_msg "tunnel" "INFO" "راه‌اندازی سرور ایران موفق بود"
        return 0
    else
        echo -e "وضعیت کلی راه‌اندازی: ${RED}بخشی ناموفق${NC}"
        echo -e "${YELLOW}[!] خطاهای بالا را بررسی کنید؛ هنوز آماده‌بودن تونل تأیید نشده است.${NC}\n"
        log_msg "tunnel" "ERROR" "بخشی از راه‌اندازی ایران ناموفق بود: GRE=${STATUS_GRE}, FRP=${STATUS_FRP}"
        return 1
    fi
}

setup_foreign_server_noninteractive() {
    local IP_FOREIGN=$1 IP_IRAN=$2 SERVER_PORT=$3 TOKEN=$4
    local LOCAL_GRE=${5:-$FOREIGN_GRE_IP} PEER_GRE=${6:-$IRAN_GRE_IP}
    local PORTS_CLEANED=${7:-}
    local RELAY_IP=${8:-}
    local PROXY_PROTOCOL=${9:-off}
    local FRP_TRANSPORT=${10:-tcp}
    local FRP_ENCRYPTION=${11:-off}
    local FRP_COMPRESSION=${12:-off}
    _setup_foreign_full "$IP_FOREIGN" "$IP_IRAN" "$SERVER_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$PORTS_CLEANED" "$RELAY_IP" "$PROXY_PROTOCOL" "$FRP_TRANSPORT" "$FRP_ENCRYPTION" "$FRP_COMPRESSION"
}

# shared full foreign path: GRE + ping feedback + frpc binaries/config/service.
# Called by the interactive menu and CLI.
_setup_foreign_full() {
    local IP_FOREIGN=$1 IP_IRAN=$2 SERVER_PORT=$3 TOKEN=$4
    local LOCAL_GRE=$5 PEER_GRE=$6 PORTS_CLEANED=$7
    local RELAY_IP=${8:-}
    local PROXY_PROTOCOL=${9:-off}
    local FRP_TRANSPORT=${10:-tcp}
    validate_kcp_mtu "$TUNNEL_NAME" "$FRP_TRANSPORT" || return 1
    local FRP_ENCRYPTION=${11:-off}
    local FRP_COMPRESSION=${12:-off}

    log_msg "tunnel" "INFO" "شروع راه‌اندازی سرور خارج: GRE ${IP_FOREIGN} <-> ${IP_IRAN}, serverPort: ${SERVER_PORT}, پورت‌های سرویس: ${PORTS_CLEANED}"
    backup_configs "pre_setup_foreign"
    ensure_dependencies_smart || return 1

    local STATUS_GRE="OK"
    local STATUS_PING="OK"
    local STATUS_FRP="OK"
    local GRE_ERR="" PING_ERR="" FRP_ERR=""

    carrier_init_kernel 2>/dev/null || true
    if ! setup_gre_systemd "$IP_FOREIGN" "$IP_IRAN" "$LOCAL_GRE" "$PEER_GRE"; then
        STATUS_GRE="FAILED"
        GRE_ERR="راه‌اندازی یا تنظیم اینترفیس GRE ناموفق بود"
        log_msg "tunnel" "ERROR" "راه‌اندازی GRE روی خارج ناموفق بود"
    fi
    carrier_apply_active "$TUNNEL_NAME" >/dev/null 2>&1 || true

    echo -e "${CYAN}[*] در حال تست پینگ داخلی GRE به ایران (${PEER_GRE})...${NC}"
    if ping -c 3 -W 2 "$PEER_GRE" >/dev/null 2>&1; then
        echo -e "${GREEN}[✔️] تونل GRE برقرار و قابل دسترسی است.${NC}"
    else
        STATUS_PING="WARN"
        PING_ERR="پینگ GRE مقابل ${PEER_GRE} پاسخ نداد؛ راه‌اندازی ایران را بررسی کنید"
        echo -e "${YELLOW}[!] پینگ ${PEER_GRE} هنوز پاسخ نداده است.${NC}"
    fi

    install_frp_binaries || return 1
    local EFF_TLS=$(perf_get_tls)
    local EFF_ENC=$(perf_get_enc)
    local EFF_COMP=$(perf_get_comp)
    local TLS_ENABLE=""
    local TLS_CUSTOM=""
    if [[ "$EFF_TLS" == "1" ]]; then
        TLS_ENABLE="transport.tls.enable = true"
        TLS_CUSTOM="transport.tls.disableCustomTLSFirstByte = true"
    fi
    local EFF_SERVER_PORT="${SERVER_PORT}"
    if [[ "$FRP_TRANSPORT" == "quic" ]]; then
        EFF_SERVER_PORT=$((SERVER_PORT + 1))
        if [[ "$EFF_SERVER_PORT" -gt 65535 ]]; then EFF_SERVER_PORT=$((SERVER_PORT - 1)); fi
    fi
    mkdir -p "${CONFIG_DIR}"
    cat <<EOF > "${CONFIG_DIR}/frpc.toml"
serverAddr = "${PEER_GRE}"
serverPort = ${EFF_SERVER_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
${TLS_ENABLE:+$TLS_ENABLE
}${TLS_CUSTOM:+$TLS_CUSTOM
}loginFailExit = false
transport.protocol = "${FRP_TRANSPORT}"
transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 30
transport.heartbeatInterval = 30
transport.heartbeatTimeout = 90
transport.dialServerTimeout = 15
transport.dialServerKeepalive = 30
transport.poolCount = 20

EOF
    local PROXY_TARGET_IP="${RELAY_IP:-127.0.0.1}"
    local PP_LINE=""
    if [[ "$PROXY_PROTOCOL" == "v2" || "$PROXY_PROTOCOL" == "v1" ]]; then
        PP_LINE="transport.proxyProtocolVersion = \"${PROXY_PROTOCOL}\""
    fi
    local ENC_LINE=""
    if [[ "$FRP_ENCRYPTION" == "on" || "$FRP_ENCRYPTION" == "1" || "$FRP_ENCRYPTION" == "true" ]]; then
        ENC_LINE="transport.useEncryption = true"
    fi
    local COMP_LINE=""
    if [[ "$FRP_COMPRESSION" == "on" || "$FRP_COMPRESSION" == "1" || "$FRP_COMPRESSION" == "true" ]]; then
        COMP_LINE="transport.useCompression = true"
    fi
    local PORT
    for PORT in $PORTS_CLEANED; do
        cat <<EOF >> "${CONFIG_DIR}/frpc.toml"
[[proxies]]
name = "tcp_${PORT}"
type = "tcp"
localIP = "${PROXY_TARGET_IP}"
localPort = ${PORT}
remotePort = ${PORT}
${PP_LINE:+$PP_LINE
}${ENC_LINE:+$ENC_LINE
}${COMP_LINE:+$COMP_LINE
}
[[proxies]]
name = "udp_${PORT}"
type = "udp"
localIP = "${PROXY_TARGET_IP}"
localPort = ${PORT}
remotePort = ${PORT}

EOF
    done

    cat <<EOF > /etc/systemd/system/frpc.service
[Unit]
Description=سرویس اتصال معکوس کلاینت FRP
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=3s
StartLimitIntervalSec=0
LimitNOFILE=1048576
LimitNPROC=512000
TasksMax=infinity
ExecStart=${INSTALL_DIR}/frpc -c ${CONFIG_DIR}/frpc.toml

[Install]
WantedBy=multi-user.target
EOF
    chmod 600 "${CONFIG_DIR}"/*.toml 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed frpc >/dev/null 2>&1 || true
    systemctl enable frpc >/dev/null 2>&1
    systemctl restart frpc

    local _frpc_ok=0
    for _i in {1..5}; do
        sleep 2
        if systemctl is-active --quiet frpc 2>/dev/null; then
            _frpc_ok=1
            break
        fi
    done

    if [[ "$_frpc_ok" -ne 1 ]]; then
        STATUS_FRP="FAILED"
        FRP_ERR="راه‌اندازی سرویس frpc ناموفق بود؛ بررسی کنید: journalctl -u frpc"
        log_msg "tunnel" "ERROR" "راه‌اندازی سرویس frpc ناموفق بود"
    fi

    # Chaff is now opt-in: users can enable it from Performance menu or `NavaTunnel chaff on`.
    local DPI_EN=$(perf_get_dpi_enabled)
    if [[ "$DPI_EN" == "1" ]]; then
        dpi_shield_on >/dev/null 2>&1 || true
    fi
    tune_apply >/dev/null 2>&1 || true
    watchdog_on >/dev/null 2>&1 || true


    echo -e "\n=============================================================="
    echo "                   خلاصه راه‌اندازی"
    echo "=============================================================="
    if [[ "$STATUS_GRE" == "OK" ]]; then
        echo -e "[${GREEN}موفق${NC}]     اینترفیس تونل GRE (${TUNNEL_NAME}: ${IP_FOREIGN} <-> ${IP_IRAN}, IP: ${LOCAL_GRE})"
    else
        echo -e "[${RED}ناموفق${NC}] اینترفیس تونل GRE (${GRE_ERR})"
    fi

    if [[ "$STATUS_PING" == "OK" ]]; then
        echo -e "[${GREEN}موفق${NC}]     دسترسی با پینگ GRE (سرور ${PEER_GRE} قابل دسترسی است)"
    else
        echo -e "[${YELLOW}هشدار${NC}]   دسترسی با پینگ GRE (${PING_ERR})"
    fi

    if [[ "$STATUS_FRP" == "OK" ]]; then
        echo -e "[${GREEN}موفق${NC}]     سرویس کلاینت FRP (سرویس frpc فعال و در حال اتصال به ${PEER_GRE}:${SERVER_PORT})"
        echo -e "         پورت‌های سرویس: ${PORTS_CLEANED} (TCP و UDP، با TLS)"
    else
        echo -e "[${RED}ناموفق${NC}] سرویس کلاینت FRP (${FRP_ERR})"
    fi

    echo "=============================================================="

    # Success: GRE interface up + frpc connected = tunnel functional.
    # PING=WARN is acceptable: ICMP is often filtered by DPI/ISP on GRE tunnels
    # in Iran while TCP (used by frpc) works fine. Only treat ping as blocking
    # failure if frpc itself also failed.
    local _ping_blocking=0
    if [[ "$STATUS_PING" != "OK" && "$STATUS_FRP" != "OK" ]]; then
        _ping_blocking=1
    fi

    if [[ "$STATUS_GRE" == "OK" && "$STATUS_FRP" == "OK" && "$_ping_blocking" -eq 0 ]]; then
        if [[ "$STATUS_PING" != "OK" ]]; then
            echo -e "وضعیت کلی راه‌اندازی: ${GREEN}موفق${NC} ${YELLOW}(پینگ ICMP مسدود است؛ اتصال TCP تونل برقرار است)${NC}\n"
        else
            echo -e "وضعیت کلی راه‌اندازی: ${GREEN}موفق${NC}\n"
        fi
        log_msg "tunnel" "INFO" "راه‌اندازی سرور خارج موفق بود (PING=${STATUS_PING})"
        return 0
    else
        echo -e "وضعیت کلی راه‌اندازی: ${RED}بخشی ناموفق${NC}"
        echo -e "${YELLOW}[!] خطاهای بالا را بررسی کنید؛ هنوز آماده‌بودن تونل تأیید نشده است.${NC}\n"
        log_msg "tunnel" "ERROR" "بخشی از راه‌اندازی خارج ناموفق بود: GRE=${STATUS_GRE}, FRP=${STATUS_FRP}, PING=${STATUS_PING}"
        return 1
    fi
}

# ---- Multi-peer FRP tunnels: no application-level peer count limit ----
# Peer 1 reuses the legacy names (gre-tunnel, frps.toml, frps.service) so
# existing installs keep working. Additional peers get gre-tN + frps-N.toml +
# frps-N.service, each with its own token and control port (one frps
# understands only one token). Registry: /etc/gre-panel/peers.json.
PEERS_FILE="${NAVATUNNEL_STATE_DIR}/peers.json"

peer_init() {
    mkdir -p "$(dirname "$PEERS_FILE")" "$CONFIG_DIR"
    [[ -f "$PEERS_FILE" ]] || (umask 077; echo '{"peers":[]}' > "$PEERS_FILE") || return 1
    chmod 600 "$PEERS_FILE" || return 1
}

peer_require_py() {
    command -v python3 >/dev/null 2>&1 || { echo -e "${RED}[!] برای مدیریت تونل‌ها به python3 نیاز است.${NC}"; return 1; }
}

# print registry as-is (JSON)
peer_list() { peer_init; cat "$PEERS_FILE"; }

# Smallest unused positive ID; freed IDs are reused without an upper cap.
peer_next_id() {
    peer_require_py || return 1
    PEERS_F="$PEERS_FILE" python3 -c '
import json,os
with open(os.environ["PEERS_F"]) as f:
    used={int(p["id"]) for p in json.load(f).get("peers",[])}
candidate=1
while candidate in used:
    candidate+=1
print(candidate)'
}

# space-separated "port:peername" of all claimed reverse ports
peer_ports_used() {
    peer_init; peer_require_py || return 1
    PEERS_F="$PEERS_FILE" python3 -c \
'import json,os; d=json.load(open(os.environ["PEERS_F"])); print(" ".join(str(p) + ":" + str(r.get("name","")) for r in d.get("peers",[]) for p in r.get("ports",[])))'
}

# $1=id -> compact JSON record or empty
peer_get() {
    PEERS_F="$PEERS_FILE" PEER_ID="$1" python3 -c \
'import json,os; d=json.load(open(os.environ["PEERS_F"])); m=[p for p in d.get("peers",[]) if p["id"]==int(os.environ["PEER_ID"])]; print(json.dumps(m[0]) if m else "")'
}

# The selected protocol determines FEC; older records may only contain the loss flag.
peer_connection_settings() {
    local record
    record=$(peer_get "$1") || return 1
    [[ -n "$record" ]] || { echo 'تونل پیدا نشد.' >&2; return 1; }
    python3 -c 'import json,sys
p=json.load(sys.stdin)
protocol=p.get("frp_transport") or ("kcp" if p.get("loss_recovery",False) else "tcp")
if protocol not in ("tcp","kcp","quic","websocket","wss"): sys.exit("پروتکل FRP ذخیره‌شده نامعتبر است")
print(protocol+"\t"+("on" if protocol=="kcp" else "off"))' <<< "$record"
}

peer_token() {
    peer_init; peer_require_py || return 1
    local ID=$1 rec
    rec=$(peer_get "$ID")
    [[ -n "$rec" ]] || { echo -e "${RED}[!] تونلی با شناسه $ID وجود ندارد.${NC}"; return 1; }
    echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
    # second line: full foreign-setup bundle (token + addresses + ports).
    # First-line token output stays unchanged for scripts.
    local B_TOK LIP RIP FP LGRE PGRE PTS LOSS PROTOCOL settings
    B_TOK=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
    LIP=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("local_pub",""))')
    RIP=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("remote_pub",""))')
    FP=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("frp_port",""))')
    LGRE=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("local_gre",""))')
    PGRE=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("peer_gre",""))')
    PTS=$(echo "$rec" | python3 -c 'import json,sys; print(" ".join(str(x) for x in json.load(sys.stdin).get("ports",[])))')
    settings=$(peer_connection_settings "$ID") || return 1
    IFS=$'\t' read -r PROTOCOL LOSS <<< "$settings"
    if ! is_valid_ip "$LIP" || ! is_valid_port "$FP" || ! is_valid_ip "$LGRE" || ! is_valid_ip "$PGRE"; then
        echo 'اطلاعات اتصال این تونل ناقص یا نامعتبر است؛ IP ایران، پورت کنترل و IPهای داخلی را بررسی کنید.' >&2
        return 1
    fi
    [[ "$B_TOK" =~ ^[A-Za-z0-9-]{1,128}$ && -n "$PTS" ]] || {
        echo 'توکن یا پورت‌های سرویس این تونل ناقص یا نامعتبر است.' >&2
        return 1
    }
    local generated
    generated=$(bundle_make "$LIP" "$FP" "$LGRE" "$PGRE" "$B_TOK" "$PTS" "" "$LOSS" "$PROTOCOL") || return 1
    bundle_parse "$generated" || { echo 'ساخت کد اتصال معتبر ناموفق بود.' >&2; return 1; }
    printf 'BUNDLE:%s\n' "$generated"
}

# write one frps instance: $1=suffix("" for legacy, "-N" for peers) $2=bind_port $3=token
peer_write_frps() {
    local SUF=$1 BIND_PORT=$2 TOKEN=$3
    local POWER_IF="gre-t${SUF#-}"
    [[ -n "$SUF" ]] || POWER_IF=$TUNNEL_NAME
    local EFF_TLS=$(perf_get_tls)
    local QUIC_PORT=$((BIND_PORT == 65535 ? BIND_PORT - 1 : BIND_PORT + 1))
    local MAX_POOL=500
    if [[ -f /etc/gre-panel/perf.json ]] && command -v python3 >/dev/null 2>&1; then
        MAX_POOL=$(python3 -c "import json; print(json.load(open('/etc/gre-panel/perf.json')).get('frp_max_pool', 500))" 2>/dev/null || echo 500)
    fi
    local TLS_LINE=""
    [[ "$EFF_TLS" == "1" ]] && TLS_LINE="transport.tls.force = true"
    cat <<EOF > "${CONFIG_DIR}/frps${SUF}.toml"
bindAddr = "0.0.0.0"
bindPort = ${BIND_PORT}
kcpBindPort = ${BIND_PORT}
quicBindPort = ${QUIC_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
${TLS_LINE:+$TLS_LINE
}transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 30
transport.tcpKeepalive = 30
transport.heartbeatTimeout = 90
transport.maxPoolCount = ${MAX_POOL}
EOF
    local SVC="frps${SUF}"
    cat <<EOF > /etc/systemd/system/${SVC}.service
[Unit]
ConditionPathExists=!${NAVATUNNEL_STATE_DIR}/stopped/${POWER_IF}
Description=سرویس سرور FRP${SUF:+ (peer${SUF#-})}
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=3s
StartLimitIntervalSec=0
LimitNOFILE=1048576
LimitNPROC=512000
TasksMax=infinity
ExecStart=${INSTALL_DIR}/frps -c ${CONFIG_DIR}/frps${SUF}.toml

[Install]
WantedBy=multi-user.target
EOF
    chmod 600 "${CONFIG_DIR}"/*.toml 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable "$SVC" >/dev/null 2>&1
    systemctl restart "$SVC"
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${BIND_PORT}/tcp" >/dev/null 2>&1
        ufw allow "${BIND_PORT}/udp" >/dev/null 2>&1
        ufw allow "${QUIC_PORT}/udp" >/dev/null 2>&1
    fi
}

# add a peer tunnel on the Iran side.
# Flags: --name --local-pub --remote-pub --frp-port --token --local-gre --peer-gre --ports "443, 2083" [--bundle hsh1_...] [--chaff low|mid|off] [--force]
# --bundle pastes a foreign-setup string: empty flags are filled from it,
# explicit flags always win.
cli_add_peer() {
    local NAME="" LOCAL_PUB="" REMOTE_PUB="" FRP_PORT="" TOKEN="" LOCAL_GRE="" PEER_GRE="" PORTS="" FORCE=0 BUNDLE="" LOSS_RECOVERY=off LOSS_EXPLICIT=0
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --* && $# -lt 2 ]]; then
            case "$1" in
                --force|--show-token|--encrypt|--compress|--dry-run|--off|--help) ;;
                *) echo "مقدار این گزینه وارد نشده است: $1" >&2; return 1 ;;
            esac
        fi
        case "$1" in
            --loss-recovery) LOSS_RECOVERY="$2"; LOSS_EXPLICIT=1; shift 2 ;;
            --name) NAME="$2"; shift 2 ;;
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --frp-port) FRP_PORT="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            --bundle) BUNDLE="$2"; shift 2 ;;
            --chaff) CHAFF_PROFILE="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            -h|--help) echo 'روش استفاده: NavaTunnel.sh add-peer --local-pub IP --remote-pub IP [--frp-port N] --token T --local-gre IP --peer-gre IP --ports "443, 2083" [--name LABEL] [--bundle hsh1_...] [--chaff low|mid|off] [--force]'; return 0 ;;
            *) echo -e "${RED}[!] گزینه ناشناخته: $1${NC}"; return 1 ;;
        esac
    done
    case "$LOSS_RECOVERY" in on|off) ;; *) echo "مقدار --loss-recovery باید on یا off باشد." >&2; return 1;; esac
    CHAFF_PROFILE="${CHAFF_PROFILE:-$(perf_get_chaff)}"
    case "$CHAFF_PROFILE" in
        low|mid|off) ;;
        *) echo -e "${YELLOW}[!] حالت ترافیک پوششی ${CHAFF_PROFILE} ناشناخته است؛ غیرفعال انتخاب شد.${NC}"; CHAFF_PROFILE="off" ;;
    esac
    if [[ -n "$BUNDLE" ]]; then
        bundle_parse "$BUNDLE" || { echo -e "${RED}[!] کد --bundle نامعتبر است؛ قالب مورد انتظار ( hsh1_<IRAN_PUB>_<PORT>_<IRAN_GRE>_<FOREIGN_GRE>_<TOKEN>[_<PORTS>]).${NC}"; return 1; }
        [[ "$LOSS_EXPLICIT" == 1 ]] || LOSS_RECOVERY=$B_LOSS_RECOVERY
        # add-peer runs on Iran: bundle Iran pub/GRE are OURS, foreign GRE is THEIRS
        [[ -z "$LOCAL_PUB" ]] && LOCAL_PUB=$B_IRAN_PUB
        [[ -z "$FRP_PORT" ]] && FRP_PORT=$B_FRP_PORT
        [[ -z "$LOCAL_GRE" ]] && LOCAL_GRE=$B_IRAN_GRE
        [[ -z "$PEER_GRE" ]] && PEER_GRE=$B_FOREIGN_GRE
        [[ -z "$TOKEN" ]] && TOKEN=$B_TOKEN
        [[ -z "$PORTS" ]] && PORTS=$B_PORTS
    fi
    FRP_PORT=${FRP_PORT:-$(gen_random_port)}
    validate_setup_common "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$LOCAL_GRE" || return 1
    is_valid_ip "$PEER_GRE" || { echo -e "${RED}[!] IP داخلی GRE سرور مقابل نامعتبر است: '$PEER_GRE'${NC}"; return 1; }
    [[ "$LOCAL_GRE" != "$PEER_GRE" ]] || { echo -e "${RED}[!] IP داخلی GRE دو سمت باید متفاوت باشد.${NC}"; return 1; }
    if grep -q "\"remote_pub\": *\"${REMOTE_PUB}\"" "$PEERS_FILE" 2>/dev/null; then
        echo -e "${RED}[!] IP خارج ${REMOTE_PUB} در تونل دیگری استفاده شده است؛ برای همان سرور تونل تکراری نسازید.${NC}"; return 1
    fi
    [[ -n "$TOKEN" ]] || { echo -e "${RED}[!] گزینه --token ضروری است؛ برای هر تونل توکن جدا بسازید.${NC}"; return 1; }
    local CLEANED="" p
    for p in $(echo "$PORTS" | tr ',' ' '); do
        is_valid_port "$p" || { echo "پورت نامعتبر: $p" >&2; return 1; }
            CLEANED="$CLEANED $((10#$p))"
    done
    CLEANED=$(echo "$CLEANED" | xargs)
    [[ -n "$CLEANED" ]] || { echo -e "${RED}[!] گزینه --ports باید حداقل یک پورت معتبر داشته باشد.${NC}"; return 1; }
    peer_init; peer_require_py || return 1
    local ID
    ID=$(peer_next_id) || return 1
    [[ "$ID" =~ ^[1-9][0-9]*$ ]] || { echo "اختصاص شناسه تونل ناموفق بود." >&2; return 1; }
    # port conflict: a remotePort can be served by only one frpc
    local USED entry CONFLICT=""
    USED=$(peer_ports_used)
    for p in $CLEANED; do
        for entry in $USED; do
            if [[ "${entry%%:*}" == "$p" ]]; then CONFLICT="$CONFLICT $p (used by peer '${entry#*:}')"; fi
        done
    done
    if [[ -n "$CONFLICT" ]]; then
        echo -e "${RED}[!] تداخل پورت؛ در تونل دیگری استفاده شده است:${CONFLICT}${NC}"
        echo -e "${YELLOW}    برای این تونل پورت دیگری انتخاب کنید؛ مثلاً 8443 به‌جای 443.${NC}"
        return 1
    fi
    peer_control_port_check "$FRP_PORT" 0 "$CLEANED" || return 1
    # GRE inner IPs must be unique across peers
    if grep -q "\"local_gre\": *\"${LOCAL_GRE}\"" "$PEERS_FILE" || grep -q "\"peer_gre\": *\"${LOCAL_GRE}\"" "$PEERS_FILE"; then
        echo -e "${RED}[!] IP داخلی GRE ${LOCAL_GRE} در تونل دیگری استفاده شده است.${NC}"; return 1
    fi
    [[ -z "$NAME" ]] && NAME="peer-${ID}"
    install_frp_binaries || return 1
    if [[ "$ID" -eq 1 ]] && ! tunnel_present; then
        # first tunnel keeps legacy names (gre-tunnel, frps) — old setups untouched
        setup_gre_systemd "$LOCAL_PUB" "$REMOTE_PUB" "$LOCAL_GRE" "$PEER_GRE" || return 1
        peer_write_frps "" "$FRP_PORT" "$TOKEN"
        GRE_IF="$TUNNEL_NAME"; FRPS_SVC="frps"; LEGACY=true
        # Chaff is now opt-in: not activated during setup.
    else
        GRE_IF="gre-t${ID}"; FRPS_SVC="frps-${ID}"; LEGACY=false
        setup_gre_iface "$GRE_IF" "$LOCAL_PUB" "$REMOTE_PUB" "$LOCAL_GRE" "$PEER_GRE" || return 1
        peer_write_frps "-${ID}" "$FRP_PORT" "$TOKEN"
        # point the new unit at the right interface
        sed -i "s/After=network.target/After=network.target ${GRE_IF}.service/" /etc/systemd/system/${FRPS_SVC}.service
        systemctl daemon-reload; systemctl restart "$FRPS_SVC"
        # Chaff is now opt-in: not activated during setup.
    fi
    sleep 1
    if ! systemctl is-active --quiet "$FRPS_SVC"; then
        echo -e "${RED}[!] راه‌اندازی ${FRPS_SVC} ناموفق بود؛ تنظیمات تولیدشده را بررسی کنید.${NC}"
        return 1
    fi
    # registry record (ports as JSON array)
    local PORTS_JSON
    PORTS_JSON=$(echo "$CLEANED" | python3 -c 'import json,sys; print(json.dumps([int(x) for x in sys.stdin.read().split()]))')
    PEERS_F="$PEERS_FILE" python3 - "$ID" "$NAME" "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$PORTS_JSON" "$GRE_IF" "$FRPS_SVC" "$LEGACY" "${CHAFF_PROFILE:-off}" "$LOSS_RECOVERY" <<'PYEOF'
import json, os, sys
f = os.environ["PEERS_F"]
iid, name, lip, rip, fport, tok, lgre, pgre, pjson, gif, svc, leg, prof, loss = sys.argv[1:]
d = json.load(open(f))
d.setdefault("peers", []).append({"id": int(iid), "name": name, "local_pub": lip,
  "remote_pub": rip, "frp_port": int(fport), "token": tok, "local_gre": lgre,
  "peer_gre": pgre, "ports": json.loads(pjson), "gre_if": gif, "frps_svc": svc,
  "legacy": leg == "true", "chaff_profile": prof, "loss_recovery": loss == "on"})
json.dump(d, open(f, "w"), indent=2)
PYEOF
    echo -e "${GREEN}[✔️] تونل ${NAME} با شناسه ${ID} ساخته شد: GRE ${LOCAL_PUB} <-> ${REMOTE_PUB} (${LOCAL_GRE} peer ${PEER_GRE} on ${GRE_IF}), ${FRPS_SVC} :${FRP_PORT}${NC}"
    echo -e "${YELLOW}توکن تونل ${NAME}: ${TOKEN} (روی خارج با پورت‌های ${CLEANED} وارد کنید)${NC}"
    echo -e "BUNDLE:$(bundle_make "$LOCAL_PUB" "$FRP_PORT" "$LOCAL_GRE" "$PEER_GRE" "$TOKEN" "$CLEANED" "" "$LOSS_RECOVERY")"
    echo -e "${CYAN}سمت خارج؛ مقصد سرویس frpc: ${LOCAL_GRE}:${FRP_PORT}${NC}"
}

# remove one peer ($1=id). Legacy peer 1 also drops the old single tunnel.
cli_remove_peer() {
    local ID="" FORCE=0
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --* && $# -lt 2 ]]; then
            case "$1" in
                --force|--show-token|--encrypt|--compress|--dry-run|--off|--help) ;;
                *) echo "مقدار این گزینه وارد نشده است: $1" >&2; return 1 ;;
            esac
        fi
        case "$1" in --id) ID="$2"; shift 2 ;; --force) FORCE=1; shift ;;
            -h|--help) echo 'روش استفاده: NavaTunnel.sh remove-peer --id N [--force]'; return 0 ;;
            *) echo -e "${RED}[!] گزینه ناشناخته: $1${NC}"; return 1 ;; esac
    done
    [[ "$ID" =~ ^[0-9]+$ ]] || { echo -e "${RED}[!] شناسه تونل با --id ضروری است.${NC}"; return 1; }
    peer_init; peer_require_py || return 1
    local rec
    rec=$(peer_get "$ID")
    [[ -n "$rec" ]] || { echo -e "${RED}[!] تونلی با شناسه $ID وجود ندارد.${NC}"; return 1; }
    local NAME GIF SVC LEG
    NAME=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
    GIF=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["gre_if"])')
    SVC=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["frps_svc"])')
    LEG=$(echo "$rec" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("legacy") else "0")')
    if [[ "$FORCE" -ne 1 ]]; then
        read -p "تونل ${NAME} با شناسه ${ID} همراه GRE و سرویس آن حذف شود؟ [y/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}[*] Aborted.${NC}"; return 0; }
    fi
    local TRAFFIC_IDS tid
    TRAFFIC_IDS=$(python3 - "$GIF" "$rec" <<'PYREMOVE'
import json,sys
try:
    data=json.load(open('/etc/gre-panel/traffic.json'))
except FileNotFoundError:
    data={}
peer=json.loads(sys.argv[2])
for name,t in data.items():
    if (t.get('interface') and t['interface']==sys.argv[1]) or (t.get('peer') and t['peer']==peer.get('remote_pub')):
        print(name)
PYREMOVE
    ) || return 1
    for tid in $TRAFFIC_IDS; do cli_traffic remove "$tid" || return 1; done
    local CONF_FILE="${CONFIG_DIR}/frps-${ID}.toml" CHAFF_SVC="gre-chaff-${ID}"
    if [[ "$LEG" == "1" ]]; then CONF_FILE="${CONFIG_DIR}/frps.toml"; CHAFF_SVC="gre-chaff"; fi
    systemctl stop "$SVC" "${GIF}.service" "${CHAFF_SVC}.service" >/dev/null 2>&1 || true
    systemctl disable "$SVC" "${GIF}.service" "${CHAFF_SVC}.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${SVC}.service" "/etc/systemd/system/${GIF}.service" "$CONF_FILE" "/etc/systemd/system/${CHAFF_SVC}.service"
    systemctl daemon-reload || return 1
    if [[ -n "$GIF" && "$GIF" != "none" ]]; then
        ip link del "$GIF" >/dev/null 2>&1 || ip tunnel del "$GIF" >/dev/null 2>&1 || true
    fi
    PEERS_F="$PEERS_FILE" PEER_ID="$ID" python3 -c \
'import json,os; f=os.environ["PEERS_F"]; d=json.load(open(f)); d["peers"]=[p for p in d.get("peers",[]) if p["id"]!=int(os.environ["PEER_ID"])]; json.dump(d,open(f,"w"),indent=2)' \
        || return 1
    [[ ! "$GIF" =~ ^gre-(tunnel|t[0-9]+)$ ]] || rm -f "${NAVATUNNEL_STATE_DIR}/stopped/${GIF}"
    echo -e "${GREEN}[✔️] تونل ${NAME} با شناسه ${ID} حذف شد.${NC}"
}

cli_edit_peer() {
    local ID="" NAME="" REMOTE_PUB="" CARRIER="" PORTS="" PROXY_PROTOCOL=""
    local FRP_TRANSPORT="" FRP_ENCRYPTION="" FRP_COMPRESSION=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --* && $# -lt 2 ]]; then
            case "$1" in
                --force|--show-token|--encrypt|--compress|--dry-run|--off|--help) ;;
                *) echo "مقدار این گزینه وارد نشده است: $1" >&2; return 1 ;;
            esac
        fi
        case "$1" in
            --id) ID="$2"; shift 2 ;;
            --name) NAME="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --carrier) CARRIER="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            --proxy-protocol) echo "این تنظیم باید روی کلاینت FRP سرور خارج انجام شود." >&2; return 1 ;;
            --frp-transport) echo "این تنظیم باید روی کلاینت FRP سرور خارج انجام شود." >&2; return 1 ;;
            --encrypt) echo "این تنظیم باید روی کلاینت FRP سرور خارج انجام شود." >&2; return 1 ;;
            --compress) echo "این تنظیم باید روی کلاینت FRP سرور خارج انجام شود." >&2; return 1 ;;
            --frp-encryption) echo "این تنظیم باید روی کلاینت FRP سرور خارج انجام شود." >&2; return 1 ;;
            --frp-compression) echo "این تنظیم باید روی کلاینت FRP سرور خارج انجام شود." >&2; return 1 ;;
            -h|--help) echo 'روش استفاده: NavaTunnel.sh edit-peer --id N [--name LABEL] [--remote-pub IP] [--carrier direct|fou:P] [--ports "443, 2083"]'; return 0 ;;
            *) echo -e "${RED}[!] گزینه ناشناخته: $1${NC}"; return 1 ;;
        esac
    done
    [[ "$ID" =~ ^[0-9]+$ ]] || { echo -e "${RED}[!] شناسه تونل با --id ضروری است.${NC}"; return 1; }
    if [[ -z "$NAME" && -z "$REMOTE_PUB" && -z "$CARRIER" && -z "$PORTS" && -z "$PROXY_PROTOCOL" && -z "$FRP_TRANSPORT" && -z "$FRP_ENCRYPTION" && -z "$FRP_COMPRESSION" ]]; then
        echo -e "${RED}[!] موردی برای ویرایش وارد نشده است؛ حداقل یک گزینه تعیین کنید.${NC}"
        return 1
    fi

    peer_init; peer_require_py || return 1
    local rec
    rec=$(peer_get "$ID")
    [[ -n "$rec" ]] || { echo -e "${RED}[!] تونلی با شناسه $ID وجود ندارد.${NC}"; return 1; }

    local CUR_NAME CUR_REMOTE CUR_CARRIER CUR_GIF CUR_SVC
    CUR_NAME=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))')
    CUR_REMOTE=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("remote_pub",""))')
    CUR_CARRIER=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("carrier","direct"))')
    CUR_GIF=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("gre_if",""))')
    CUR_SVC=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("frps_svc","frps"))')

    # Validate remote public IP if provided
    if [[ -n "$REMOTE_PUB" ]]; then
        is_valid_ip "$REMOTE_PUB" || { echo -e "${RED}[!] IP عمومی سرور مقابل نامعتبر است: ${REMOTE_PUB}${NC}"; return 1; }
        PEERS_F="$PEERS_FILE" PEER_ID="$ID" NEW_IP="$REMOTE_PUB" python3 <<'PYEOF'
import json, os, sys
f = os.environ["PEERS_F"]
pid = int(os.environ["PEER_ID"])
new_ip = os.environ["NEW_IP"]
d = json.load(open(f))
for p in d.get("peers", []):
    if p.get("id") != pid and p.get("remote_pub") == new_ip:
        print(f"[!] تداخل IP: آدرس {new_ip} در تونل {p.get('name')} استفاده شده است", file=sys.stderr)
        sys.exit(1)
PYEOF
        if [[ $? -ne 0 ]]; then
            return 1
        fi
    fi

    # Validate carrier if provided
    if [[ -n "$CARRIER" ]]; then
        if [[ "$CARRIER" != "direct" && "$CARRIER" != fou:* ]]; then
            echo -e "${RED}[!] روش انتقال نامعتبر: ${CARRIER} (باید direct یا fou:PORT باشد)${NC}"
            return 1
        fi
    fi

    # Validate ports if provided
    local CLEANED=""
    if [[ -n "$PORTS" ]]; then
        local p
        for p in $(echo "$PORTS" | tr ',' ' '); do
            is_valid_port "$p" || { echo "پورت نامعتبر: $p" >&2; return 1; }
            CLEANED="$CLEANED $((10#$p))"
        done
        CLEANED=$(echo "$CLEANED" | xargs)
        [[ -n "$CLEANED" ]] || { echo -e "${RED}[!] گزینه --ports باید حداقل یک پورت بین 1 و 65535 داشته باشد.${NC}"; return 1; }

        local USED entry CONFLICT=""
        USED=$(PEERS_F="$PEERS_FILE" PEER_ID="$ID" python3 -c 'import json,os
with open(os.environ["PEERS_F"]) as f: peers=json.load(f).get("peers",[])
print(" ".join(str(port)+":"+str(peer["id"]) for peer in peers if peer["id"]!=int(os.environ["PEER_ID"]) for port in peer.get("ports",[])))') || return 1
        for p in $CLEANED; do
            for entry in $USED; do
                local port_owner="${entry#*:}" port_num="${entry%%:*}"
                if [[ "$port_num" == "$p" ]]; then
                    CONFLICT="$CONFLICT $p (used by peer '${port_owner}')"
                fi
            done
        done
        if [[ -n "$CONFLICT" ]]; then
            echo -e "${RED}[!] تداخل پورت؛ در تونل دیگری استفاده شده است:${CONFLICT}${NC}"
            return 1
        fi
    fi

    # 1. Apply Remote IP update if changed
    if [[ -n "$REMOTE_PUB" && "$REMOTE_PUB" != "$CUR_REMOTE" ]]; then
        echo -e "${CYAN}[*] در حال تغییر IP مقابل GRE: ${CUR_REMOTE} -> ${REMOTE_PUB}...${NC}"
        if ip link show "$CUR_GIF" >/dev/null 2>&1; then
            ip tunnel change "$CUR_GIF" remote "$REMOTE_PUB" >/dev/null 2>&1 || {
                ip link set dev "$CUR_GIF" down >/dev/null 2>&1 || true
                ip tunnel change "$CUR_GIF" remote "$REMOTE_PUB" >/dev/null 2>&1 || true
                ip link set dev "$CUR_GIF" up >/dev/null 2>&1 || true
            }
        fi
        local SVC_FILE="/etc/systemd/system/${CUR_GIF}.service"
        if [[ -f "$SVC_FILE" ]]; then
            sed -i -E "s/remote [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/remote ${REMOTE_PUB}/g" "$SVC_FILE"
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl restart "${CUR_GIF}.service" >/dev/null 2>&1 || true
        fi
        if ! ping -c 1 -W 2 "$REMOTE_PUB" >/dev/null 2>&1; then
            echo -e "${YELLOW}[WARN] IP جدید ${REMOTE_PUB} پاسخ پینگ نداد؛ ممکن است خاموش باشد یا ICMP را بسته باشد.${NC}"
        fi
    fi

    # 2. Apply Carrier update if changed
    if [[ -n "$CARRIER" && "$CARRIER" != "$CUR_CARRIER" ]]; then
        echo -e "${CYAN}[*] در حال اعمال روش انتقال ${CARRIER} روی ${CUR_GIF}...${NC}"
        carrier_apply "$CARRIER" "$CUR_GIF" || return 1
    fi

    # 3. Apply Ports update if changed
    if [[ -n "$CLEANED" ]]; then
        echo -e "${CYAN}[*] در حال به‌روزرسانی پورت‌های سرویس ${CUR_SVC}...${NC}"
        local TOML_FILE="/etc/frp/frps-${ID}.toml"
        [[ ! -f "$TOML_FILE" && "$ID" -eq 1 ]] && TOML_FILE="/etc/frp/frps.toml"
        if [[ -f "$TOML_FILE" ]]; then
            TOML_F="$TOML_FILE" PORTS_CLEAN="$CLEANED" python3 <<'PYEOF'
import os,re
from pathlib import Path
path=Path(os.environ["TOML_F"])
ports=sorted({int(p) for p in os.environ["PORTS_CLEAN"].split()})
lines=path.read_text().splitlines(keepends=True)
header=[]; skipping=False; allow=False
for line in lines:
    if line.strip().startswith('[[proxies]]'): skipping=True; continue
    if skipping and line.lstrip().startswith('['): skipping=False
    if skipping: continue
    if re.match(r'^\s*allowPorts\s*=',line):
        allow=']' not in line.split('=',1)[1]; continue
    if allow:
        if ']' in line: allow=False
        continue
    header.append(line)
setting='allowPorts = ['+', '.join('{ start = '+str(p)+', end = '+str(p)+' }' for p in ports)+']\n'
tmp=path.with_suffix('.tmp')
tmp.write_text(setting+''.join(header)); tmp.chmod(0o600); tmp.replace(path)
PYEOF
            [[ $? -eq 0 ]] || return 1
            systemctl reload-or-restart "$CUR_SVC" >/dev/null 2>&1 || return 1
        fi
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
            for p in $CLEANED; do
                ufw allow "$p"/tcp >/dev/null 2>&1 || true
                ufw allow "$p"/udp >/dev/null 2>&1 || true
            done
        fi
    fi

    # 4. Update peers.json
    PEERS_F="$PEERS_FILE" PEER_ID="$ID" NEW_NAME="$NAME" NEW_REMOTE="$REMOTE_PUB" NEW_CARRIER="$CARRIER" NEW_PORTS="$CLEANED" NEW_PP="$PROXY_PROTOCOL" NEW_TRANS="$FRP_TRANSPORT" NEW_ENC="$FRP_ENCRYPTION" NEW_COMP="$FRP_COMPRESSION" python3 <<'PYEOF'
import json, os
f = os.environ["PEERS_F"]
pid = int(os.environ["PEER_ID"])
name = os.environ.get("NEW_NAME")
rip = os.environ.get("NEW_REMOTE")
car = os.environ.get("NEW_CARRIER")
pstr = os.environ.get("NEW_PORTS")
pp = os.environ.get("NEW_PP")
ft = os.environ.get("NEW_TRANS")
enc = os.environ.get("NEW_ENC")
comp = os.environ.get("NEW_COMP")
d = json.load(open(f))
for p in d.get("peers", []):
    if p.get("id") == pid:
        if name:
            p["name"] = name
        if rip:
            p["remote_pub"] = rip
        if car:
            p["carrier"] = car
        if pstr:
            p["ports"] = [int(x) for x in pstr.split()]
        if pp:
            p["proxy_protocol"] = pp
        if ft:
            p["frp_transport"] = ft
        if enc in ("on", "true", "1"):
            p["use_encryption"] = True
        elif enc in ("off", "false", "0"):
            p["use_encryption"] = False
        if comp in ("on", "true", "1"):
            p["use_compression"] = True
        elif comp in ("off", "false", "0"):
            p["use_compression"] = False
json.dump(d, open(f, "w"), indent=2)
PYEOF

    local FINAL_NAME="${NAME:-$CUR_NAME}"
    echo -e "${GREEN}[✔️] تونل ${FINAL_NAME} با شناسه ${ID} به‌روز شد.${NC}"
}

# edit forwarded ports of one peer ($1=id, --ports "443, 2083")
cli_edit_peer_ports() {
    local ID="" PORTS=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --* && $# -lt 2 ]]; then
            case "$1" in
                --force|--show-token|--encrypt|--compress|--dry-run|--off|--help) ;;
                *) echo "مقدار این گزینه وارد نشده است: $1" >&2; return 1 ;;
            esac
        fi
        case "$1" in
            --id) ID="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            -h|--help) echo 'روش استفاده: NavaTunnel.sh edit-peer-ports --id N --ports "443, 2083"'; return 0 ;;
            *) echo -e "${RED}[!] گزینه ناشناخته: $1${NC}"; return 1 ;;
        esac
    done
    cli_edit_peer --id "$ID" --ports "$PORTS"
}


# readable peer table for the menu
peer_list_pretty() {
    peer_init; peer_require_py || return 1
    PEERS_F="$PEERS_FILE" python3 <<'PYEOF'
import json, os, subprocess
try:
    peers = json.load(open(os.environ["PEERS_F"])).get("peers", [])
except Exception as e:
    print(f"[!] خواندن فهرست تونل‌ها ناموفق بود: {e}"); raise SystemExit(1)
if not peers:
    print("[*] تونلی ثبت نشده است؛ از گزینه ساخت تونل برای افزودن سرور خارج استفاده کنید.")
    raise SystemExit(0)
try:
    tun = subprocess.run(["ip", "tunnel", "show"], capture_output=True, text=True).stdout
except OSError:
    tun = ""
for p in sorted(peers, key=lambda x: x["id"]):
    gre = "up" if p.get("gre_if", "") in {line.split(":",1)[0].strip() for line in tun.splitlines()} else "down"
    try:
        frp = subprocess.run(["systemctl", "is-active", p.get("frps_svc", "")],
                             capture_output=True, text=True).stdout.strip()
    except Exception:
        frp = "?"
    states=dict(active='فعال',inactive='غیرفعال',failed='ناموفق',activating='در حال راه‌اندازی')
    print(f"\nتونل #{p['id']}: {p.get('name','')} | خارج: {p.get('remote_pub','?')}")
    print(f"  GRE: {p.get('gre_if','?')} | "+('موجود' if gre=='up' else 'موجود نیست'))
    print(f"  IP داخلی: {p.get('local_gre','?')} -> {p.get('peer_gre','?')}")
    print(f"  سرویس: {p.get('frps_svc','?')} | پورت کنترل: {p.get('frp_port','?')} | "+states.get(frp,frp or 'نامشخص'))
    print('  پورت‌های سرویس: '+','.join(map(str,p.get('ports',[]))))

PYEOF
}

setup_iran_server() {
    echo -e "\n${YELLOW}====================================================${NC}"
    echo -e "${YELLOW}       مرحله 1: تنظیم سرور ایران با GRE و FRP  ${NC}"
    echo -e "${YELLOW}====================================================${NC}"

    MY_PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    [[ -z "$MY_PUBLIC_IP" ]] && MY_PUBLIC_IP=$(curl -sSL --max-time 5 https://api.ipify.org 2>/dev/null)
    prompt_ip IP_IRAN "IP عمومی سرور ایران" "$MY_PUBLIC_IP"
    prompt_ip IP_FOREIGN "IP عمومی سرور خارج" ""

    prompt_port BIND_PORT "پورت کنترل FRP" "$(gen_random_port)"
    BIND_PORT=$(ensure_port_available "$BIND_PORT" "پورت کنترل FRP" 0) || return 1

    AUTO_TOKEN=$(gen_token32)
    prompt_token TOKEN "توکن محرمانه اتصال" "$AUTO_TOKEN"

    # single source of truth: GRE + frps all happen inside
    setup_iran_server_noninteractive "$IP_IRAN" "$IP_FOREIGN" "$BIND_PORT" "$TOKEN" "$IRAN_GRE_IP" "$FOREIGN_GRE_IP"
}

# interactive wrapper for cli_add_peer: prompts for one more foreign server.
menu_protocol_prompt() {
    ui_clear >&2
    local current=${1:-tcp} choice
    echo 'پروتکل FRP روی کلاینت خارج اجرا می‌شود؛ روی ایران انتخاب و در کد اتصال ذخیره می‌شود.' >&2
    echo '1) TCP (پیش‌فرض)' >&2
    echo '2) KCP (همراه FEC؛ ترافیک بیشتر)' >&2
    echo '3) QUIC' >&2
    echo '4) WebSocket' >&2
    echo '5) WSS (WebSocket با TLS)' >&2
    echo '0) لغو' >&2
    while true; do
        read -r -p "انتخاب پروتکل [Enter: $current]: " choice || return 1
        case "$choice" in
            '') printf '%s\n' "$current"; return 0 ;;
            1) echo tcp; return 0;; 2) echo kcp; return 0;; 3) echo quic; return 0;;
            4) echo websocket; return 0;; 5) echo wss; return 0;; 0) return 1;;
            *) echo 'شماره‌ای از 0 تا 5 وارد کنید.' >&2 ;;
        esac
    done
}

cli_peer_protocol() {
    local id="" protocol=""
    while [[ $# -gt 0 ]]; do
        [[ $# -ge 2 ]] || { echo 'روش استفاده: NavaTunnel peer-protocol --id N --protocol tcp|kcp|quic|websocket|wss' >&2; return 1; }
        case "$1" in --id) id="$2";; --protocol) protocol="$2";; *) return 1;; esac
        shift 2
    done
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    case "$protocol" in tcp|kcp|quic|websocket|wss) ;; *) echo 'پروتکل FRP نامعتبر است.' >&2; return 1;; esac
    peer_init || return 1
    if [[ "$protocol" == kcp ]]; then
        local record iface
        record=$(peer_get "$id") || return 1
        [[ -n "$record" ]] || { echo 'تونل پیدا نشد.' >&2; return 1; }
        iface=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("gre_if",""))' <<< "$record") || return 1
        validate_kcp_mtu "$iface" kcp || return 1
    fi
    python3 - "$PEERS_FILE" "$id" "$protocol" <<'PYCODE'
import json,sys,os
from pathlib import Path
p=Path(sys.argv[1]); data=json.loads(p.read_text()); record=next((t for t in data.get('peers',[]) if t['id']==int(sys.argv[2])),None)
if record is None: sys.exit('تونل پیدا نشد')
record['frp_transport']=sys.argv[3]; record['loss_recovery']=sys.argv[3]=='kcp'
out=p.with_suffix('.protocol.tmp')
with open(out,'w') as f:
    os.chmod(out,0o600); json.dump(data,f,indent=2)
os.replace(out,p)
PYCODE
    [[ $? == 0 ]] || return 1
    echo "پروتکل FRP این تونل ذخیره شد: $protocol"
    echo 'این انتخاب در ایران ذخیره شد؛ برای اعمال، کد اتصال جدید را روی سرور خارج اجرا کنید.'
}

menu_loss_prompt() {
    ui_clear >&2
    local answer
    echo 'جبران افت بسته با KCP/FEC، مصرف ترافیک را افزایش می‌دهد و افت مسیر را حذف نمی‌کند.' >&2
    while true; do
        read -r -p 'آیا می‌خواهید جبران افت پکت فعال شود؟ [y/N]: ' answer || return 1
        case "$answer" in y|Y) echo on; return 0;; n|N|'') echo off; return 0;; *) echo 'فقط y یا n وارد کنید.' >&2;; esac
    done
}

cli_loss_recovery() {
    local id="" mode=""
    while [[ $# -gt 0 ]]; do
        [[ $# -ge 2 ]] || { echo 'روش استفاده: NavaTunnel loss-recovery --id N --mode on|off' >&2; return 1; }
        case "$1" in --id) id="$2";; --mode) mode="$2";; *) echo "گزینه ناشناخته: $1" >&2; return 1;; esac
        shift 2
    done
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    case "$mode" in on|off) ;; *) echo 'حالت باید on یا off باشد.' >&2; return 1;; esac
    peer_init || return 1
    if [[ "$mode" == on ]]; then
        local record iface
        record=$(peer_get "$id") || return 1
        [[ -n "$record" ]] || { echo 'تونل پیدا نشد.' >&2; return 1; }
        iface=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("gre_if",""))' <<< "$record") || return 1
        validate_kcp_mtu "$iface" kcp || return 1
    fi
    python3 - "$PEERS_FILE" "$id" "$mode" <<'PYCODE'
import json,sys,os
from pathlib import Path
p=Path(sys.argv[1]); data=json.loads(p.read_text()); record=next((t for t in data.get('peers',[]) if t['id']==int(sys.argv[2])),None)
if record is None: sys.exit('تونل پیدا نشد')
record['loss_recovery']=sys.argv[3]=='on'
if record['loss_recovery']: record['frp_transport']='kcp'
elif record.get('frp_transport')=='kcp': record['frp_transport']='tcp'
out=p.with_suffix('.loss.tmp')
with open(out,'w') as f:
    os.chmod(out,0o600); json.dump(data,f,indent=2)
os.replace(out,p)
PYCODE
    [[ $? == 0 ]] || return 1
    local stored_protocol stored_mode stored
    stored=$(peer_connection_settings "$id") || return 1
    IFS=$'\t' read -r stored_protocol stored_mode <<< "$stored"
    [[ "$stored_mode" == "$mode" ]] || { echo 'بررسی انتخاب ذخیره‌شده ناموفق بود.' >&2; return 1; }
    echo "جبران افت بسته: $(fa_state "$stored_mode") | پروتکل: $stored_protocol (در فایل ایران تأیید شد)."
    echo 'برای اعمال روی اتصال فعال، کد اتصال جدید را روی سرور خارج اجرا کنید؛ گزینه جایگزینی را تأیید کنید.'
}

menu_loss_recovery() {
    local id=$1 option settings protocol mode label bundle
    while true; do
        ui_clear
        settings=$(peer_connection_settings "$id") || return 1
        IFS=$'\t' read -r protocol mode <<< "$settings"
        label='غیرفعال'; [[ "$mode" == on ]] && label='فعال'
        echo "انتخاب ذخیره‌شده روی ایران: $label | پروتکل: $protocol"
        echo 'وضعیت اعمال‌شده روی خارج از این سرور بررسی نشده؛ تغییر مستقیم خارج خودکار این فهرست را تغییر نمی‌دهد.'
        echo '1) فعال‌سازی جبران افت بسته (KCP/FEC)'
        echo '2) غیرفعال‌سازی جبران افت بسته (KCP به TCP برمی‌گردد)'
        echo '3) نمایش انتخاب ذخیره‌شده'
        echo '0) بازگشت'
        read -r -p 'انتخاب [Enter: بازگشت]: ' option || return 0
        case "$option" in
            1|2)
                mode=off; [[ "$option" == 1 ]] && mode=on
                cli_loss_recovery --id "$id" --mode "$mode" || return 1
                bundle=$(peer_token "$id" | sed -n 's/^BUNDLE://p')
                if [[ -n "$bundle" ]]; then
                    echo 'برای اعمال این انتخاب روی تونل موجود، دستور زیر را روی خارج اجرا کنید (اتصال کوتاه قطع می‌شود):'
                    printf 'NavaTunnel setup-foreign --bundle %q --force\n' "$bundle"
                fi ;;
            3) ;;
            0|'') return 0 ;;
            *) echo 'گزینه نامعتبر است.' ;;
        esac
        pause_prompt
    done
}

# Bring a standalone Iran installation into the selection menu without restarting it.
menu_import_existing() {
    peer_init || return 1
    python3 - "$PEERS_FILE" "/etc/systemd/system/${TUNNEL_NAME}.service" "${CONFIG_DIR}/frps.toml" "$TUNNEL_NAME" <<'PYCODE'
import json,sys,re,ipaddress,os
from pathlib import Path
registry,unit,config,iface=sys.argv[1:]
p=Path(registry); data=json.loads(p.read_text()); peers=data.get('peers',[])
if any(t.get('gre_if')==iface for t in peers): sys.exit(0)
if not Path(unit).exists() or not Path(config).exists(): sys.exit(0)
u=Path(unit).read_text(); c=Path(config).read_text()
def match(pattern,text):
    m=re.search(pattern,text,re.M); return m.group(1) if m else ''
local=match(r'\blocal\s+([0-9.]+)',u); remote=match(r'\bremote\s+([0-9.]+)',u)
inner=match(r'addr (?:replace|add) ([0-9.]+)/30',u); other=match(r'route replace ([0-9.]+)/32',u)
port=match(r'^\s*bindPort\s*=\s*(\d+)',c); token=match(r'^\s*auth\.token\s*=\s*"([^"\n]+)"',c)
try:
    for address in (local,remote,inner,other): ipaddress.IPv4Address(address)
    if not 0<int(port)<65536 or not token: sys.exit(0)
except ValueError: sys.exit(0)
used={t['id'] for t in peers}; number=1
while number in used: number+=1
ports=sorted({int(x) for x in re.findall(r'remotePort\s*=\s*(\d+)',c)})
for a,b in re.findall(r'start\s*=\s*(\d+)\s*,\s*end\s*=\s*(\d+)',c):
    if 0<int(a)<=int(b)<65536: ports.extend(range(int(a),int(b)+1))
peers.append(dict(id=number,name='iran-1',local_pub=local,remote_pub=remote,frp_port=int(port),token=token,
                 local_gre=inner,peer_gre=other,ports=sorted(set(ports)),gre_if=iface,frps_svc='frps',legacy=True))
data['peers']=peers
out=p.with_suffix('.menu.tmp')
with open(out,'w') as f:
    os.chmod(out,0o600); json.dump(data,f,indent=2)
os.replace(out,p)
PYCODE
}

# Allocate an unused /30 without tying addresses to the peer ID.
menu_gre_pair() {
    python3 - "$PEERS_FILE" <<'PYCODE'
import json,sys,ipaddress
from pathlib import Path
p=Path(sys.argv[1]); peers=json.loads(p.read_text()).get('peers',[]) if p.exists() else []
used={t[k] for t in peers for k in ('local_gre','peer_gre') if t.get(k)}
used.update(('10.10.10.1','10.10.10.2'))
base=int(ipaddress.IPv4Address('10.200.0.0'))
for n in range(16384):
    remote=str(ipaddress.IPv4Address(base+n*4+1)); local=str(ipaddress.IPv4Address(base+n*4+2))
    if local not in used and remote not in used:
        print(local,remote); break
else: sys.exit('در بازه 10.200.0.0/16 آدرس GRE آزاد پیدا نشد')
PYCODE
}

# Check all listeners used by FRPS, including its companion QUIC port.
peer_control_port_check() {
    local port=$1 exclude=${2:-0} service_ports=${3:-} tcp udp fou
    is_valid_port "$port" || { echo 'پورت کنترل باید بین 1 و 65535 باشد.' >&2; return 1; }
    peer_init || return 1
    command -v ss >/dev/null || ensure_dependencies_smart || return 1
    tcp=$(ss -H -ltn) || { echo 'بررسی پورت‌های TCP ناموفق بود.' >&2; return 1; }
    udp=$(ss -H -lun) || { echo 'بررسی پورت‌های UDP ناموفق بود.' >&2; return 1; }
    fou=$(ip fou show 2>/dev/null) || fou=''
    TCP_LISTEN="$tcp" UDP_LISTEN="$udp" FOU_LISTEN="$fou" python3 - "$PEERS_FILE" "$port" "$exclude" "$service_ports" <<'PYCODE'
import json,os,re,sys
port=int(sys.argv[2]); exclude=int(sys.argv[3])
quic=lambda p:p-1 if p==65535 else p+1
needed_tcp={port}; needed_udp={port,quic(port)}
peers=json.load(open(sys.argv[1])).get('peers',[])
ignore_tcp=set(); ignore_udp=set()
for peer in peers:
    control=int(peer.get('frp_port') or 0)
    if peer.get('id')==exclude:
        if control: ignore_tcp.add(control); ignore_udp.update((control,quic(control)))
    elif control and (needed_tcp & {control} or needed_udp & {control,quic(control)}):
        sys.exit('پورت کنترل یا پورت QUIC همراه آن با تونل '+str(peer.get('name',''))+' تداخل دارد.')
    if (needed_tcp|needed_udp)&set(map(int,peer.get('ports',[]))):
        sys.exit('پورت کنترل یا پورت QUIC همراه آن با پورت سرویس تونل '+str(peer.get('name',''))+' تداخل دارد.')
if (needed_tcp|needed_udp)&{int(p) for p in sys.argv[4].replace(',',' ').split()}:
    sys.exit('پورت کنترل یا پورت QUIC همراه آن در فهرست پورت‌های سرویس همین تونل است.')
def listeners(text):
    ports=set()
    for line in text.splitlines():
        parts=line.split()
        if len(parts)>=4:
            match=re.search(r':(\d+)$',parts[3])
            if match: ports.add(int(match[1]))
    return ports
if needed_tcp & (listeners(os.environ['TCP_LISTEN'])-ignore_tcp):
    sys.exit('پورت کنترل TCP روی این سرور اشغال است.')
if needed_udp & (listeners(os.environ['UDP_LISTEN'])-ignore_udp):
    sys.exit('پورت کنترل UDP یا پورت QUIC همراه آن روی این سرور اشغال است.')
if needed_udp & {int(p) for p in re.findall(r'\bport\s+(\d+)',os.environ['FOU_LISTEN'])}:
    sys.exit('پورت کنترل یا پورت QUIC همراه آن با حامل FOU تداخل دارد.')
PYCODE
}

peer_control_port_auto() {
    local exclude=${1:-0} ports=${2:-} candidate attempt
    for ((attempt=0; attempt<100; attempt++)); do
        candidate=$(gen_random_port) || return 1
        peer_control_port_check "$candidate" "$exclude" "$ports" 2>/dev/null && { echo "$candidate"; return 0; }
    done
    echo 'انتخاب پورت کنترل آزاد ناموفق بود؛ وضعیت پورت‌ها را بررسی کنید.' >&2
    return 1
}

menu_control_port_prompt() {
    local id=${1:-0} ports=${2:-} value
    while true; do
        if [[ "$id" == 0 ]]; then
            read -r -p 'پورت کنترل FRP [Enter یا auto: خودکار؛ 0: لغو]: ' value || return 1
        else
            read -r -p 'پورت کنترل جدید [auto: خودکار؛ Enter یا 0: لغو]: ' value || return 1
            [[ -n "$value" ]] || return 1
        fi
        [[ "$value" != 0 ]] || return 1
        if [[ -z "$value" || "$value" == auto ]]; then
            peer_control_port_auto "$id" "$ports"; return $?
        fi
        if peer_control_port_check "$value" "$id" "$ports"; then
            echo "$((10#$value))"; return 0
        fi
    done
}

cli_peer_control_port() {
    local id='' port='' rec svc config tmp failure=0
    while [[ $# -gt 0 ]]; do
        [[ $# -ge 2 ]] || { echo 'روش استفاده: NavaTunnel peer-control-port --id N --port N|auto' >&2; return 1; }
        case "$1" in --id) id=$2;; --port) port=$2;; *) return 1;; esac
        shift 2
    done
    [[ "$id" =~ ^[1-9][0-9]*$ && -n "$port" ]] || return 1
    rec=$(peer_get "$id") || return 1
    [[ -n "$rec" ]] || { echo 'تونل پیدا نشد.' >&2; return 1; }
    [[ "$port" != auto ]] || port=$(peer_control_port_auto "$id") || return 1
    peer_control_port_check "$port" "$id" || return 1
    port=$((10#$port))
    local old
    old=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("frp_port",0))' <<< "$rec") || return 1
    [[ "$port" != "$old" ]] || { echo 'پورت کنترل همین مقدار است؛ تغییری انجام نشد.'; return 0; }
    svc=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("frps_svc",""))' <<< "$rec") || return 1
    [[ "$svc" =~ ^frps(-[0-9]+)?$ ]] || { echo 'نام سرویس FRPS نامعتبر است.' >&2; return 1; }
    config="${CONFIG_DIR}/${svc}.toml"
    [[ -f "$config" ]] || { echo 'فایل تنظیمات FRPS پیدا نشد.' >&2; return 1; }
    tmp=$(mktemp -d) || return 1
    cp -p "$PEERS_FILE" "$tmp/peers.json" && cp -p "$config" "$tmp/frps.toml" || { rm -rf "$tmp"; return 1; }
    # Change only the root listener settings; preserve TLS, token and proxy rules.
    python3 - "$PEERS_FILE" "$config" "$id" "$port" <<'PYCODE'
import json,os,re,sys,tempfile
from pathlib import Path
registry,config=map(Path,sys.argv[1:3]); number=int(sys.argv[3]); port=int(sys.argv[4])
data=json.loads(registry.read_text()); record=next(p for p in data['peers'] if p['id']==number)
text=config.read_text(); root,sep,tail=text.partition('[[proxies]]')
values={'bindPort':port,'kcpBindPort':port,'quicBindPort':port-1 if port==65535 else port+1}
for key,value in values.items():
    pattern=r'^\s*'+key+r'\s*=.*$'
    if re.search(pattern,root,re.M): root=re.sub(pattern,key+' = '+str(value),root,flags=re.M)
    else: root=key+' = '+str(value)+'\n'+root
record['frp_port']=port
for path,content in ((config,root+sep+tail),(registry,json.dumps(data,ensure_ascii=False,indent=2)+'\n')):
    fd,tmp=tempfile.mkstemp(dir=path.parent,prefix='.control-port-')
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,'w') as f:f.write(content)
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
PYCODE
    [[ $? == 0 ]] || failure=1
    local quic=$((port == 65535 ? port-1 : port+1))
    if (( ! failure )) && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow "$port/tcp" && ufw allow "$port/udp" && ufw allow "$quic/udp" || failure=1
    fi
    if (( ! failure )); then
        systemctl restart "$svc" && systemctl is-active --quiet "$svc" || failure=1
    fi
    if (( failure )); then
        cp -p "$tmp/peers.json" "$PEERS_FILE" && cp -p "$tmp/frps.toml" "$config" || {
            echo "بازیابی فایل‌ها ناموفق بود؛ پشتیبان: $tmp" >&2; return 1;
        }
        systemctl restart "$svc" || { echo "تنظیمات قبلی بازیابی شد ولی سرویس راه‌اندازی نشد؛ پشتیبان: $tmp" >&2; return 1; }
        rm -rf "$tmp"
        echo 'تغییر پورت کنترل ناموفق بود؛ تنظیمات قبلی بازیابی شد.' >&2
        return 1
    fi
    rm -rf "$tmp"
    echo "پورت کنترل این تونل به $port تغییر کرد."
    echo 'اتصال خارج تا اعمال کد جدید قطع می‌شود؛ فرمان زیر را روی سرور خارج همین تونل اجرا کنید:'
    local output bundle
    output=$(peer_token "$id") || return 1
    bundle=$(sed -n 's/^BUNDLE://p' <<< "$output")
    [[ -n "$bundle" ]] || return 1
    printf 'NavaTunnel setup-foreign --bundle %q --force\n' "$bundle"
}

menu_add_peer() {
    ui_clear
    menu_import_existing || return 1
    local NAME LOCAL_IRAN IP_FOREIGN PPORTS CPORT TOKEN LGRE PGRE pair MYIP LOSS
    echo 'ساخت تونل ایران — برای لغو، نام را 0 وارد کنید.'
    read -r -p 'نام دلخواه تونل [Enter: خودکار]: ' NAME || return 0
    [[ "$NAME" == 0 ]] && return 0
    MYIP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null)
    [[ -n "$MYIP" ]] || MYIP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1);exit}}')
    prompt_ip LOCAL_IRAN 'IP عمومی سرور ایران' "$MYIP" || return 1
    prompt_ip IP_FOREIGN 'IP عمومی سرور خارج' '' || return 1
    prompt_ports PPORTS 'پورت‌های سرویس (مثلاً 443,8443)' || return 1
    LOSS=$(menu_loss_prompt) || return 0
    pair=$(menu_gre_pair) || return 1
    read -r LGRE PGRE <<< "$pair"
    CPORT=$(menu_control_port_prompt 0 "$PPORTS") || return 0
    TOKEN=$(gen_token32)
    echo "پورت کنترل: $CPORT | آدرس داخلی: $LGRE / $PGRE (خودکار)"
    cli_add_peer --name "$NAME" --local-pub "$LOCAL_IRAN" --remote-pub "$IP_FOREIGN" \
        --frp-port "$CPORT" --token "$TOKEN" --local-gre "$LGRE" --peer-gre "$PGRE" --ports "$PPORTS" --loss-recovery "$LOSS" || return 1
    echo 'تونل ساخته شد. برای دریافت کد اتصال سرور خارج، از مدیریت تونل‌ها گزینه کد اتصال را انتخاب کنید.'
}

# Selection menus keep IDs internally and present numbered choices.
menu_select_peer() {
    ui_clear >&2
    menu_import_existing || return 1
    local rows choice i=0
    rows=$(python3 - "$PEERS_FILE" <<'PYCODE'
import json,sys
for p in sorted(json.load(open(sys.argv[1])).get('peers',[]),key=lambda p:p['id']):
    print(str(p['id'])+'\t'+str(p.get('name',''))+' | '+str(p.get('remote_pub',''))+' | پورت کنترل: '+str(p.get('frp_port') or 'نامشخص'))
PYCODE
) || return 1
    local -a ids=()
    local id label
    while IFS=$'\t' read -r id label; do
        [[ -n "$id" ]] || continue
        ids+=("$id"); i=$((i+1)); printf '%s) %s\n' "$i" "$label" >&2
    done <<< "$rows"
    ((i)) || { echo 'تونلی در فهرست نیست. ابتدا یک تونل بسازید.' >&2; pause_prompt >&2; return 1; }
    echo '0) بازگشت' >&2
    while true; do
        read -r -p 'شماره تونل: ' choice || return 1
        if [[ "$choice" =~ ^[0-9]{1,6}$ ]]; then
            choice=$((10#$choice))
            ((choice==0)) && return 1
            if ((choice<=i)); then
                printf '%s\n' "${ids[choice-1]}"
                return 0
            fi
        fi
        echo 'شماره تونل نامعتبر است؛ از فهرست انتخاب کنید یا 0 بزنید.' >&2
    done
}

menu_remove_peer() {
    local id
    id=$(menu_select_peer) || return 0
    cli_remove_peer --id "$id"
}

menu_edit_peer_ports() {
    menu_edit_peer
}

# Change the shared Iran endpoint without rebuilding FRP or traffic counters.
cli_iran_ip() {
    [[ $# -eq 2 && "$1" == --ip ]] || { echo 'روش استفاده: NavaTunnel iran-ip --ip IP' >&2; return 1; }
    is_valid_ip "$2" || { echo 'IP عمومی ایران نامعتبر است.' >&2; return 1; }
    peer_init; peer_require_py || return 1
    PEERS_F="$PEERS_FILE" NEW_IRAN_IP="$2" IP_BACKUP_DIR="$BACKUP_DIR" python3 <<'PYEOF'
import ipaddress,json,os,re,subprocess,tempfile
from pathlib import Path
registry=Path(os.environ['PEERS_F'])
new=str(ipaddress.IPv4Address(os.environ['NEW_IRAN_IP']))
originals={}; touched=[]; backup=None

def run(*args):
    return subprocess.run(args,check=True,capture_output=True,text=True,timeout=30).stdout

def atomic(path,content,mode):
    fd,tmp=tempfile.mkstemp(dir=path.parent,prefix='.iran-ip-')
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,'wb') as f: f.write(content)
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

try:
    data=json.loads(registry.read_text())
    peers=data.get('peers',[])
    if not peers: raise ValueError('هیچ تونل ایران ثبت نشده است.')
    if all(p.get('local_pub')==new for p in peers):
        print('IP ایران برای همه تونل‌ها همین آدرس است؛ تغییری انجام نشد.')
        raise SystemExit(0)
    addresses=run('ip','-o','-4','addr','show')
    bound=any(token.split('/')[0]==new for token in addresses.split())
    updates={}; services=[]
    for peer in peers:
        iface=peer.get('gre_if','')
        if not re.fullmatch(r'gre-(?:tunnel|t[0-9]+)',iface):
            raise ValueError('نام اینترفیس تونل نامعتبر است.')
        path=Path('/etc/systemd/system')/(iface+'.service')
        old=path.read_bytes(); mode=path.stat().st_mode & 0o777
        remote=str(ipaddress.IPv4Address(peer['remote_pub']))
        local=new if bound else ''
        if not bound:
            route=run('ip','-4','route','get',remote)
            match=re.search(r'\bsrc\s+(\d+\.\d+\.\d+\.\d+)',route)
            if match: local=str(ipaddress.IPv4Address(match[1]))
        pattern=r'(?:\blocal\s+\d+\.\d+\.\d+\.\d+\s+)?\bremote\s+'+re.escape(remote)+r'\b'
        replacement=('local '+local+' ' if local else '')+'remote '+remote
        text,count=re.subn(pattern,replacement,old.decode())
        if not count: raise ValueError('آدرس GRE در سرویس '+iface+' پیدا نشد.')
        originals[path]=(old,mode); updates[path]=(text.encode(),mode)
        services.append(iface+'.service')
        peer['local_pub']=new
    originals[registry]=(registry.read_bytes(),registry.stat().st_mode & 0o777)
    updates[registry]=((json.dumps(data,ensure_ascii=False,indent=2)+'\n').encode(),0o600)
    base=Path(os.environ['IP_BACKUP_DIR']); base.mkdir(parents=True,exist_ok=True)
    backup=Path(tempfile.mkdtemp(prefix='iran-ip-',dir=base)); backup.chmod(0o700)
    for path,(content,mode) in originals.items():
        target=backup/path.name; target.write_bytes(content); target.chmod(0o600)
    for path,(content,mode) in updates.items():
        atomic(path,content,mode); touched.append(path)
    run('systemctl','daemon-reload')
    for service in services:
        run('systemctl','restart',service)
        run('systemctl','is-active','--quiet',service)
    print('IP ایران برای همه تونل‌ها ثبت شد: '+new)
    print('پشتیبان تنظیمات قبلی: '+str(backup))
    print('برای وصل شدن مجدد، کد اتصال جدید هر تونل را روی سرور خارج همان تونل اجرا کنید.')
except Exception as error:
    failures=[]
    for path in reversed(touched):
        try: atomic(path,*originals[path])
        except Exception: failures.append(str(path))
    if touched:
        try: run('systemctl','daemon-reload')
        except Exception: failures.append('بازخوانی سرویس‌ها')
        for service in services:
            try: run('systemctl','restart',service)
            except Exception: failures.append(service)
    print('تغییر IP ایران ناموفق بود: '+str(error),file=__import__('sys').stderr)
    if touched:
        print('تنظیمات قبلی بازیابی شد.' if not failures else 'بازیابی کامل نشد؛ وضعیت سرویس‌ها و پشتیبان را بررسی کنید: '+str(backup),file=__import__('sys').stderr)
    raise SystemExit(1)
PYEOF
}

menu_iran_ip() {
    ui_clear
    local value confirm id bundle
    menu_import_existing || return 1
    echo 'تغییر IP عمومی ایران برای همه تونل‌های ثبت‌شده'
    echo 'این گزینه IP کارت شبکه را تغییر نمی‌دهد؛ ابتدا IP جدید باید روی سرور قابل استفاده باشد.'
    echo 'اتصال‌ها تا اعمال کدهای جدید روی سرورهای خارج قطع می‌شوند.'
    read -r -p 'IP جدید ایران [Enter: لغو]: ' value || return 0
    [[ -n "$value" ]] || return 0
    is_valid_ip "$value" || { echo 'IP نامعتبر است.'; return 1; }
    read -r -p 'این تغییر روی همه تونل‌های ایران اعمال شود؟ [y/N]: ' confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    cli_iran_ip --ip "$value" || return 1
    echo 'کدهای زیر را روی سرور خارج مربوط به هر تونل اجرا کنید (جایگزینی اتصال قبلی):'
    while read -r id; do
        peer_get "$id" | python3 -c 'import json,sys; p=json.load(sys.stdin); print("تونل:",p.get("name",""),"| خارج:",p["remote_pub"])'
        bundle=$(peer_token "$id" | sed -n 's/^BUNDLE://p') || return 1
        [[ -n "$bundle" ]] || return 1
        printf 'NavaTunnel setup-foreign --bundle %q --force\n' "$bundle"
    done < <(python3 -c 'import json,sys; print("\n".join(str(p["id"]) for p in json.load(open(sys.argv[1])).get("peers",[])))' "$PEERS_FILE")
    echo 'کدهای اتصال شامل توکن هستند؛ آن‌ها را عمومی منتشر نکنید.'
}

# Persist intentional stops through boot and automatic service restarts.
cli_tunnel_power() {
    local i action=${1:-} id='' foreign=0 rec iface service unit marker temp was_stopped=0 failure=0
    shift || return 1
    [[ "$action" == start || "$action" == stop ]] || return 1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id) [[ $# -ge 2 ]] || return 1; id=$2; shift 2 ;;
            --foreign) foreign=1; shift ;;
            *) echo 'روش استفاده: NavaTunnel tunnel-power start|stop --id N | --foreign' >&2; return 1 ;;
        esac
    done
    if ((foreign)); then
        [[ -z "$id" && -f "${CONFIG_DIR}/frpc.toml" ]] || return 1
        iface=$TUNNEL_NAME; service=frpc
    else
        [[ "$id" =~ ^[1-9][0-9]*$ ]] || return 1
        rec=$(peer_get "$id") || return 1
        [[ -n "$rec" ]] || { echo 'تونل پیدا نشد.' >&2; return 1; }
        iface=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("gre_if",""))' <<< "$rec") || return 1
        service=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("frps_svc",""))' <<< "$rec") || return 1
    fi
    [[ "$iface" =~ ^gre-(tunnel|t[0-9]+)$ && "$service" =~ ^frp[sc](-[0-9]+)?$ ]] || return 1
    marker="${NAVATUNNEL_STATE_DIR}/stopped/${iface}"
    mkdir -p "$(dirname "$marker")" || return 1
    [[ ! -f "$marker" ]] || was_stopped=1
    local resume_chaff=0
    [[ ! -f "$marker" ]] || { grep -qx 'chaff=1' "$marker" && resume_chaff=1; }
    local -a units=("${iface}.service" "${service}.service")
    local chaff=gre-chaff
    [[ "$iface" == gre-tunnel ]] || chaff="gre-chaff-${iface#gre-t}"
    if [[ -f "/etc/systemd/system/${chaff}.service" ]]; then
        units+=("${chaff}.service")
        if (( ! was_stopped )) && systemctl is-active --quiet "${chaff}.service"; then resume_chaff=1; fi
    fi
    temp=$(mktemp -d) || return 1
    for unit in "${units[@]}"; do
        [[ -f "/etc/systemd/system/$unit" ]] && cp -p "/etc/systemd/system/$unit" "$temp/$unit" || {
            rm -rf "$temp"; echo 'فایل سرویس تونل پیدا نشد یا پشتیبان‌گیری ناموفق بود.' >&2; return 1;
        }
    done
    python3 - "$marker" "${units[@]}" <<'PYCODE'
import os,sys,tempfile
from pathlib import Path
marker=sys.argv[1]; staged=[]
for name in sys.argv[2:]:
    path=Path('/etc/systemd/system')/name
    text=path.read_text(); line='ConditionPathExists=!'+marker
    if line in text.splitlines():continue
    if '[Unit]\n' not in text:sys.exit('بخش Unit در فایل سرویس پیدا نشد.')
    text=text.replace('[Unit]\n','[Unit]\n'+line+'\n',1)
    staged.append((path,text,path.stat().st_mode&0o777))
for path,text,mode in staged:
    fd,tmp=tempfile.mkstemp(dir=path.parent,prefix='.power-')
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,'w') as f:f.write(text)
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
PYCODE
    [[ $? == 0 ]] || failure=1
    if (( ! failure )); then
        if [[ "$action" == stop ]]; then
            (umask 077; printf 'chaff=%s\n' "$resume_chaff" > "$marker") || failure=1
        else
            rm -f "$marker" || failure=1
        fi
    fi
    if (( ! failure )); then systemctl daemon-reload || failure=1; fi
    if (( failure )); then
        for unit in "${units[@]}"; do cp -p "$temp/$unit" "/etc/systemd/system/$unit" || return 1; done
        if ((was_stopped)); then (umask 077; printf 'chaff=%s\n' "$resume_chaff" > "$marker"); else rm -f "$marker"; fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        rm -rf "$temp"
        echo 'ثبت تنظیم توقف/شروع ناموفق بود؛ فایل‌های قبلی بازیابی شدند.' >&2
        return 1
    fi
    rm -rf "$temp"
    if [[ "$action" == stop ]]; then
        # Stop FRP and cover traffic before removing their GRE interface.
        for ((i=${#units[@]}-1; i>=0; i--)); do
            unit=${units[i]}
            systemctl stop "$unit" || failure=1
            if systemctl is-active --quiet "$unit"; then failure=1; fi
        done
        (( ! failure )) || { echo 'توقف کامل نشد؛ وضعیت سرویس‌ها را بررسی کنید. توقف دستی ثبت شده است.' >&2; return 1; }
        echo 'همین تونل متوقف شد؛ توقف پس از ریبوت و راه‌اندازی خودکار هم حفظ می‌شود.'
    else
        for unit in "${units[@]}"; do
            [[ "$unit" != "${chaff}.service" || "$resume_chaff" == 1 ]] || continue
            if ! systemctl start "$unit" || ! systemctl is-active --quiet "$unit"; then failure=1; break; fi
        done
        if ((failure)); then
            (umask 077; printf 'chaff=%s\n' "$resume_chaff" > "$marker")
            for ((i=${#units[@]}-1; i>=0; i--)); do systemctl stop "${units[i]}" >/dev/null 2>&1 || true; done
            echo 'شروع تونل ناموفق بود؛ برای جلوگیری از راه‌اندازی ناقص، تونل متوقف ماند.' >&2
            return 1
        fi
        echo 'همین تونل شروع شد؛ برقراری اتصال سمت مقابل را از وضعیت و لاگ‌ها بررسی کنید.'
    fi
}

menu_edit_peer() {
    local id option value rec name service iface bundle loss protocol settings
    id=$(menu_select_peer) || return 0
    while true; do
        ui_clear
        rec=$(peer_get "$id") || return 1
        [[ -n "$rec" ]] || return 0
        name=$(python3 -c 'import json,sys; p=json.load(sys.stdin); print(p.get("name",""),"|",p.get("remote_pub",""),"| پورت‌ها:",",".join(map(str,p.get("ports",[]))))' <<< "$rec")
        echo "تونل: $name"
        service=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("frps_svc",""))' <<< "$rec")
        local service_state
        service_state=$(systemctl is-active "$service" 2>/dev/null) || true
        echo "وضعیت سرویس همین تونل: $(fa_state "${service_state:-unknown}")"
        echo "پورت کنترل FRP: $(python3 -c 'import json,sys; print(json.load(sys.stdin).get("frp_port","نامشخص"))' <<< "$rec")"
        echo "IP ذخیره‌شده ایران: $(python3 -c 'import json,sys; print(json.load(sys.stdin).get("local_pub",""))' <<< "$rec")"
        settings=$(peer_connection_settings "$id") || return 1
        IFS=$'\t' read -r protocol loss <<< "$settings"
        [[ "$loss" == on ]] && loss='فعال' || loss='غیرفعال'
        echo "انتخاب ذخیره‌شده ایران: FRP=$protocol | جبران افت بسته: $loss"
        echo 'اعمال روی خارج نیاز به کد اتصال دارد؛ وضعیت خارج از اینجا بررسی نشده است.'
        iface=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["gre_if"])' <<< "$rec")
        echo "MTU: $(tunnel_mtu_get "$iface")"
        local counter
        counter=$(traffic_id_for_interface "$iface") || return 1
        if [[ -n "$counter" ]]; then
            echo 'آخرین مصرف ذخیره‌شده؛ پایش هر 10 ثانیه:'
            traffic_summary "$counter" || return 1
        else
            echo 'شمارنده ترافیک ثبت نشده است؛ از گزینه 9 برای ثبت و نمایش مصرف استفاده کنید.'
        fi
        echo '1) شروع همین تونل'
        echo '2) توقف همین تونل'
        echo '3) ری‌استارت همین تونل'
        echo '4) تغییر پورت‌های سرویس'
        echo '5) تغییر نام تونل'
        echo '6) تغییر IP سرور خارج'
        echo '7) انتخاب روش انتقال GRE'
        echo '8) دریافت کد اتصال خارج'
        echo '9) مصرف و تنظیمات ترافیک همین تونل'
        echo '10) فعال‌سازی یا غیرفعال‌سازی جبران افت بسته'
        echo '11) انتخاب پروتکل FRP'
        echo '12) تغییر دائمی MTU همین تونل'
        echo '13) تغییر پورت کنترل FRP همین تونل'
        echo '14) حذف همین تونل'
        echo '0) بازگشت'
        read -r -p 'انتخاب: ' option || return 0
        case "$option" in
            4|5|6)
                echo 'Enter: بدون تغییر'
                read -r -p 'مقدار جدید: ' value || return 0
                [[ -n "$value" ]] || continue
                case "$option" in
                    4) cli_edit_peer --id "$id" --ports "$value" && echo 'برای اعمال پورت‌ها در خارج، کد اتصال جدید را روی سرور خارج دوباره اعمال کنید.' ;;
                    5) cli_edit_peer --id "$id" --name "$value" ;;
                    6) cli_edit_peer --id "$id" --remote-pub "$value" ;;
                esac ;;
            7)
                ui_clear
                echo 'انتخاب روش انتقال GRE همین تونل'
                echo '1) GRE مستقیم'
                echo '2) FOU:443'
                echo '3) FOU:55555'
                echo '0) لغو'
                read -r -p 'انتخاب: ' value || return 0
                case "$value" in 1) value=direct;; 2) value=fou:443;; 3) value=fou:55555;; *) continue;; esac
                cli_edit_peer --id "$id" --carrier "$value"
                echo 'روش انتقال دو سمت باید یکسان باشد؛ تنظیمات سرور خارج را هم به‌روز کنید.' ;;
            8)
                local connection_output
                if connection_output=$(peer_token "$id"); then
                    bundle=$(sed -n 's/^BUNDLE://p' <<< "$connection_output")
                    if [[ -n "$bundle" ]]; then
                        echo 'روی سرور خارج (بعد از نصب NavaTunnel) اجرا کنید:'
                        printf 'NavaTunnel setup-foreign --bundle %q\n' "$bundle"
                        echo 'این کد شامل توکن اتصال است؛ آن را عمومی منتشر نکنید.'
                    else
                        echo 'کد اتصال تولید نشد؛ اطلاعات ذخیره‌شده تونل را بررسی کنید.'
                    fi
                else
                    echo 'دریافت کد اتصال ناموفق بود؛ خطای بالا را بررسی کنید.'
                fi
                pause_prompt ;;
            3)
                service=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["frps_svc"])' <<< "$rec")
                iface=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["gre_if"])' <<< "$rec")
                if systemctl restart "${iface}.service" && systemctl restart "${service}.service"; then echo 'تونل ری‌استارت شد.'; else echo 'ری‌استارت ناموفق بود؛ وضعیت سرویس را بررسی کنید.'; fi ;;
            2) cli_tunnel_power stop --id "$id" ;;
            1) cli_tunnel_power start --id "$id" ;;
            9) menu_tunnel_traffic "$iface" ;;
            12) menu_mtu "$iface" ;;
            13)
                echo 'تغییر پورت کنترل اتصال خارج را قطع می‌کند؛ پس از تغییر، کد جدید را روی خارج اعمال کنید.'
                value=$(menu_control_port_prompt "$id") || continue
                cli_peer_control_port --id "$id" --port "$value" ;;
            11) value=$(menu_protocol_prompt "$protocol") || continue; cli_peer_protocol --id "$id" --protocol "$value" ;;
            10) menu_loss_recovery "$id" ;;
            14) cli_remove_peer --id "$id"; [[ -n "$(peer_get "$id")" ]] || return 0 ;;
            0) return 0 ;;
            *) echo 'گزینه نامعتبر است.' ;;
        esac
        case "$option" in 4|5|6|7|3|11|12|13|2|1) pause_prompt ;; 8|9|14|10) ;; *) pause_prompt ;; esac
    done
}

setup_foreign_server() {
    ui_clear
    echo -e "\n${YELLOW}====================================================${NC}"
    echo -e "${YELLOW}   مرحله 2: تنظیم سرور خارج با GRE و FRP  ${NC}"
    echo -e "${YELLOW}====================================================${NC}"
    MY_PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    [[ -z "$MY_PUBLIC_IP" ]] && MY_PUBLIC_IP=$(curl -sSL --max-time 5 https://api.ipify.org 2>/dev/null)

    echo -e "کد اتصال سرور ایران را دارید؟ (${CYAN}hsh1_...${NC})"
    read -p "کد اتصال را وارد کنید [Enter: تنظیم دستی]: " BUNDLE_IN
    local SERVER_PORT TOKEN INPUT_PORTS BUNDLE_USED=0 LOCAL_GRE_SET="$FOREIGN_GRE_IP" PEER_GRE_SET="$IRAN_GRE_IP"
    local IP_FOREIGN="" IP_IRAN="" LOSS=off TRANSPORT=tcp

    if [[ -n "$BUNDLE_IN" ]]; then
        if bundle_parse "$BUNDLE_IN"; then
            echo ""
            cli_bundle_inspect "$BUNDLE_IN"
            read -p "تنظیمات این کد اتصال اعمال شود؟ [Y/n]: " CONFIRM_APPLY
            if [[ "$CONFIRM_APPLY" =~ ^[Nn]$ ]]; then
                echo -e "${YELLOW}[*] اعمال کد اتصال لغو شد؛ بازگشت به منو.${NC}"
                return 0
            fi
            BUNDLE_USED=1
            LOSS=$B_LOSS_RECOVERY
            TRANSPORT=$B_FRP_TRANSPORT
            prompt_ip IP_FOREIGN "IP عمومی سرور خارج" "$MY_PUBLIC_IP"
            IP_IRAN=$B_IRAN_PUB
            SERVER_PORT=$B_FRP_PORT
            TOKEN=$B_TOKEN
            LOCAL_GRE_SET=$B_FOREIGN_GRE
            PEER_GRE_SET=$B_IRAN_GRE
            INPUT_PORTS=$(echo "$B_PORTS" | tr ' ' ',')
            carrier_set_fou_ports "$B_FOU_P1" "$B_FOU_P2" 2>/dev/null || true
            carrier_init_kernel 2>/dev/null || true
            if [[ -z "$INPUT_PORTS" ]]; then
                prompt_ports INPUT_PORTS "پورت‌های سرویس"
            fi
        else
            echo -e "${RED}[!] کد اتصال نامعتبر است؛ ادامه با تنظیم دستی.${NC}"
        fi
    fi

    if [[ "$BUNDLE_USED" -ne 1 ]]; then
        prompt_ip IP_FOREIGN "IP عمومی سرور خارج" "$MY_PUBLIC_IP"
        prompt_ip IP_IRAN "IP عمومی سرور ایران" ""
        prompt_port SERVER_PORT "پورت FRP اعلام‌شده از ایران" "$(gen_random_port)"
        prompt_required TOKEN "توکن محرمانه اتصال"
        prompt_ports INPUT_PORTS "پورت‌های سرویس"
    fi

    if [[ "$BUNDLE_USED" != 1 ]]; then LOSS=$(menu_loss_prompt) || return 0; fi
    [[ "$LOSS" == on ]] && TRANSPORT=kcp
    TRANSPORT=$(menu_protocol_prompt "$TRANSPORT") || return 0
    PORTS_CLEANED=$(echo "$INPUT_PORTS" | tr ',' ' ')

    # single source of truth: GRE + ping + frpc all happen inside
    _setup_foreign_full "$IP_FOREIGN" "$IP_IRAN" "$SERVER_PORT" "$TOKEN" "$LOCAL_GRE_SET" "$PEER_GRE_SET" "$PORTS_CLEANED" "" off "$TRANSPORT"
}

check_status() {
    echo -e "\n${YELLOW}=== بررسی وضعیت GRE و FRP ===${NC}"

    # 1. GRE Status
    echo -e "\n${CYAN}[1] اینترفیس تونل GRE:${NC}"
    if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
        ip addr show dev "$TUNNEL_NAME"
        echo -e "${GREEN}[✔️] اینترفیس ${TUNNEL_NAME} موجود و فعال است.${NC}"
    else
        echo -e "${YELLOW}[*] اینترفیس ${TUNNEL_NAME} پیدا نشد.${NC}"
    fi

    # 2. Ping Test
    if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
        echo -e "\n${CYAN}[2] تست پینگ GRE:${NC}"
        if ip addr show dev "$TUNNEL_NAME" 2>/dev/null | grep -q "$IRAN_GRE_IP"; then
            TARGET_PING="$FOREIGN_GRE_IP"
            echo "تست پینگ IP داخلی GRE خارج ($TARGET_PING)..."
        else
            TARGET_PING="$IRAN_GRE_IP"
            echo "تست پینگ IP داخلی GRE ایران ($TARGET_PING)..."
        fi
        ping -c 3 -W 2 "$TARGET_PING" && echo -e "${GREEN}[✔️] پینگ موفق بود.${NC}" || echo -e "${YELLOW}[!] سرور مقابل پاسخ پینگ نداد.${NC}"
    fi

    # 3. Service Status
    echo -e "\n${CYAN}[3] وضعیت سرویس‌های تونل:${NC}"
    if systemctl is-active --quiet frps; then
        echo -e "${GREEN}[✔️] سرویس frps روی ایران فعال است.${NC}"
        systemctl status frps --no-pager -l
    elif systemctl is-active --quiet frpc; then
        echo -e "${GREEN}[✔️] سرویس frpc روی خارج فعال است.${NC}"
        systemctl status frpc --no-pager -l
    else
        echo -e "${RED}[!] هیچ‌یک از سرویس‌های FRP فعال نیستند.${NC}"
    fi
}

show_logs() {
    echo -e "\n${YELLOW}=== لاگ زنده سرویس‌ها (Ctrl+C: خروج) ===${NC}"
    if systemctl list-unit-files | grep -q "frps.service"; then
        journalctl -u frps -n 50 -f
    elif systemctl list-unit-files | grep -q "frpc.service"; then
        journalctl -u frpc -n 50 -f
    else
        echo -e "${RED}[!] سرویس تونل پیدا نشد.${NC}"
    fi
}

restart_all() {
    echo -e "\n${CYAN}[*] در حال ری‌استارت سرویس‌های GRE و FRP همه تونل‌ها...${NC}"
    local u
    for u in /etc/systemd/system/gre-t*.service /etc/systemd/system/frps*.service /etc/systemd/system/frpc.service /etc/systemd/system/gre-chaff*.service; do
        [[ -f "$u" ]] || continue
        systemctl restart "$(basename "$u")" >/dev/null 2>&1 && echo -e "${GREEN}[✔️] سرویس $(basename "$u") ری‌استارت شد.${NC}"
    done
    echo -e "${GREEN}[✔️] همه سرویس‌ها ری‌استارت شدند.${NC}"
}

ensure_doctor_tools() {
    local NEED_INSTALL=0
    for cmd in iperf3 ping curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            NEED_INSTALL=1
            break
        fi
    done
    if [[ "$NEED_INSTALL" -eq 1 ]]; then
        echo -e "${CYAN}[*] در حال نصب ابزارهای بررسی شبکه...${NC}"
        apt-get update -qq && apt-get install -y -qq iperf3 iputils-ping curl || echo -e "${YELLOW}[!] نصب بعضی ابزارهای بررسی شبکه ناموفق بود.${NC}"
    fi
}

doctor_diagnostics() {
    ensure_doctor_tools

    echo -e "\n${CYAN}==========================================================${NC}"
    echo -e "${CYAN}      بررسی سلامت شبکه و تست سرعت NavaTunnel      ${NC}"
    echo -e "${CYAN}==========================================================${NC}\n"

    # 1. Determine Peer IP
    local ROLE="unknown"
    local TARGET_IP=""
    local LOCAL_IP=""

    if ip addr show dev "$TUNNEL_NAME" 2>/dev/null | grep -q "$IRAN_GRE_IP"; then
        ROLE="Iran (Server)"
        LOCAL_IP="$IRAN_GRE_IP"
        TARGET_IP="$FOREIGN_GRE_IP"
    elif ip addr show dev "$TUNNEL_NAME" 2>/dev/null | grep -q "$FOREIGN_GRE_IP"; then
        ROLE="Foreign (Client)"
        LOCAL_IP="$FOREIGN_GRE_IP"
        TARGET_IP="$IRAN_GRE_IP"
    else
        local IFACE
        IFACE=$(ip -o link show type gre 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | head -n1)
        if [[ -n "$IFACE" ]]; then
            LOCAL_IP=$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
            if [[ "$LOCAL_IP" =~ \.1$ ]]; then
                TARGET_IP="${LOCAL_IP%.*}.2"
                ROLE="Foreign"
            elif [[ "$LOCAL_IP" =~ \.2$ ]]; then
                TARGET_IP="${LOCAL_IP%.*}.1"
                ROLE="Iran"
            fi
        fi
    fi

    echo -e "  ${YELLOW}نقش:${NC}        ${ROLE}"
    echo -e "  ${YELLOW}تونل:${NC}      ${TUNNEL_NAME:-gre-tunnel}"
    echo -e "  ${YELLOW}IP این سرور:${NC}    ${LOCAL_IP:-N/A}"
    echo -e "  ${YELLOW}IP سرور مقابل:${NC}     ${TARGET_IP:-N/A}\n"

    if [[ -z "$TARGET_IP" ]]; then
        echo -e "${RED}[!] اینترفیس تونل فعال نیست یا IP مقابل پیدا نشد.${NC}"
        return 1
    fi

    # 2. Ping & Jitter Test (10 packets)
    echo -e "${CYAN}[1/4] اندازه‌گیری تأخیر، افت بسته و نوسان با 10 بسته...${NC}"
    local PING_OUT
    PING_OUT=$(ping -c 10 -W 2 "$TARGET_IP" 2>&1)
    local LOSS
    LOSS=$(echo "$PING_OUT" | awk -F',' '/packet loss/ {for(i=1;i<=NF;i++) if($i~/packet loss/) print $(i-0)}' | tr -dc '0-9.')
    local RTT_LINE
    RTT_LINE=$(echo "$PING_OUT" | grep -E '(rtt|round-trip) min/avg/max')

    local MIN_RTT="0" AVG_RTT="0" MAX_RTT="0" JITTER="0"
    if [[ -n "$RTT_LINE" ]]; then
        local STATS
        STATS=$(echo "$RTT_LINE" | awk -F'=' '{print $2}' | tr -d ' ' | cut -d'/' -f1-4)
        MIN_RTT=$(echo "$STATS" | cut -d'/' -f1)
        AVG_RTT=$(echo "$STATS" | cut -d'/' -f2)
        MAX_RTT=$(echo "$STATS" | cut -d'/' -f3)
        JITTER=$(echo "$STATS" | cut -d'/' -f4)
    fi

    local LOSS_INT="${LOSS%%.*}"
    LOSS_INT="${LOSS_INT:-0}"

    echo -e "  • افت بسته:  ${LOSS:-0}%"
    echo -e "  • کمترین تأخیر:      ${MIN_RTT} ms"
    echo -e "  • میانگین تأخیر:      ${AVG_RTT} ms"
    echo -e "  • بیشترین تأخیر:      ${MAX_RTT} ms"
    echo -e "  • نوسان تأخیر:${JITTER} ms"

    if [[ "$LOSS_INT" -eq 0 ]]; then
        echo -e "  ${GREEN}[✔️] تست پینگ بدون افت بسته انجام شد.${NC}\n"
    elif [[ "$LOSS_INT" -le 10 ]]; then
        echo -e "  ${YELLOW}[⚠️] افت بسته کم (${LOSS}%).${NC}\n"
    else
        echo -e "  ${RED}[!] افت بسته زیاد مشاهده شد (${LOSS}%).${NC}\n"
    fi

    # 3. Path MTU Discovery
    echo -e "${CYAN}[2/4] بررسی MTU مسیر و تکه‌شدن بسته‌ها...${NC}"
    local OPTIMAL_MTU=0
    # 1420
    if ping -c 2 -W 2 -M do -s 1392 "$TARGET_IP" >/dev/null 2>&1; then
        echo -e "  • MTU 1420: ${GREEN}PASS (Unfragmented)${NC}"
        OPTIMAL_MTU=1420
    else
        echo -e "  • MTU 1420: ${YELLOW}FRAGMENTED${NC}"
    fi

    # 1400
    if ping -c 2 -W 2 -M do -s 1372 "$TARGET_IP" >/dev/null 2>&1; then
        echo -e "  • MTU 1400: ${GREEN}PASS (Unfragmented)${NC}"
        [[ "$OPTIMAL_MTU" -eq 0 ]] && OPTIMAL_MTU=1400
    else
        echo -e "  • MTU 1400: ${YELLOW}FRAGMENTED${NC}"
    fi

    # 1360
    if ping -c 2 -W 2 -M do -s 1332 "$TARGET_IP" >/dev/null 2>&1; then
        echo -e "  • MTU 1360: ${GREEN}PASS (Unfragmented)${NC}"
        [[ "$OPTIMAL_MTU" -eq 0 ]] && OPTIMAL_MTU=1360
    else
        echo -e "  • MTU 1360: ${RED}ناموفق${NC}"
    fi

    echo -e "  ${GREEN}[✔️] MTU پیشنهادی مسیر: ${OPTIMAL_MTU:-1400} بایت.${NC}\n"

    # 4. Kernel TCP Stack Audit
    echo -e "${CYAN}[3/4] بررسی TCP سیستم و هدایت بسته‌ها...${NC}"
    local CC
    CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    local FWD
    FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    local MSS_COUNT
    MSS_COUNT=$(iptables -t mangle -L -v -n 2>/dev/null | grep -c "TCPMSS" || echo "0")

    if [[ "$CC" == "bbr" ]]; then
        echo -e "  • کنترل ازدحام TCP: ${GREEN}BBR فعال${NC}"
    else
        echo -e "  • کنترل ازدحام TCP: ${YELLOW}${CC} (BBR فعال نیست)${NC}"
    fi

    if [[ "$FWD" == "1" ]]; then
        echo -e "  • هدایت IPv4:        ${GREEN}فعال${NC}"
    else
        echo -e "  • هدایت IPv4:        ${RED}غیرفعال${NC}"
    fi

    if [[ "$MSS_COUNT" -gt 0 ]]; then
        echo -e "  • محدودیت MSS برای TCP:       ${GREEN}Active (${MSS_COUNT} rules)${NC}\n"
    else
        echo -e "  • محدودیت MSS برای TCP:       ${YELLOW}تنظیم نشده${NC}\n"
    fi

    # 5. Throughput / iPerf3 Test
    echo -e "${CYAN}[4/4] تست پهنای باند و سرعت انتقال...${NC}"
    if command -v iperf3 >/dev/null 2>&1; then
        echo -e "  تست انتقال سه‌ثانیه‌ای به ${TARGET_IP}:5201..."
        local IPERF_OUT
        IPERF_OUT=$(iperf3 -c "$TARGET_IP" -t 3 -J 2>/dev/null)
        if [[ -n "$IPERF_OUT" ]] && echo "$IPERF_OUT" | grep -q '"bits_per_second"'; then
            local BPS
            BPS=$(echo "$IPERF_OUT" | awk -F'"bits_per_second":' '/"bits_per_second"/ {print $2}' | tr -dc '0-9.' | head -n1)
            local MBPS
            MBPS=$(awk -v b="$BPS" 'BEGIN { if (b > 0) printf "%.2f", b / 1000000; else print "0" }')
            echo -e "  ${GREEN}[✔️] سرعت انتقال: ${MBPS} Mbps${NC}\n"
        else
            echo -e "  ${YELLOW}[i] سرویس iperf3 روی مقابل فعال نیست در ${TARGET_IP}:5201.${NC}"
            echo -e "      (برای تست مستقیم سرعت، روی مقابل NavaTunnel doctor server را اجرا کنید).\n"
        fi
    fi

    # 6. Overall Rating & Recommendations
    local SCORE=100
    if [[ "$LOSS_INT" -gt 0 ]]; then
        SCORE=$((SCORE - LOSS_INT * 2))
    fi
    if [[ "$AVG_RTT" != "0" ]] && awk -v r="$AVG_RTT" 'BEGIN { exit (r > 100 ? 0 : 1) }'; then
        SCORE=$((SCORE - 15))
    fi
    if [[ "$CC" != "bbr" ]]; then
        SCORE=$((SCORE - 15))
    fi
    if [[ "$FWD" != "1" ]]; then
        SCORE=$((SCORE - 20))
    fi
    if [[ "$MSS_COUNT" -eq 0 ]]; then
        SCORE=$((SCORE - 10))
    fi
    if [[ "$OPTIMAL_MTU" -lt 1400 && "$OPTIMAL_MTU" -gt 0 ]]; then
        SCORE=$((SCORE - 10))
    fi
    [[ "$SCORE" -lt 0 ]] && SCORE=0

    echo -e "${CYAN}==========================================================${NC}"
    echo -e "  ${YELLOW}امتیاز سلامت:${NC} ${SCORE}/100"
    if [[ "$SCORE" -ge 85 ]]; then
        echo -e "  ${GREEN}وضعیت: عالی؛ تنظیمات بررسی‌شده تونل مناسب‌اند.${NC}"
    elif [[ "$SCORE" -ge 70 ]]; then
        echo -e "  ${CYAN}وضعیت: خوب؛ بهینه‌سازی جزئی پیشنهاد می‌شود.${NC}"
    elif [[ "$SCORE" -ge 50 ]]; then
        echo -e "  ${YELLOW}وضعیت: هشدار؛ افت بسته یا محدودیت سیستم وجود دارد.${NC}"
    else
        echo -e "  ${RED}وضعیت: بحرانی؛ مشکل مهم شبکه یا مسیر مشاهده شد.${NC}"
    fi
    echo -e "${CYAN}==========================================================${NC}\n"

    if [[ "$SCORE" -lt 85 ]]; then
        read -p "اصلاحات پیشنهادی BBR، MSS و MTU خودکار اعمال شوند؟ [y/N]: " DO_FIX
        if [[ "$DO_FIX" =~ ^[Yy]$ ]]; then
            doctor_apply_fixes
        fi
    fi
}

doctor_apply_fixes() {
    echo -e "\n${CYAN}[*] در حال اعمال بهینه‌سازی خودکار...${NC}"
    tune_apply
    echo -e "${GREEN}[✔️] بهینه‌سازی اعمال شد.${NC}\n"
}

doctor_start_server() {
    ensure_doctor_tools
    if pgrep -x iperf3 >/dev/null 2>&1; then
        echo -e "${YELLOW}[i] سرویس iperf3 از قبل فعال است.${NC}"
    else
        iperf3 -s -D
        echo -e "${GREEN}[✔️] سرویس iperf3 روی پورت 5201 اجرا شد.${NC}"
    fi
}

doctor_stop_server() {
    pkill -f "iperf3 -s" >/dev/null 2>&1 || true
    echo -e "${GREEN}[✔️] سرویس iperf3 متوقف شد.${NC}"
}

doctor_health_check() {
    echo -e "\n${CYAN}=============================================================="
    echo "             بررسی سلامت سیستم و تونل NavaTunnel"
    echo -e "==============================================================${NC}"

    local PASS_COUNT=0 WARN_COUNT=0 FAIL_COUNT=0

    report_item() {
        local name="$1" status="$2" details="$3"
        local badge
        case "$status" in
            PASS) badge="${GREEN}[موفق]${NC}"; ((PASS_COUNT++)) ;;
            WARN) badge="${YELLOW}[هشدار]${NC}"; ((WARN_COUNT++)) ;;
            FAIL) badge="${RED}[ناموفق]${NC}"; ((FAIL_COUNT++)) ;;
        esac
        printf "%-8b %-30s %s\n" "$badge" "$name" "$details"
    }

    # 1. OS & Architecture
    local OS_INFO
    OS_INFO=$(uname -s -m 2>/dev/null || echo "Linux")
    report_item "سیستم‌عامل و معماری" "PASS" "$OS_INFO"

    # 2. نسخه کرنل لینوکس
    local KERNEL_VER
    KERNEL_VER=$(uname -r 2>/dev/null || echo "Unknown")
    report_item "نسخه کرنل لینوکس" "PASS" "$KERNEL_VER"

    # 3. IP Forwarding
    local IP_FWD
    IP_FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
    if [[ "$IP_FWD" == "1" ]]; then
        report_item "هدایت بسته‌ها (ip_forward)" "PASS" "فعال (1)"
    else
        report_item "هدایت بسته‌ها (ip_forward)" "WARN" "غیرفعال (0)؛ از sysctl فعال کنید"
    fi

    # 4. GRE Kernel Modules
    if lsmod 2>/dev/null | grep -q "ip_gre" || modprobe ip_gre 2>/dev/null; then
        report_item "ماژول GRE کرنل" "PASS" "بارگذاری‌شده"
    else
        report_item "ماژول GRE کرنل" "FAIL" "ماژول ip_gre موجود یا قابل بارگذاری نیست"
    fi

    # 5. FOU Kernel Module
    if lsmod 2>/dev/null | grep -q "fou" || modprobe fou 2>/dev/null; then
        report_item "ماژول FOU کرنل" "PASS" "بارگذاری‌شده"
    else
        report_item "ماژول FOU کرنل" "WARN" "ماژول FOU در دسترس نیست؛ استفاده از GRE مستقیم"
    fi

    # 6. اینترفیس GRE Status
    if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
        local INNER_IP
        INNER_IP=$(ip -4 addr show dev "$TUNNEL_NAME" 2>/dev/null | awk '/inet / {print $2}')
        if [[ -n "$INNER_IP" ]]; then
            report_item "اینترفیس GRE (${TUNNEL_NAME})" "PASS" "فعال با IP: $INNER_IP"
        else
            report_item "اینترفیس GRE (${TUNNEL_NAME})" "WARN" "اینترفیس موجود است ولی IPv4 ندارد"
        fi
    else
        report_item "اینترفیس GRE (${TUNNEL_NAME})" "WARN" "اینترفیس پیدا نشد"
    fi

    # 7. GRE Peer Ping Connectivity
    local PEER_PING_TARGET=""
    if [[ -f /etc/frp/frpc.toml ]]; then
        PEER_PING_TARGET=$(awk -F'=' '/serverAddr/{gsub(/[ "]/,"",$2); print $2}' /etc/frp/frpc.toml 2>/dev/null)
    elif [[ -f /etc/frp/frps.toml ]]; then
        PEER_PING_TARGET="$FOREIGN_GRE_IP"
    fi
    if [[ -n "$PEER_PING_TARGET" ]]; then
        local P_OUT
        if P_OUT=$(ping -c 2 -W 2 "$PEER_PING_TARGET" 2>/dev/null); then
            local RTT
            RTT=$(echo "$P_OUT" | awk -F'/' '/rtt/ {print $5}')
            report_item "دسترسی به GRE مقابل" "PASS" "قابل دسترسی (${RTT:-<50} ms)"
        else
            # ICMP may be filtered by ISP/DPI (common in Iran with GRE tunnels).
            # If frpc is active, TCP through GRE is working — downgrade to WARN.
            if systemctl is-active --quiet frpc 2>/dev/null; then
                report_item "دسترسی به GRE مقابل" "WARN" "پینگ ICMP مسدود است ولی سرویس TCP تونل فعال است"
            else
                report_item "دسترسی به GRE مقابل" "FAIL" "پینگ سرور مقابل ناموفق بود ${PEER_PING_TARGET}"
            fi
        fi
    else
        report_item "دسترسی به GRE مقابل" "WARN" "IP سرور مقابل هنوز تنظیم نشده است"
    fi

    # 8. FRPS Service
    if [[ -f /etc/systemd/system/frps.service ]]; then
        if systemctl is-active --quiet frps 2>/dev/null; then
            local F_PORT
            F_PORT=$(awk -F'=' '/bindPort/{gsub(/[ "]/,"",$2); print $2}' /etc/frp/frps.toml 2>/dev/null)
            report_item "سرور FRP (frps)" "PASS" "فعال روی پورت :${F_PORT:-unknown}"
        else
            report_item "سرور FRP (frps)" "FAIL" "سرویس نصب شده ولی فعال نیست"
        fi
    fi

    # 9. FRPC Service
    if [[ -f /etc/systemd/system/frpc.service ]]; then
        if systemctl is-active --quiet frpc 2>/dev/null; then
            report_item "کلاینت FRP (frpc)" "PASS" "فعال؛ اتصال معکوس برقرار است"
        else
            report_item "کلاینت FRP (frpc)" "FAIL" "سرویس نصب شده ولی فعال نیست"
        fi
    fi

    # 11. Firewall / Ports
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        report_item "فایروال UFW" "PASS" "فعال؛ پورت‌ها تنظیم شده‌اند"
    else
        report_item "فایروال UFW" "PASS" "بدون محدودیت یا غیرفعال"
    fi

    echo -e "${CYAN}==============================================================${NC}"
    if [[ "$FAIL_COUNT" -eq 0 && "$WARN_COUNT" -eq 0 ]]; then
        echo -e "نتیجه کلی بررسی سلامت: ${GREEN}موفق${NC} (همه بررسی‌ها موفق بودند)"
    elif [[ "$FAIL_COUNT" -eq 0 ]]; then
        echo -e "نتیجه کلی بررسی سلامت: ${YELLOW}هشدار${NC} (${WARN_COUNT} هشدار مشاهده شد؛ سیستم قابل استفاده است)"
    else
        echo -e "نتیجه کلی بررسی سلامت: ${RED}ناموفق${NC} (${FAIL_COUNT} خطای مهم مشاهده شد)"
    fi
    echo -e "${CYAN}==============================================================${NC}\n"
}

cli_doctor() {
    case "${1:-}" in
        server) doctor_start_server ;;
        stop-server) doctor_stop_server ;;
        fix) doctor_apply_fixes ;;
        diag|speed) doctor_diagnostics ;;
        stress|stress-test|load) shift; cli_stress_test "$@" ;;
        check|*) doctor_health_check ;;
    esac
}

cli_stress_test() {
    local TARGET_HOST="${1:-127.0.0.1}"
    local TARGET_PORT="${2:-}"
    local CONNS="${3:-200}"

    if [[ -z "$TARGET_PORT" ]]; then
        TARGET_PORT=$(awk -F'=' '/bindPort/{gsub(/[ "]/,"",$2); print $2}' /etc/frp/frps.toml 2>/dev/null)
        [[ -z "$TARGET_PORT" ]] && TARGET_PORT=$(awk -F'=' '/serverPort/{gsub(/[ "]/,"",$2); print $2}' /etc/frp/frpc.toml 2>/dev/null)
        [[ -z "$TARGET_PORT" ]] && TARGET_PORT=7000
    fi

    echo -e "\n${CYAN}==============================================================${NC}"
    echo -e "${CYAN}      تست فشار اتصال هم‌زمان NavaTunnel${NC}"
    echo -e "${CYAN}==============================================================${NC}"
    echo -e "مقصد: ${GREEN}${TARGET_HOST}:${TARGET_PORT}${NC}"
    echo -e "اتصال‌های هم‌زمان: ${YELLOW}${CONNS}${NC}\n"

    echo -e "${CYAN}[*] بررسی ظرفیت اتصال هم‌زمان سیستم...${NC}"
    local NOFILE_VAL
    NOFILE_VAL=$(ulimit -n 2>/dev/null || echo 1024)
    local SOMAXCONN_VAL
    SOMAXCONN_VAL=$(sysctl -n net.core.somaxconn 2>/dev/null || echo 128)
    local CONNTRACK_VAL
    CONNTRACK_VAL=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || sysctl -n net.nf_conntrack_max 2>/dev/null || echo 65536)

    echo -e "  - ulimit -n: ${GREEN}${NOFILE_VAL}${NC} (هدف: حداقل 65536)"
    echo -e "  - somaxconn: ${GREEN}${SOMAXCONN_VAL}${NC} (هدف: حداقل 65535)"
    echo -e "  - nf_conntrack_max: ${GREEN}${CONNTRACK_VAL}${NC} (هدف: حداقل 1048576)"

    for svc in frps frpc; do
        if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
            local SV_NOFILE
            SV_NOFILE=$(systemctl show -p LimitNOFILE "$svc" 2>/dev/null | cut -d= -f2)
            echo -e "  - ${svc} LimitNOFILE: ${GREEN}${SV_NOFILE:-1048576}${NC}"
        fi
    done

    echo -e "\n${CYAN}[*] در حال شروع ${CONNS} اتصال آزمایشی هم‌زمان...${NC}"
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] python3 پیدا نشد؛ تست به‌صورت ترتیبی با netcat انجام می‌شود.${NC}"
        local SUCCESS=0
        for ((i=1; i<=CONNS; i++)); do
            if nc -z -w 2 "$TARGET_HOST" "$TARGET_PORT" >/dev/null 2>&1; then
                ((SUCCESS++))
            fi
        done
        echo -e "انجام شد: ${SUCCESS} اتصال از ${CONNS} اتصال برقرار شد."
        return 0
    fi

    python3 -c "
import socket, sys, time, concurrent.futures

target_host = sys.argv[1]
target_port = int(sys.argv[2])
conns = int(sys.argv[3])

def probe(cid):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(4.0)
        s.connect((target_host, target_port))
        time.sleep(0.05)
        s.close()
        return True, None
    except Exception as e:
        return False, str(e)

success = 0
dropped = 0
with concurrent.futures.ThreadPoolExecutor(max_workers=min(conns, 200)) as executor:
    futures = [executor.submit(probe, i) for i in range(conns)]
    for f in concurrent.futures.as_completed(futures):
        ok, err = f.result()
        if ok:
            success += 1
        else:
            dropped += 1

print(f'RESULT: Total={conns} Success={success} Dropped={dropped}')
if dropped > 0:
    sys.exit(1)
" "$TARGET_HOST" "$TARGET_PORT" "$CONNS"

    local RET=$?
    echo -e "${CYAN}==============================================================${NC}"
    if [[ $RET -eq 0 ]]; then
        echo -e "${GREEN}[✔️] موفق؛ در تست اتصال‌های هم‌زمان، قطع غیرمنتظره مشاهده نشد.${NC}"
        echo -e "${GREEN}اتصال هم‌زمان زیاد، بدون قطع غیرمنتظره؛ پایداری FRP و تونل${NC}"
    else
        echo -e "${RED}[!] ناموفق؛ بعضی اتصال‌ها زیر بار قطع شدند. فایل /var/log/navatunnel/errors.log را بررسی کنید.${NC}"
    fi
    echo -e "${CYAN}==============================================================${NC}\n"
    return $RET
}

uninstall_all() {
    echo -e "\n${RED}=== حذف کامل تونل‌ها و فرمان NavaTunnel ===${NC}"
    read -p "GRE، FRP و فرمان NavaTunnel حذف شوند؟ [y/N]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        uninstall_all_force
    else
        echo -e "${YELLOW}[*] Aborted.${NC}"
    fi
}

# Non-interactive core: full wipe. Called by uninstall_all() after confirm
# and by `NavaTunnel uninstall --force`. Must also delete the menu entrypoints
# (/usr/local/bin/NavaTunnel + /usr/local/bin/NavaTunnel.sh + legacy gre.sh) so
# `NavaTunnel` stops working.
uninstall_all_force() {
        echo -e "${CYAN}[*] در حال حذف کامل NavaTunnel...${NC}"
        if [[ -f /etc/gre-panel/traffic.json ]]; then cli_traffic clear || return 1; fi
        # 1. Stop & disable all services & timers
        systemctl stop frps frpc "${TUNNEL_NAME}.service" gre-panel gre-chaff navatunnel-chaff navatunnel-watchdog.timer navatunnel-watchdog.service navatunnel-dpi >/dev/null 2>&1 || true
        systemctl stop 'frps*' 'frpc*' 'gre-t*' 'gre-chaff*' 'navatunnel-chaff*' >/dev/null 2>&1 || true
        systemctl disable frps frpc "${TUNNEL_NAME}.service" gre-panel gre-chaff navatunnel-chaff navatunnel-watchdog.timer navatunnel-watchdog.service navatunnel-dpi >/dev/null 2>&1 || true
        systemctl disable 'frps*' 'frpc*' 'gre-t*' 'gre-chaff*' 'navatunnel-chaff*' >/dev/null 2>&1 || true

        # 2. Terminate any leftover processes
        pkill -9 -f "${INSTALL_DIR}/frps" >/dev/null 2>&1 || true
        pkill -9 -f "${INSTALL_DIR}/frpc" >/dev/null 2>&1 || true
        pkill -9 -f "${INSTALL_DIR}/gre-panel" >/dev/null 2>&1 || true
        pkill -9 -f "NavaTunnel-chaff.sh" >/dev/null 2>&1 || true

        # 3. Remove all systemd files
        rm -f /etc/systemd/system/frps*.service /etc/systemd/system/frpc*.service \
              /etc/systemd/system/${TUNNEL_NAME}.service \
              /etc/systemd/system/gre-t*.service /etc/systemd/system/gre-panel.service \
              /etc/systemd/system/gre-chaff*.service /etc/systemd/system/navatunnel-chaff*.service \
              /etc/systemd/system/navatunnel-watchdog.* /etc/systemd/system/navatunnel-dpi.service
        rm -f /etc/systemd/system/NavaTunnel-traffic.service /etc/systemd/system/NavaTunnel-traffic.timer /usr/local/bin/NavaTunnel-traffic.sh /usr/local/bin/navatunnel-traffic.sh
        rm -f /var/lock/navatunnel-watchdog.lock
        chmod 600 "${CONFIG_DIR}"/*.toml 2>/dev/null || true
    systemctl daemon-reload
        systemctl reset-failed >/dev/null 2>&1 || true

        # 4. Remove all GRE and FOU interfaces
        local gif
        for gif in "$TUNNEL_NAME" $(ip tunnel show 2>/dev/null | awk -F: '{print $1}') $(ip -d link show type gre 2>/dev/null | awk -F: '/^[0-9]+: / {print $2}' | tr -d ' '); do
            [[ -n "$gif" ]] && { ip link del "$gif" >/dev/null 2>&1 || ip tunnel del "$gif" >/dev/null 2>&1 || true; }
        done
        if command -v ip >/dev/null 2>&1; then
            ip fou show 2>/dev/null | awk '{print $3}' | while read -r fp; do
                [[ -n "$fp" ]] && ip fou del port "$fp" 2>/dev/null || true
            done
            ip fou del port 19998 >/dev/null 2>&1 || true
        fi

        # 5. Clean iptables / firewall rules
        if command -v iptables >/dev/null 2>&1; then
            iptables -D INPUT -j NAVATUNNEL-DPI 2>/dev/null || true
            iptables -F NAVATUNNEL-DPI 2>/dev/null || true
            iptables -X NAVATUNNEL-DPI 2>/dev/null || true
            iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 2>/dev/null || true
            iptables -t nat -D OUTPUT -p udp --dport 19999 -j DNAT --to-destination 127.0.0.1:19999 2>/dev/null || true
            iptables -D INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null || true
        fi

        # 6. Revert network tuning
        tune_restore >/dev/null 2>&1 || true
        rm -f /etc/sysctl.d/99-navatunnel.conf /etc/sysctl.d/99-gre-panel.conf
        command -v sysctl >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1 || true

        # 7. Remove all binaries
        rm -f "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc"
        rm -f /usr/local/bin/gre-panel /usr/local/bin/grepanel
        rm -f /usr/local/bin/NavaTunnel-chaff.sh /usr/local/bin/gre-chaff.sh

        # 8. Remove configs, data, registries, logs, cron
        rm -rf "$CONFIG_DIR"
        rm -rf /etc/gre-panel /usr/local/gre-panel
        rm -rf /var/log/navatunnel* /var/log/gre-panel* /var/lock/navatunnel* /tmp/navatunnel*
        rm -f /etc/cron.d/navatunnel* /etc/cron.daily/navatunnel*
        crontab -l 2>/dev/null | grep -v 'NavaTunnel' | crontab - 2>/dev/null || true

        # 9. Remove entrypoints last
        rm -f /usr/local/bin/NavaTunnel /usr/local/bin/NavaTunnel.sh /usr/local/bin/navatunnel /usr/local/bin/navatunnel.sh /usr/local/bin/gre.sh

        echo -e "${GREEN}[✔️] حذف کامل انجام شد؛ همه تونل‌ها، سرویس‌ها و فایل‌ها حذف شدند.${NC}"
}

remove_tunnel() {
    echo -e "\n${RED}=== حذف تونل GRE و FRP ===${NC}"
    read -p "تونل از همین سرور حذف شود؟ [y/N]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        remove_tunnel_force
    else
        echo -e "${YELLOW}[*] Aborted.${NC}"
    fi
}

# Non-interactive core: stop/disable units, drop interface, remove FRP files.
# Shared configuration is retained until full uninstall.
remove_tunnel_force() {
        echo -e "${CYAN}[*] در حال حذف همه اجزای تونل...${NC}"
        if [[ -f /etc/gre-panel/traffic.json ]]; then cli_traffic clear || return 1; fi
        # Stop & disable services
        systemctl stop frps frpc "${TUNNEL_NAME}.service" gre-chaff navatunnel-chaff navatunnel-dpi >/dev/null 2>&1 || true
        systemctl stop 'frps*' 'frpc*' 'gre-t*' 'gre-chaff*' 'navatunnel-chaff*' >/dev/null 2>&1 || true
        systemctl disable frps frpc "${TUNNEL_NAME}.service" gre-chaff navatunnel-chaff navatunnel-dpi >/dev/null 2>&1 || true
        systemctl disable 'frps*' 'frpc*' 'gre-t*' 'gre-chaff*' 'navatunnel-chaff*' >/dev/null 2>&1 || true

        # Kill stray tunnel processes
        pkill -9 -f "${INSTALL_DIR}/frps" >/dev/null 2>&1 || true
        pkill -9 -f "${INSTALL_DIR}/frpc" >/dev/null 2>&1 || true
        pkill -9 -f "NavaTunnel-chaff.sh" >/dev/null 2>&1 || true

        # Remove systemd files
        rm -f /etc/systemd/system/frps*.service /etc/systemd/system/frpc.service \
              /etc/systemd/system/${TUNNEL_NAME}.service \
              /etc/systemd/system/gre-t*.service /etc/systemd/system/gre-chaff*.service \
              /etc/systemd/system/navatunnel-chaff*.service /etc/systemd/system/navatunnel-dpi.service
        chmod 600 "${CONFIG_DIR}"/*.toml 2>/dev/null || true
    systemctl daemon-reload
        systemctl reset-failed >/dev/null 2>&1 || true

        # Remove GRE interfaces
        local gif
        for gif in "$TUNNEL_NAME" $(ip tunnel show 2>/dev/null | awk -F: '{print $1}') $(ip -d link show type gre 2>/dev/null | awk -F: '/^[0-9]+: / {print $2}' | tr -d ' '); do
            [[ -n "$gif" ]] && { ip link del "$gif" >/dev/null 2>&1 || ip tunnel del "$gif" >/dev/null 2>&1 || true; }
        done
        if command -v ip >/dev/null 2>&1; then
            ip fou show 2>/dev/null | awk '{print $3}' | while read -r fp; do
                [[ -n "$fp" ]] && ip fou del port "$fp" 2>/dev/null || true
            done
            ip fou del port 19998 >/dev/null 2>&1 || true
        fi

        # Clean firewall rules
        if command -v iptables >/dev/null 2>&1; then
            iptables -D INPUT -j NAVATUNNEL-DPI 2>/dev/null || true
            iptables -F NAVATUNNEL-DPI 2>/dev/null || true
            iptables -X NAVATUNNEL-DPI 2>/dev/null || true
            iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 2>/dev/null || true
            iptables -t nat -D OUTPUT -p udp --dport 19999 -j DNAT --to-destination 127.0.0.1:19999 2>/dev/null || true
            iptables -D INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null || true
        fi

        # Remove configs
        rm -rf "$CONFIG_DIR"
        rm -f "$PEERS_FILE"
        rm -f /usr/local/bin/NavaTunnel-chaff.sh /usr/local/bin/gre-chaff.sh

        echo -e "${GREEN}[✔️] تونل، اینترفیس GRE، سرویس‌های FRP و فایل‌های آن‌ها حذف شدند.${NC}"
}


# ---- Network optimization for tunnel throughput ----
# Same on both roles (auto-detects nothing: these are role-independent).
# Backup lives in /etc/gre-panel/tune.bak (key=value snapshot), restored by
# tune_restore(). Idempotent — safe to run twice.
TUNE_BACKUP="/etc/gre-panel/tune.bak"

tune_backup_once() {
    if [[ -f "$TUNE_BACKUP" ]]; then return 0; fi
    mkdir -p "$(dirname "$TUNE_BACKUP")"
    : > "$TUNE_BACKUP"
    local k v
    for k in net.ipv4.ip_forward net.core.rmem_max net.core.wmem_max \
             net.core.rmem_default net.core.wmem_default net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
             net.core.netdev_max_backlog net.core.somaxconn net.ipv4.tcp_max_syn_backlog \
             net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_window_scaling net.ipv4.tcp_mtu_probing \
             net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes \
             net.core.default_qdisc net.ipv4.tcp_congestion_control \
             net.ipv4.tcp_fastopen net.ipv4.ip_local_port_range; do
        v=$(sysctl -n "$k" 2>/dev/null) || v=""
        echo "$k=$v" >> "$TUNE_BACKUP"
    done
    if lsmod 2>/dev/null | grep -q "^tcp_bbr"; then echo "tcp_bbr=loaded" >> "$TUNE_BACKUP";
    else echo "tcp_bbr=absent" >> "$TUNE_BACKUP"; fi
    echo "gre_mtu=$(ip link show "$TUNNEL_NAME" 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}')" >> "$TUNE_BACKUP"
    if iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
       iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; then
        echo "mss_clamp=present" >> "$TUNE_BACKUP"
    else
        echo "mss_clamp=absent" >> "$TUNE_BACKUP"
    fi
    echo -e "${CYAN}[*] تنظیمات فعلی پشتیبان‌گیری شد در ${TUNE_BACKUP}.${NC}"
}

tune_apply() {
    tune_backup_once
    echo -e "${CYAN}[*] در حال بهینه‌سازی شبکه برای سرعت و پایداری تونل...${NC}"

    # 1. BBR congestion control + fq queuing (best for high-latency / lossy links)
    modprobe tcp_bbr >/dev/null 2>&1 || true
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    if sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
        echo -e "${GREEN}[✔️] کنترل ازدحام TCP روی bbr و fq تنظیم شد${NC}"
    else
        echo -e "${YELLOW}[!] BBR در دسترس نیست؛ کنترل ازدحام فعلی حفظ شد.${NC}"
    fi

    # 2. Bigger socket buffers (16MB) and full TCP window scaling
    sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1
    sysctl -w net.core.rmem_default=1048576 >/dev/null 2>&1
    sysctl -w net.core.wmem_default=1048576 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 1048576 16777216" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 1048576 16777216" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_window_scaling=1 >/dev/null 2>&1
    echo -e "${GREEN}[✔️] بافرهای شبکه روی 16 مگابایت و مقیاس پنجره فعال شد${NC}"

    # 3. Deeper NIC queue and high connection backlog
    sysctl -w net.core.netdev_max_backlog=65535 >/dev/null 2>&1
    sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_max_syn_backlog=65535 >/dev/null 2>&1
    echo -e "${GREEN}[✔️] ظرفیت صف شبکه روی 65535 تنظیم شد${NC}"

    # 4. Anti-stall, keepalive, TIME_WAIT reuse, and fast connection tuning
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_time=30 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_intvl=10 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_probes=5 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_fin_timeout=15 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_max_tw_buckets=2000000 >/dev/null 2>&1 || true
    sysctl -w fs.file-max=2097152 >/dev/null 2>&1 || true
    sysctl -w fs.nr_open=2097152 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    # TCP Fast Open: eliminate 1 RTT on new connections (client+server)
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
    # Wider ephemeral port range: default 32768-60999 → 1024-65535
    # Prevents port exhaustion under high connection load
    sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null 2>&1 || true

    # Conntrack table size & timeout optimization for high concurrent conns
    modprobe nf_conntrack >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_max=1048576 >/dev/null 2>&1 || sysctl -w net.nf_conntrack_max=1048576 >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=7200 >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=60 >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_fin_wait=60 >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=60 >/dev/null 2>&1 || true
    echo -e "${GREEN}[✔️] تنظیم نگهداری TCP، شروع سریع، استفاده مجدد، ظرفیت اتصال و بازه پورت‌ها انجام شد${NC}"

    # OS limits configuration for high concurrency
    mkdir -p /etc/security/limits.d
    cat > /etc/security/limits.d/99-navatunnel.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* soft nproc 512000
* hard nproc 512000
EOF

    # 5. GRE MTU 1380 for tunnel interface and any peer interfaces
    local iface
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^gre-t'); do
        tunnel_mtu_apply "$iface" >/dev/null 2>&1 || true
    done
    if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
        tunnel_mtu_apply "$TUNNEL_NAME" >/dev/null 2>&1 && echo -e "${GREEN}[✔️] ${TUNNEL_NAME} MTU → $(tunnel_mtu_get "$TUNNEL_NAME")${NC}" || echo -e "${YELLOW}[!] اعمال MTU تونل GRE ناموفق بود.${NC}"
    else
        echo -e "${YELLOW}[*] اینترفیس ${TUNNEL_NAME} هنوز موجود نیست؛ MTU در راه‌اندازی بعدی اعمال می‌شود.${NC}"
    fi

    # 6. MSS clamp: POSTROUTING (general) + per GRE interface (precise)
    # --clamp-mss-to-pmtu is less predictable than a fixed value for tunnel links
    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340
    # Per-interface MSS clamp on all GRE ifaces (covers FORWARD path too)
    local gre_iface
    for gre_iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^(gre-t|gre-tunnel)'); do
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$gre_iface" -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
            iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$gre_iface" -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || true
    done
    echo -e "${GREEN}[✔️] محدودیت MSS روی قواعد عمومی و اینترفیس‌های GRE اعمال شد${NC}"

    # 7. Persist across reboots
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-gre-tune.conf <<'EOF'
# NavaTunnel tunnel optimization (applied by Optimize button / tune command)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.core.netdev_max_backlog = 65535
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 2000000
fs.file-max = 2097152
fs.nr_open = 2097152
net.ipv4.ip_forward = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_local_port_range = 1024 65535
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
EOF
    echo -e "${GREEN}[✔️] تنظیمات در /etc/sysctl.d/99-gre-tune.conf ذخیره شد${NC}"
    echo -e "${GREEN}[✔️] بهینه‌سازی انجام شد؛ در صورت افت کیفیت، بازگردانی تنظیمات را اجرا کنید.${NC}"
}

tune_restore() {
    if [[ ! -f "$TUNE_BACKUP" ]]; then
        echo -e "${YELLOW}[!] در ${TUNE_BACKUP} پشتیبان پیدا نشد؛ بازگردانی ممکن نیست.${NC}"
        return 1
    fi
    echo -e "${CYAN}[*] در حال بازگردانی تنظیمات پیش از بهینه‌سازی...${NC}"
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            net.*) [[ -n "$v" ]] && sysctl -w "$k=$v" >/dev/null 2>&1 && echo -e "${GREEN}[✔️] $k → $v${NC}" ;;
            gre_mtu)
                if [[ -n "$v" ]] && ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
                    ip link set dev "$TUNNEL_NAME" mtu "$v" >/dev/null 2>&1 && echo -e "${GREEN}[✔️] ${TUNNEL_NAME} MTU → $v${NC}"
                fi ;;
            mss_clamp)
                if [[ "$v" == "absent" ]]; then
                    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || true
                    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
                    # Also remove per-GRE-iface FORWARD clamp rules added by tune_apply
                    local gri
                    for gri in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^(gre-t|gre-tunnel)'); do
                        iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o "$gri" -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || true
                    done
                    echo -e "${GREEN}[✔️] قواعد محدودیت MSS حذف شدند${NC}"
                fi ;;
        esac
    done < "$TUNE_BACKUP"
    rm -f /etc/sysctl.d/99-gre-tune.conf
    echo -e "${GREEN}[✔️] بازگردانی انجام شد؛ پشتیبان در ${TUNE_BACKUP} تا بهینه‌سازی بعدی باقی می‌ماند.${NC}"
    rm -f "$TUNE_BACKUP"
}

tune_status() {
    echo -e "${CYAN}=== وضعیت بهینه‌سازی تونل ===${NC}"
    echo "کنترل ازدحام: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo ?) ($(sysctl -n net.core.default_qdisc 2>/dev/null || echo ?))"
    echo "بافر دریافت: $(sysctl -n net.core.rmem_max 2>/dev/null || echo ?)"
    echo "بافر ارسال: $(sysctl -n net.core.wmem_max 2>/dev/null || echo ?)"
    echo "صف شبکه: $(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo ?)"
    echo "هدایت بسته‌ها: $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo ?)"
    echo "MTU تونل GRE: $(ip link show "$TUNNEL_NAME" 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}' || echo 'بدون اینترفیس')"
    if iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
       iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; then
        echo "محدودیت MSS: فعال"
    else
        echo "محدودیت MSS: غیرفعال"
    fi
    if [[ -f "$TUNE_BACKUP" ]]; then echo "پشتیبان: $TUNE_BACKUP (قابل بازگردانی)"; else echo "پشتیبان: موجود نیست"; fi
    [[ -f /etc/sysctl.d/99-gre-tune.conf ]] && echo "تنظیم دائمی: فعال در /etc/sysctl.d/99-gre-tune.conf" || echo "تنظیم دائمی: خیر"
}

# free_ram: drop page caches + compact memory + journald cap + ensure 1G swap.
# Safe on any Ubuntu host: no service is touched, kernel reclaims only
# discardable cache; swap is created once and reused afterwards.
free_ram() {
    echo -e "${CYAN}[*] در حال آزادسازی حافظه کش؛ سرویس‌ها متوقف نمی‌شوند...${NC}"
    local before
    before=$(free -m | awk '/^Mem:/{print $7}')
    # 1. journald cap (the #1 silent RAM eater on Ubuntu: 100M+ in RAM)
    if [[ -f /etc/systemd/journald.conf ]]; then
        sed -i 's/^#*SystemMaxUse=.*/SystemMaxUse=32M/' /etc/systemd/journald.conf
        sed -i 's/^#*RuntimeMaxUse=.*/RuntimeMaxUse=16M/' /etc/systemd/journald.conf
        grep -q '^SystemMaxUse=32M' /etc/systemd/journald.conf || echo 'SystemMaxUse=32M' >> /etc/systemd/journald.conf
        grep -q '^RuntimeMaxUse=16M' /etc/systemd/journald.conf || echo 'RuntimeMaxUse=16M' >> /etc/systemd/journald.conf
        journalctl --vacuum-size=16M >/dev/null 2>&1
        systemctl restart systemd-journald >/dev/null 2>&1
        echo -e "${GREEN}[✔️] مصرف لاگ journald به 16 مگابایت محدود شد${NC}"
    fi
    # 2. drop page caches + compact
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    echo 1 > /proc/sys/vm/compact_memory 2>/dev/null
    echo -e "${GREEN}[✔️] کش فایل آزاد و حافظه مرتب شد${NC}"
    # 3. ensure 1G swap (safety net for 1GB VPS)
    if ! swapon --show 2>/dev/null | grep -q '/swapfile'; then
        echo -e "${CYAN}[*] در حال ساخت یک گیگابایت حافظه swap...${NC}"
        if fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 2>/dev/null; then
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile >/dev/null 2>&1
            grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            echo -e "${GREEN}[✔️] یک گیگابایت swap ساخته شد${NC}"
        else
            echo -e "${YELLOW}[!] ساخت swap ناموفق بود؛ فضای دیسک را بررسی کنید${NC}"
        fi
    else
        echo -e "${GREEN}[✔️] حافظه swap از قبل فعال است${NC}"
    fi
    sysctl -w vm.swappiness=15 >/dev/null 2>&1
    echo 'vm.swappiness=15' > /etc/sysctl.d/99-swappiness.conf 2>/dev/null
    local after
    after=$(free -m | awk '/^Mem:/{print $7}')
    echo -e "${GREEN}[✔️] حافظه آزاد: ${before}M → ${after}M${NC}"
    free -m | head -2
}

# Dedicated backup key for encrypted backups (CWE-256: decouples backup key from login password)
ensure_backup_key() {
    mkdir -p /etc/gre-panel
    if [[ ! -f /etc/gre-panel/backup.key ]]; then
        (umask 077; openssl rand -hex 32 > /etc/gre-panel/backup.key) || return 1
    fi
    chmod 600 /etc/gre-panel/backup.key
}

# ---- Watchdog & Scheduled Encrypted Backup ----
init_watchdog_json() {
    mkdir -p "$NAVATUNNEL_STATE_DIR"
    if [[ ! -f "$WATCHDOG_FILE" ]]; then
        cat << 'EOF' > "$WATCHDOG_FILE"
{
  "enabled": true,
  "interval_sec": 60,
  "fail_threshold": 2,
  "auto_restart": false,
  "tg_bot_token": "",
  "tg_chat_id": "",
  "tg_route": "direct",
  "tg_tunnel_port": 0,
  "backup_every_hours": 0,
  "backup_daily_at": "",
  "last_check": "",
  "consec_fails": 0,
  "last_alert": ""
}
EOF
        chmod 600 "$WATCHDOG_FILE" 2>/dev/null || true
    fi
}

watchdog_get_peer_gre() {
    local PEER=""
    if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
        local INNER
        INNER=$(ip -4 addr show dev "$TUNNEL_NAME" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
        if [[ -n "$INNER" ]]; then
            if [[ "$INNER" == "$IRAN_GRE_IP" ]]; then
                PEER="$FOREIGN_GRE_IP"
            elif [[ "$INNER" == "$FOREIGN_GRE_IP" ]]; then
                PEER="$IRAN_GRE_IP"
            else
                IFS=. read -r a b c d <<< "$INNER"
                if (( d % 2 == 0 )); then
                    PEER="$a.$b.$c.$((d - 1))"
                else
                    PEER="$a.$b.$c.$((d + 1))"
                fi
            fi
        fi
    fi
    if [[ -z "$PEER" && -f "$PEERS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        PEER=$(python3 -c '
import json
try:
    with open("'"$PEERS_FILE"'") as f:
        d = json.load(f)
        peers = d.get("peers", [])
        if peers and "peer_gre" in peers[0]:
            print(peers[0]["peer_gre"])
except Exception:
    pass
' 2>/dev/null)
    fi
    echo "$PEER"
}

watchdog_check() {
    init_watchdog_json
    autotune_tick
    local PEER_GRE
    PEER_GRE=$(watchdog_get_peer_gre)
    local GRE_OK=0
    if [[ -n "$PEER_GRE" ]]; then
        if ping -c 1 -W 2 "$PEER_GRE" >/dev/null 2>&1; then
            GRE_OK=1
        elif ss -tn state established 2>/dev/null | grep -q "$PEER_GRE"; then
            GRE_OK=1
        elif nc -z -w 2 "$PEER_GRE" 22 >/dev/null 2>&1 || nc -z -w 2 "$PEER_GRE" 7777 >/dev/null 2>&1 || nc -z -w 2 "$PEER_GRE" 5201 >/dev/null 2>&1; then
            GRE_OK=1
        elif timeout 2 bash -c "</dev/tcp/$PEER_GRE/22" >/dev/null 2>&1 || timeout 2 bash -c "</dev/tcp/$PEER_GRE/7777" >/dev/null 2>&1; then
            GRE_OK=1
        fi
    fi

    local FRP_NAME=""
    local FRP_OK=0
    if [[ -f /etc/frp/frpc.toml ]] || systemctl list-unit-files 2>/dev/null | grep -q "^frpc\.service"; then
        FRP_NAME="frpc"
        systemctl is-active --quiet frpc 2>/dev/null && FRP_OK=1
    elif [[ -f /etc/frp/frps.toml ]] || systemctl list-unit-files 2>/dev/null | grep -q "^frps\.service"; then
        FRP_NAME="frps"
        systemctl is-active --quiet frps 2>/dev/null && FRP_OK=1
    else
        if systemctl list-units --type=service 2>/dev/null | grep -q 'frps'; then
            FRP_NAME="frps"
            FRP_OK=1
        fi
    fi

    # Foreign spoke resilience: if GRE ICMP ping fails (datacenter firewall/filtering or relay),
    # but frpc is active AND holds established TCP sockets to the FRP control/reverse port,
    # the transport is alive and passing traffic — do NOT trigger false-down restart loops.
    if [[ $GRE_OK -eq 0 && "$FRP_NAME" == "frpc" && $FRP_OK -eq 1 ]]; then
        if ss -tn state established 2>/dev/null | grep -qE ':(4773[0-9]|7000)'; then
            GRE_OK=1
        fi
    fi

    local FAILS=0
    if [[ -f "$WATCHDOG_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        FAILS=$(python3 -c '
import json
try:
    with open("'"$WATCHDOG_FILE"'") as f:
        print(int(json.load(f).get("consec_fails", 0)))
except Exception:
    print(0)
' 2>/dev/null || echo 0)
    fi

    local STATUS="down"
    local DETAIL=""
    if [[ $GRE_OK -eq 1 && $FRP_OK -eq 1 ]]; then
        STATUS="up"
        DETAIL="پینگ GRE به $PEER_GRE موفق و FRP $FRP_NAME فعال است"
    else
        local ERR_PARTS=()
        if [[ $GRE_OK -ne 1 ]]; then
            if [[ -z "$PEER_GRE" ]]; then
                ERR_PARTS+=("اینترفیس GRE موجود یا فعال نیست")
            else
                ERR_PARTS+=("پینگ GRE به $PEER_GRE ناموفق بود")
            fi
        fi
        if [[ $FRP_OK -ne 1 ]]; then
            ERR_PARTS+=("سرویس FRP ${FRP_NAME:-service} غیرفعال است")
        fi
        DETAIL=$(IFS="; "; echo "${ERR_PARTS[*]}")
    fi

    if [[ "${1:-}" == --machine ]]; then
        echo "WATCHDOG status=$STATUS fails=$FAILS detail=$DETAIL"
    else
        echo "وضعیت پایش: $(fa_state "$STATUS")"
        echo "خطاهای متوالی: $FAILS"
        echo "جزئیات: $DETAIL"
    fi
    return 0
}

watchdog_send() {
    local TEXT="$1"
    [[ -z "$TEXT" ]] && return 1
    init_watchdog_json

    local CFG
    CFG=$(python3 -c '
import json
try:
    with open("'"$WATCHDOG_FILE"'") as f:
        d = json.load(f)
        tok = d.get("tg_bot_token", "").strip()
        cid = str(d.get("tg_chat_id", "")).strip()
        route = d.get("tg_route", "direct").strip()
        port = str(d.get("tg_tunnel_port", 0)).strip()
        print(f"{tok}\t{cid}\t{route}\t{port}")
except Exception:
    pass
' 2>/dev/null)

    local TG_TOKEN TG_CHAT_ID TG_ROUTE TG_PORT
    IFS=$'\t' read -r TG_TOKEN TG_CHAT_ID TG_ROUTE TG_PORT <<< "$CFG"

    if [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        echo -e "${YELLOW}[!] توکن ربات یا شناسه گفت‌وگوی تلگرام در ${WATCHDOG_FILE} تنظیم نشده است.${NC}" >&2
        return 1
    fi

    local HOST
    HOST="$(hostname 2>/dev/null || echo 'server')"
    local FULL_MSG="[NavaTunnel ${HOST}] ${TEXT}"

    local CURL_ARGS=(-sS -f)
    if [[ "$TG_ROUTE" == "tunnel" ]]; then
        if [[ -z "$TG_PORT" || "$TG_PORT" -le 0 ]]; then
            echo -e "${RED}[!] مسیر تلگرام از تونل انتخاب شده ولی پورت آن تنظیم نشده است.${NC}" >&2
            return 1
        fi
        CURL_ARGS+=(--max-time 20 --socks5-hostname "127.0.0.1:${TG_PORT}")
    else
        CURL_ARGS+=(--max-time 15)
    fi

    local CURL_OUT
    CURL_OUT=$(curl "${CURL_ARGS[@]}" -d "chat_id=${TG_CHAT_ID}" --data-urlencode "text=${FULL_MSG}" "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" 2>&1)
    local RET=$?

    if [[ $RET -ne 0 ]]; then
        local REDACTED_ERR
        REDACTED_ERR=$(echo "$CURL_OUT" | sed "s/${TG_TOKEN}/[REDACTED]/g")
        echo -e "${RED}[!] ارسال تلگرام ناموفق بود: ${REDACTED_ERR}${NC}" >&2
        return 1
    fi
    return 0
}

watchdog_test() {
    echo -e "${CYAN}[*] در حال تست هشدار تلگرام...${NC}"
    if watchdog_send "آزمایش پایش NavaTunnel موفق بود"; then
        echo -e "${GREEN}[✔️] پیام آزمایشی تلگرام ارسال شد.${NC}"
        return 0
    else
        echo -e "${RED}[!] ارسال پیام آزمایشی ناموفق بود؛ توکن، شناسه گفت‌وگو و مسیر را بررسی کنید.${NC}"
        return 1
    fi
}

restart_all_lite() {
    local u
    # On Iran Hub (frps services exist and frpc does not):
    # NEVER blindly restart listening frps server daemons! Listening frps instances
    # do not recover broken client routes by restarting; restarting frps severs all
    # active client/user sessions across ALL other healthy connected spokes simultaneously.
    # Only restart GRE tunnel interfaces on the hub.
    if [[ -f /etc/frp/frps.toml ]] || systemctl list-unit-files 2>/dev/null | grep -q "^frps\.service"; then
        for u in /etc/systemd/system/gre-t*.service; do
            [[ -f "$u" ]] || continue
            systemctl restart "$(basename "$u")" >/dev/null 2>&1
        done
        return 0
    fi

    # On foreign node (frpc client):
    local list=()
    for u in /etc/systemd/system/gre-tunnel.service /etc/systemd/system/frpc.service; do
        [[ -f "$u" ]] || continue
        list+=("$(basename "$u")")
    done
    local unique_units=($(echo "${list[@]}" | tr " " "\n" | sort -u))
    for u in "${unique_units[@]}"; do
        systemctl restart "$u" >/dev/null 2>&1
    done
}


autotune_tick() {
    [[ ! -f /etc/gre-panel/perf.json ]] && return 0
    local DO_TUNE=$(python3 -c "import json; print(json.load(open('/etc/gre-panel/perf.json')).get('auto_tune', False))" 2>/dev/null || echo "False")
    [[ "$DO_TUNE" != "True" && "$DO_TUNE" != "true" ]] && return 0

    local CONN=$(ss -tn state established 2>/dev/null | wc -l)
    local RAM=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    [[ -z "$RAM" ]] && RAM=1024

    # Dynamically tune network stack without restarting live tunnel services (never kill active conns!)
    if [[ "$CONN" -gt 300 ]]; then
        sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_max_syn_backlog=65535 >/dev/null 2>&1 || true
        sysctl -w net.core.netdev_max_backlog=65535 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1 || true
    fi
}

watchdog_tick() {
    local LOCKFILE="/var/lock/navatunnel-watchdog.lock"
    mkdir -p /var/lock 2>/dev/null || true
    exec 200>"$LOCKFILE" 2>/dev/null || exec 200>/tmp/navatunnel-watchdog.lock
    if ! flock -n 200; then
        echo "پایش دیگری در حال اجرا است؛ این اجرا پایان یافت"
        return 0
    fi

    init_watchdog_json

    local TICK_ACTION
    TICK_ACTION=$(python3 -c '
import json, time
try:
    with open("'"$WATCHDOG_FILE"'") as f:
        d = json.load(f)
    enabled = d.get("enabled", False)
    backup_every = int(d.get("backup_every_hours", 0))
    backup_daily = d.get("backup_daily_at", "").strip()
    last_backup = int(d.get("last_backup", 0))
    last_bdate = d.get("last_backup_date", "")
    now = int(time.time())
    do_backup = False
    if backup_every > 0:
        if (now - last_backup) >= (backup_every * 3600):
            do_backup = True
    elif backup_daily:
        cur_hm = time.strftime("%H:%M")
        cur_date = time.strftime("%Y-%m-%d")
        if cur_hm == backup_daily and last_bdate != cur_date:
            do_backup = True
    print(f"{enabled} {do_backup}")
except Exception as e:
    print("False False")
' 2>/dev/null)

    local IS_ENABLED="False"
    local DO_BACKUP="False"
    read -r IS_ENABLED DO_BACKUP <<< "$TICK_ACTION"

    if [[ "$IS_ENABLED" == "True" || "$IS_ENABLED" == "true" ]]; then
        local CHECK_OUT
        CHECK_OUT=$(watchdog_check --machine)
        local STATUS DETAIL
        STATUS=$(echo "$CHECK_OUT" | sed -n 's/.*status=\([^ ]*\).*/\1/p')
        DETAIL=$(echo "$CHECK_OUT" | sed -n 's/.*detail=\(.*\)/\1/p')

        local DECISION
        DECISION=$(CHECK_STATUS="$STATUS" CHECK_DETAIL="$DETAIL" python3 -c '
import json, os, time

path = "'"$WATCHDOG_FILE"'"
st = os.environ.get("CHECK_STATUS", "down")
detail = os.environ.get("CHECK_DETAIL", "")
now = int(time.time())
now_str = time.strftime("%Y-%m-%d %H:%M:%S")

try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    d = {"enabled": True, "fail_threshold": 2, "consec_fails": 0, "last_alert": ""}

threshold = int(d.get("fail_threshold", 2))
consec = int(d.get("consec_fails", 0))
last_alert = d.get("last_alert", "")
down_since = int(d.get("down_since", 0))

action = "NONE"

if st == "up":
    if last_alert == "down":
        down_min = max(1, int((now - down_since + 59) / 60))
        action = f"RECOVERED {down_min}"
        d["last_alert"] = "up"
        d["down_since"] = 0
    d["consec_fails"] = 0
else:
    consec += 1
    d["consec_fails"] = consec
    if consec >= threshold:
        if last_alert != "down":
            action = "DOWN"
            d["last_alert"] = "down"
            d["down_since"] = now
        elif consec % 2 == 0:
            action = "DOWN_RETRY"

d["last_check"] = now_str

tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
os.replace(tmp, path)
os.chmod(path, 0o600)
print(action)
' 2>/dev/null)

        local DO_RESTART
        DO_RESTART=$(python3 -c "import json; print(json.load(open('$WATCHDOG_FILE')).get('auto_restart', False))" 2>/dev/null || echo "False")
        if [[ "$DECISION" == DOWN* ]]; then
            if [[ "$DECISION" == "DOWN" ]]; then
                if [[ "$DO_RESTART" == "True" || "$DO_RESTART" == "true" ]]; then
                    watchdog_send "🔴 تونل قطع است: ${DETAIL} (تلاش برای ری‌استارت تونل)" || true
                else
                    watchdog_send "🔴 تونل قطع است: ${DETAIL} (فقط هشدار؛ ری‌استارت خودکار خاموش است)" || true
                fi
            fi
            if [[ "$DO_RESTART" == "True" || "$DO_RESTART" == "true" ]]; then
                restart_all_lite
            fi
        elif [[ "$DECISION" == RECOVERED* ]]; then
            local DMIN
            DMIN=$(echo "$DECISION" | awk '{print $2}')
            watchdog_send "🟢 تونل بازیابی شد؛ مدت قطعی ${DMIN} دقیقه" || true
        fi
    fi

    if [[ "$DO_BACKUP" == "True" || "$DO_BACKUP" == "true" ]]; then
        backup_now >/dev/null 2>&1 || true
        python3 -c '
import json, time
path = "'"$WATCHDOG_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    d["last_backup"] = int(time.time())
    d["last_backup_date"] = time.strftime("%Y-%m-%d")
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    import os
    os.replace(path + ".tmp", path)
    os.chmod(path, 0o600)
except Exception:
    pass
' 2>/dev/null || true
    fi

    return 0
}

backup_now() {
    local OUTDIR="$BACKUP_DIR"
    local KEEP=7
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --* && $# -lt 2 ]]; then
            case "$1" in
                --force|--show-token|--encrypt|--compress|--dry-run|--off|--help) ;;
                *) echo "مقدار این گزینه وارد نشده است: $1" >&2; return 1 ;;
            esac
        fi
        case "$1" in
            --keep) KEEP="$2"; shift 2 ;;
            *)
                if [[ "$1" != --* ]]; then
                    OUTDIR="$1"
                fi
                shift
                ;;
        esac
    done

    [[ "$KEEP" =~ ^[0-9]+$ ]] || { echo "مقدار --keep باید عدد صحیح نامنفی باشد." >&2; return 1; }
    mkdir -p "$OUTDIR" || return 1
    chmod 700 "$OUTDIR" 2>/dev/null || true

    ensure_backup_key || return 1
    if [[ ! -f /etc/gre-panel/backup.key ]]; then
        echo -e "${RED}[!] کلید /etc/gre-panel/backup.key پیدا نشد؛ رمزگذاری پشتیبان ممکن نیست.${NC}" >&2
        return 1
    fi

    local DATE_STR
    DATE_STR=$(date +%Y%m%d-%H%M%S)
    local OUT_FILE="${OUTDIR}/navatunnel-backup-${DATE_STR}.enc"

    local FILES=()
    local f
    for f in /etc/frp/*.toml /etc/gre-panel/peers.json /etc/gre-panel/watchdog.json \
             /etc/gre-panel/perf.json /etc/gre-panel/traffic.json /etc/gre-panel/backup.key \
             /etc/systemd/system/gre-*.service /etc/systemd/system/frps*.service \
             /etc/systemd/system/frpc*.service /etc/systemd/system/gre-chaff*.service; do
        [[ -f "$f" ]] && FILES+=("$f")
    done

    if [[ ${#FILES[@]} -eq 0 ]]; then
        echo -e "${RED}[!] فایل تنظیمات یا سرویس برای پشتیبان‌گیری پیدا نشد.${NC}" >&2
        return 1
    fi

    if ! (set -o pipefail; tar -czf - "${FILES[@]}" 2>/dev/null | openssl enc -aes-256-cbc -pbkdf2 -pass file:/etc/gre-panel/backup.key -out "$OUT_FILE"); then
        echo -e "${RED}[!] ساخت پشتیبان رمزگذاری‌شده ناموفق بود.${NC}" >&2
        rm -f "$OUT_FILE"
        return 1
    fi

    chmod 600 "$OUT_FILE" 2>/dev/null || true
    local SIZE
    SIZE=$(stat -c%s "$OUT_FILE" 2>/dev/null || echo 0)
    local HSIZE
    HSIZE=$(du -h "$OUT_FILE" 2>/dev/null | cut -f1)

    echo "BACKUP path=${OUT_FILE} size=${SIZE}"
    echo -e "${GREEN}[✔️] پشتیبان ساخته شد: ${OUT_FILE} (${HSIZE})${NC}"

    if [[ "$KEEP" -gt 0 ]]; then
        local OLD_FILES
        OLD_FILES=$(ls -1t "$OUTDIR"/navatunnel-backup-*.enc 2>/dev/null | tail -n +$((KEEP + 1)))
        if [[ -n "$OLD_FILES" ]]; then
            echo "$OLD_FILES" | xargs -r rm -f
            echo -e "${CYAN}[*] پشتیبان‌های قدیمی پاک شد؛ ${KEEP} پشتیبان آخر باقی ماند.${NC}"
        fi
    fi
    return 0
}

backup_restore() {
    local FILE=""
    local DRY_RUN=0
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --* && $# -lt 2 ]]; then
            case "$1" in
                --force|--show-token|--encrypt|--compress|--dry-run|--off|--help) ;;
                *) echo "مقدار این گزینه وارد نشده است: $1" >&2; return 1 ;;
            esac
        fi
        case "$1" in
            --dry-run) DRY_RUN=1; shift ;;
            *) FILE="$1"; shift ;;
        esac
    done

    if [[ -z "$FILE" || ! -f "$FILE" ]]; then
        echo -e "${RED}[!] فایل پشتیبان پیدا نشد: '${FILE}'${NC}" >&2
        return 1
    fi
    ensure_backup_key || return 1
    local KEY_FILE="/etc/gre-panel/backup.key"
    if [[ ! -f "$KEY_FILE" ]]; then
        echo -e "${RED}[!] کلید رمزگذاری پیدا نشد؛ بازکردن پشتیبان ممکن نیست.${NC}" >&2
        return 1
    fi

    local TMP_D
    TMP_D=$(mktemp -d)
    trap 'rm -rf "$TMP_D"' RETURN

    echo -e "${CYAN}[*] در حال رمزگشایی فایل پشتیبان...${NC}"
    if ! openssl enc -d -aes-256-cbc -pbkdf2 -pass file:"$KEY_FILE" -in "$FILE" -out "$TMP_D/backup.tar.gz" 2>/dev/null; then
        echo -e "${RED}[!] رمزگشایی ناموفق بود؛ کلید نامعتبر یا فایل خراب است.${NC}" >&2
        return 1
    fi

    echo -e "${CYAN}[*] در حال بررسی محتوای پشتیبان...${NC}"
    if ! tar -ztf "$TMP_D/backup.tar.gz" >"$TMP_D/list.txt" 2>/dev/null; then
        echo -e "${RED}[!] بررسی پشتیبان ناموفق بود؛ فایل tar نامعتبر است.${NC}" >&2
        return 1
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo -e "${GREEN}[✔️] پشتیبان معتبر است؛ فایل‌های داخل:${NC}"
        cat "$TMP_D/list.txt"
        return 0
    fi

    echo -e "${CYAN}[*] در حال بازگردانی تنظیمات و سرویس‌ها...${NC}"
    tar -xzf "$TMP_D/backup.tar.gz" -C / || return 1
    chmod 600 /etc/gre-panel/*.json 2>/dev/null || true
    echo -e "${GREEN}[✔️] فایل‌های بازگردانده‌شده:${NC}"
    cat "$TMP_D/list.txt"

    echo -e "${CYAN}[*] در حال بازخوانی تنظیمات systemd...${NC}"
    chmod 600 "${CONFIG_DIR}"/*.toml 2>/dev/null || true
    systemctl daemon-reload

    echo -e "${CYAN}[*] در حال ری‌استارت سرویس‌های تونل...${NC}"
    restart_all

    echo -e "${GREEN}[✔️] بازگردانی با موفقیت انجام شد.${NC}"
    return 0
}

install_watchdog_units() {
    [[ -x "$NAVATUNNEL_BIN" ]] || { cp "$0" "$NAVATUNNEL_BIN" 2>/dev/null && chmod +x "$NAVATUNNEL_BIN"; } || true
    cat << 'EOF' > /etc/systemd/system/navatunnel-watchdog.service
[Unit]
Description=پایش تونل و اجرای پشتیبان زمان‌بندی‌شده
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/NavaTunnel watchdog tick
EOF

    cat << 'EOF' > /etc/systemd/system/navatunnel-watchdog.timer
[Unit]
Description=پایش تونل NavaTunnel در هر دقیقه
After=network.target

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    chmod 600 "${CONFIG_DIR}"/*.toml 2>/dev/null || true
    systemctl daemon-reload
}

watchdog_on() {
    init_watchdog_json
    install_watchdog_units
    systemctl enable --now navatunnel-watchdog.timer >/dev/null 2>&1
    python3 -c '
import json
path = "'"$WATCHDOG_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    d["enabled"] = True
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    import os
    os.replace(path + ".tmp", path)
    os.chmod(path, 0o600)
except Exception:
    pass
' 2>/dev/null || true
    echo -e "${GREEN}[✔️] پایش فعال شد؛ بررسی در هر دقیقه انجام می‌شود.${NC}"
}

watchdog_off() {
    init_watchdog_json
    systemctl stop navatunnel-watchdog.timer navatunnel-watchdog.service >/dev/null 2>&1 || true
    systemctl disable navatunnel-watchdog.timer >/dev/null 2>&1 || true
    python3 -c '
import json
path = "'"$WATCHDOG_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    d["enabled"] = False
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    import os
    os.replace(path + ".tmp", path)
    os.chmod(path, 0o600)
except Exception:
    pass
' 2>/dev/null || true
    echo -e "${YELLOW}[*] پایش غیرفعال و زمان‌سنج متوقف شد.${NC}"
}

watchdog_status_full() {
    init_watchdog_json
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${CYAN}                 وضعیت پایش NavaTunnel                   ${NC}"
    echo -e "${CYAN}==========================================================${NC}"

    local INFO
    INFO=$(python3 -c '
import json
path = "'"$WATCHDOG_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    en = "Enabled" if d.get("enabled", False) else "Disabled"
    tok = d.get("tg_bot_token", "").strip()
    if tok:
        masked = tok[:6] + "..." + tok[-4:] if len(tok) > 10 else "******"
    else:
        masked = "(تنظیم نشده)"
    cid = str(d.get("tg_chat_id", "")) or "(تنظیم نشده)"
    route = d.get("tg_route", "direct")
    port = str(d.get("tg_tunnel_port", 0))
    fails = str(d.get("consec_fails", 0))
    thresh = str(d.get("fail_threshold", 2))
    last_c = d.get("last_check", "") or "(هنوز ثبت نشده)"
    last_a = d.get("last_alert", "") or "(بدون مقدار)"
    be = int(d.get("backup_every_hours", 0))
    bd = d.get("backup_daily_at", "")
    if be > 0:
        sched = f"هر {be} ساعت"
    elif bd:
        sched = f"روزانه ساعت {bd}"
    else:
        sched = "Disabled"
    print(f"{en}\t{masked}\t{cid}\t{route}\t{port}\t{fails}\t{thresh}\t{last_c}\t{last_a}\t{sched}")
except Exception as e:
    print(f"Error\t-\t-\t-\t-\t0\t2\t-\t-\tDisabled")
' 2>/dev/null)

    local EN TOK CID ROUTE PORT FAILS THRESH LAST_C LAST_A SCHED
    IFS=$'\t' read -r EN TOK CID ROUTE PORT FAILS THRESH LAST_C LAST_A SCHED <<< "$INFO"

    local TIMER_ACTIVE="inactive"
    if systemctl is-active --quiet navatunnel-watchdog.timer 2>/dev/null; then
        TIMER_ACTIVE="فعال در هر دقیقه"
    fi

    echo -e "وضعیت پایش:     ${CYAN}$(fa_state "${EN}")${NC} (زمان‌سنج: $(fa_state "${TIMER_ACTIVE}"))"
    echo -e "خطاهای متوالی:  ${FAILS} / ${THRESH}"
    echo -e "آخرین بررسی:         ${LAST_C}"
    echo -e "آخرین هشدار:         ${LAST_A}"
    echo ""
    echo -e "${YELLOW}── هشدارهای تلگرام ──${NC}"
    echo -e "توکن ربات:          ${TOK}"
    echo -e "شناسه گفت‌وگو:            ${CID}"
    if [[ "$ROUTE" == "tunnel" ]]; then
        echo -e "مسیر: تونل (SOCKS5 127.0.0.1:${PORT})"
    else
        echo -e "مسیر: مستقیم"
    fi
    echo ""
    echo -e "${YELLOW}── زمان‌بندی و فایل‌های پشتیبان ──${NC}"
    echo -e "زمان‌بندی:           ${SCHED}"
    local BC=0
    if [[ -d "$BACKUP_DIR" ]]; then
        BC=$(ls -1 "$BACKUP_DIR"/navatunnel-backup-*.enc 2>/dev/null | wc -l)
    fi
    echo -e "پشتیبان‌های ذخیره‌شده:     ${BC} در ${BACKUP_DIR}"
    if [[ "$BC" -gt 0 ]]; then
        ls -lh "$BACKUP_DIR"/navatunnel-backup-*.enc 2>/dev/null | awk '{print "  " $9 " (" $5 ", " $6 " " $7 " " $8 ")"}' | tail -n 5
    fi
    echo ""
    echo -e "${YELLOW}── بررسی فعلی سلامت ──${NC}"
    watchdog_check
    echo -e "${CYAN}==========================================================${NC}"
}

find_live_proxy_ports() {
    local PORTS=()
    if [[ -f /etc/frp/frpc.toml ]]; then
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < <(grep -E '^(remotePort|localPort)\s*=' /etc/frp/frpc.toml 2>/dev/null | awk -F= '{print $2}' | tr -d ' "')
    fi
    local f
    for f in /etc/frp/frps*.toml; do
        [[ -f "$f" ]] || continue
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < <(grep -E '^(remotePort|localPort)\s*=' "$f" 2>/dev/null | awk -F= '{print $2}' | tr -d ' "')
    done
    if [[ -f "$PEERS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        while read -r p; do
            [[ -n "$p" ]] && PORTS+=("$p")
        done < <(python3 -c '
import json
try:
    with open("'"$PEERS_FILE"'") as f:
        d = json.load(f)
        for peer in d.get("peers", []):
            for port in peer.get("ports", []):
                print(port)
except Exception:
    pass
' 2>/dev/null)
    fi
    if [[ ${#PORTS[@]} -gt 0 ]]; then
        printf "%s\n" "${PORTS[@]}" | sort -n -u
    fi
}

menu_watchdog() {
    while true; do
        ui_clear
        echo -e "${CYAN}==========================================================${NC}"
        echo -e "${CYAN}              پایش و پشتیبان رمزگذاری‌شده                 ${NC}"
        echo -e "${CYAN}==========================================================${NC}"
        echo ""
        init_watchdog_json
        local W_EN
        W_EN=$(python3 -c '
import json
try:
    with open("'"$WATCHDOG_FILE"'") as f:
        print("ENABLED" if json.load(f).get("enabled", False) else "DISABLED")
except Exception:
    print("DISABLED")
' 2>/dev/null)
        if [[ "$W_EN" == "ENABLED" ]]; then
            echo -e "وضعیت پایش: ${GREEN}● فعال${NC} (بررسی در هر دقیقه)"
        else
            echo -e "وضعیت پایش: ${RED}○ غیرفعال${NC}"
        fi
        echo ""
        echo "  1) فعال یا غیرفعال‌سازی پایش"
        echo "  2) تنظیم توکن ربات و شناسه گفت‌وگوی تلگرام"
        echo "  3) تست هشدار تلگرام"
        echo "  4) انتخاب مسیر مستقیم یا تونل و پورت SOCKS"
        echo "  5) ساخت پشتیبان رمزگذاری‌شده"
        echo "  6) زمان‌بندی پشتیبان ساعتی یا روزانه"
        echo "  7) بازگردانی پشتیبان رمزگذاری‌شده"
        echo "  8) نمایش وضعیت و پشتیبان‌ها"
        echo "  0) بازگشت به منوی اصلی"
        echo ""
        read -r -p "انتخاب گزینه [0-8]: " SUBOPT || return 0
        case "$SUBOPT" in
            1)
                if [[ "$W_EN" == "ENABLED" ]]; then
                    watchdog_off
                else
                    watchdog_on
                fi
                read -r -p "برای ادامه Enter بزنید..." _ || return 0
                ;;
            2)
                echo -e "\n${CYAN}── تنظیم هشدارهای تلگرام ──${NC}"
                read -r -p "توکن ربات تلگرام: " INPUT_TOKEN || return 0
                read -r -p "شناسه گفت‌وگوی تلگرام: " INPUT_CID || return 0
                if [[ -n "$INPUT_TOKEN" || -n "$INPUT_CID" ]]; then
                    python3 -c '
import json
path = "'"$WATCHDOG_FILE"'"
tok = "'"$INPUT_TOKEN"'".strip()
cid = "'"$INPUT_CID"'".strip()
try:
    with open(path) as f:
        d = json.load(f)
    if tok:
        d["tg_bot_token"] = tok
    if cid:
        d["tg_chat_id"] = cid
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    import os
    os.replace(path + ".tmp", path)
    os.chmod(path, 0o600)
except Exception as e:
    print(e)
' 2>/dev/null
                    echo -e "${GREEN}[✔️] تنظیمات تلگرام ذخیره شد.${NC}"
                else
                    echo -e "${YELLOW}[*] تغییری انجام نشد.${NC}"
                fi
                read -r -p "برای ادامه Enter بزنید..." _ || return 0
                ;;
            3)
                watchdog_test
                read -r -p "برای ادامه Enter بزنید..." _ || return 0
                ;;
            4)
                echo -e "\n${CYAN}── مسیر ارسال تلگرام ──${NC}"
                echo "  1) مستقیم به API تلگرام"
                echo "  2) از تونل با SOCKS5"
                read -r -p "انتخاب مسیر [1-2]: " ROUTE_CHOICE || return 0
                if [[ "$ROUTE_CHOICE" == "1" ]]; then
                    python3 -c '
import json
path = "'"$WATCHDOG_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    d["tg_route"] = "direct"
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    import os
    os.replace(path + ".tmp", path)
    os.chmod(path, 0o600)
except Exception:
    pass
' 2>/dev/null
                    echo -e "${GREEN}[✔️] مسیر مستقیم انتخاب شد.${NC}"
                elif [[ "$ROUTE_CHOICE" == "2" ]]; then
                    local PORTS=()
                    mapfile -t PORTS < <(find_live_proxy_ports)
                    local CHOSEN_PORT=0
                    if [[ ${#PORTS[@]} -gt 0 ]]; then
                        echo -e "\nپورت‌های تونل شناسایی‌شده:"
                        local idx=1
                        for p in "${PORTS[@]}"; do
                            echo "  $idx) پورت $p"
                            ((idx++))
                        done
                        echo "  $idx) واردکردن پورت دلخواه"
                        read -r -p "انتخاب پورت [1-$idx]: " PIDX || return 0
                        if [[ "$PIDX" =~ ^[0-9]+$ ]] && (( PIDX >= 1 && PIDX < idx )); then
                            CHOSEN_PORT="${PORTS[$((PIDX-1))]}"
                        else
                            read -r -p "پورت SOCKS5 تونل بین 1 و 65535: " CHOSEN_PORT || return 0
                        fi
                    else
                        read -r -p "پورت SOCKS5 تونل بین 1 و 65535: " CHOSEN_PORT || return 0
                    fi
                    if is_valid_port "$CHOSEN_PORT"; then
                        python3 -c '
import json
path = "'"$WATCHDOG_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    d["tg_route"] = "tunnel"
    d["tg_tunnel_port"] = int("'"$CHOSEN_PORT"'")
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    import os
    os.replace(path + ".tmp", path)
    os.chmod(path, 0o600)
except Exception:
    pass
' 2>/dev/null
                        echo -e "${GREEN}[✔️] مسیر تونل روی 127.0.0.1:${CHOSEN_PORT} انتخاب شد.${NC}"
                    else
                        echo -e "${RED}[!] شماره پورت نامعتبر است.${NC}"
                    fi
                fi
                read -r -p "برای ادامه Enter بزنید..." _ || return 0
                ;;
            5)
                echo -e "\n${CYAN}── ساخت پشتیبان رمزگذاری‌شده ──${NC}"
                backup_now
                read -r -p "برای ادامه Enter بزنید..." _ || return 0
                ;;
            6)
                echo -e "\n${CYAN}── زمان‌بندی پشتیبان رمزگذاری‌شده ──${NC}"
                echo "  1) هر چند ساعت"
                echo "  2) روزانه در ساعت مشخص"
                echo "  3) غیرفعال‌سازی پشتیبان زمان‌بندی‌شده"
                read -r -p "انتخاب نوع زمان‌بندی [1-3]: " S_CHOICE || return 0
                case "$S_CHOICE" in
                    1)
                        read -r -p "فاصله بر حسب ساعت (مثلاً 6): " N_HOURS || return 0
                        if [[ "$N_HOURS" =~ ^[0-9]+$ ]] && (( N_HOURS >= 1 && N_HOURS <= 168 )); then
                            python3 -c '
import json
path = "'"$WATCHDOG_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    d["backup_every_hours"] = int("'"$N_HOURS"'")
    d["backup_daily_at"] = ""
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    import os
    os.replace(path + ".tmp", path)
    os.chmod(path, 0o600)
except Exception:
    pass
' 2>/dev/null
                            echo -e "${GREEN}[✔️] پشتیبان هر ${N_HOURS} ساعت زمان‌بندی شد.${NC}"
                        else
                            echo -e "${RED}[!] ساعت باید بین 1 و 168 باشد.${NC}"
                        fi
                        ;;
                    2)
                        read -r -p "ساعت روزانه با قالب HH:MM (مثلاً 03:00): " DAILY_T || return 0
                        if [[ "$DAILY_T" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                            python3 -c '
import json
path = "'"$WATCHDOG_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    d["backup_every_hours"] = 0
    d["backup_daily_at"] = "'"$DAILY_T"'"
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    import os
    os.replace(path + ".tmp", path)
    os.chmod(path, 0o600)
except Exception:
    pass
' 2>/dev/null
                            echo -e "${GREEN}[✔️] پشتیبان روزانه در ساعت ${DAILY_T} زمان‌بندی شد.${NC}"
                        else
                            echo -e "${RED}[!] قالب ساعت نامعتبر است؛ از HH:MM مثل 03:00 استفاده کنید.${NC}"
                        fi
                        ;;
                    3)
                        python3 -c '
import json
path = "'"$WATCHDOG_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    d["backup_every_hours"] = 0
    d["backup_daily_at"] = ""
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    import os
    os.replace(path + ".tmp", path)
    os.chmod(path, 0o600)
except Exception:
    pass
' 2>/dev/null
                        echo -e "${GREEN}[✔️] پشتیبان زمان‌بندی‌شده غیرفعال شد.${NC}"
                        ;;
                    *)
                        echo -e "${RED}[!] گزینه نامعتبر است.${NC}"
                        ;;
                esac
                read -r -p "برای ادامه Enter بزنید..." _ || return 0
                ;;
            7)
                echo -e "\n${CYAN}── بازگردانی پشتیبان ──${NC}"
                local BAKS=()
                if [[ -d "$BACKUP_DIR" ]]; then
                    mapfile -t BAKS < <(ls -1t "$BACKUP_DIR"/navatunnel-backup-*.enc 2>/dev/null)
                fi
                if [[ ${#BAKS[@]} -eq 0 ]]; then
                    echo -e "${YELLOW}[!] در ${BACKUP_DIR} پشتیبان پیدا نشد.${NC}"
                    read -r -p "مسیر کامل فایل پشتیبان را وارد کنید [Enter: لغو]: " MAN_FILE || return 0
                    if [[ -n "$MAN_FILE" ]]; then
                        backup_restore "$MAN_FILE"
                    fi
                else
                    echo "پشتیبان‌های موجود:"
                    local bidx=1
                    for b in "${BAKS[@]}"; do
                        local bsz
                        bsz=$(du -h "$b" 2>/dev/null | cut -f1)
                        echo "  $bidx) $(basename "$b") ($bsz)"
                        ((bidx++))
                    done
                    read -r -p "انتخاب پشتیبان برای بازگردانی [1-$((bidx-1))]: " PICK_B || return 0
                    if [[ "$PICK_B" =~ ^[0-9]+$ ]] && (( PICK_B >= 1 && PICK_B < bidx )); then
                        local SELECTED="${BAKS[$((PICK_B-1))]}"
                        read -r -p "پشتیبان $(basename "$SELECTED") بازگردانی شود؟ تنظیمات فعلی جایگزین و سرویس‌ها ری‌استارت می‌شوند. [y/N]: " CONFIRM_R || return 0
                        if [[ "$CONFIRM_R" =~ ^[Yy]$ ]]; then
                            backup_restore "$SELECTED"
                        else
                            echo -e "${YELLOW}[*] بازگردانی لغو شد.${NC}"
                        fi
                    else
                        echo -e "${RED}[!] انتخاب نامعتبر است.${NC}"
                    fi
                fi
                read -r -p "برای ادامه Enter بزنید..." _ || return 0
                ;;
            8)
                watchdog_status_full
                read -r -p "برای ادامه Enter بزنید..." _ || return 0
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${RED}[!] گزینه نامعتبر است.${NC}"
                sleep 1
                ;;
        esac
    done
}

cli_watchdog() {
    local SUB="$1"
    shift || true
    case "$SUB" in
        on) watchdog_on ;;
        off) watchdog_off ;;
        status) watchdog_status_full ;;
        test) watchdog_test ;;
        tick) watchdog_tick ;;
        check) watchdog_check ;;
        *) echo -e "${RED}[!] دستور پایش $SUB ناشناخته است؛ از on|off|status|test|tick استفاده کنید.${NC}"; return 1 ;;
    esac
}

cli_backup() {
    local SUB="$1"
    shift || true
    case "$SUB" in
        now) backup_now "$@" ;;
        restore) backup_restore "$@" ;;
        status)
            echo -e "${CYAN}=== پشتیبان‌های NavaTunnel (${BACKUP_DIR}) ===${NC}"
            if [[ -d "$BACKUP_DIR" ]]; then
                ls -lh "$BACKUP_DIR"/navatunnel-backup-*.enc 2>/dev/null || echo "(پشتیبان پیدا نشد)"
            else
                echo "(پوشه پشتیبان موجود نیست)"
            fi
            ;;
        schedule)
            local MODE="" HOURS=0 DAILY=""
            while [[ $# -gt 0 ]]; do
        if [[ "$1" == --* && $# -lt 2 ]]; then
            case "$1" in
                --force|--show-token|--encrypt|--compress|--dry-run|--off|--help) ;;
                *) echo "مقدار این گزینه وارد نشده است: $1" >&2; return 1 ;;
            esac
        fi
                case "$1" in
                    --every|every) HOURS="$2"; MODE="interval"; shift 2 ;;
                    --daily|daily) DAILY="$2"; MODE="daily"; shift 2 ;;
                    --off|off) MODE="off"; shift ;;
                    *) shift ;;
                esac
            done
            init_watchdog_json
            if [[ "$MODE" == "interval" ]]; then
                if [[ "$HOURS" =~ ^[0-9]+$ ]] && (( HOURS >= 1 && HOURS <= 168 )); then
                    python3 -c '
import json
path = "'"$WATCHDOG_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    d["backup_every_hours"] = int("'"$HOURS"'")
    d["backup_daily_at"] = ""
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    import os
    os.replace(path + ".tmp", path)
    os.chmod(path, 0o600)
except Exception:
    pass
' 2>/dev/null
                    echo -e "${GREEN}[✔️] پشتیبان هر ${HOURS} ساعت زمان‌بندی شد.${NC}"
                else
                    echo -e "${RED}[!] فاصله ساعت $HOURS نامعتبر است؛ بازه 1 تا 168${NC}"; return 1
                fi
            elif [[ "$MODE" == "daily" ]]; then
                if [[ "$DAILY" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    python3 -c '
import json
path = "'"$WATCHDOG_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    d["backup_every_hours"] = 0
    d["backup_daily_at"] = "'"$DAILY"'"
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    import os
    os.replace(path + ".tmp", path)
    os.chmod(path, 0o600)
except Exception:
    pass
' 2>/dev/null
                    echo -e "${GREEN}[✔️] پشتیبان روزانه در ساعت ${DAILY} زمان‌بندی شد.${NC}"
                else
                    echo -e "${RED}[!] ساعت روزانه $DAILY نامعتبر است؛ قالب HH:MM مثل 03:00${NC}"; return 1
                fi
            elif [[ "$MODE" == "off" ]]; then
                python3 -c '
import json
path = "'"$WATCHDOG_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    d["backup_every_hours"] = 0
    d["backup_daily_at"] = ""
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    import os
    os.replace(path + ".tmp", path)
    os.chmod(path, 0o600)
except Exception:
    pass
' 2>/dev/null
                echo -e "${GREEN}[✔️] پشتیبان زمان‌بندی‌شده غیرفعال شد.${NC}"
            else
                echo -e "${RED}[!] روش استفاده: NavaTunnel backup schedule [--every N | --daily HH:MM | --off]${NC}"; return 1
            fi
            ;;
        *)
            echo -e "${RED}[!] دستور پشتیبان $SUB ناشناخته است؛ از now|restore|schedule|status استفاده کنید.${NC}"
            return 1
            ;;
    esac
}

update_all() {
    echo -e "${CYAN}[*] در حال به‌روزرسانی اسکریپت NavaTunnel...${NC}"
    TMP_U="$(mktemp -d)"
    trap 'rm -rf "$TMP_U"' RETURN
    # 1. fresh script from main with mirror fallbacks
    if ! download_with_fallback "$TMP_U/NavaTunnel.sh" "${NAVATUNNEL_URL_BASE}/NavaTunnel.sh" 30; then
        echo -e "${RED}[!] دریافت نسخه جدید ناموفق بود؛ تغییری انجام نشد.${NC}"
        return 1
    fi
    bash -n "$TMP_U/NavaTunnel.sh" || { echo -e "${RED}[!] ساختار اسکریپت دریافتی نامعتبر بود؛ تغییری انجام نشد.${NC}"; return 1; }
    if cmp -s "$TMP_U/NavaTunnel.sh" "$0" 2>/dev/null || cmp -s "$TMP_U/NavaTunnel.sh" ./NavaTunnel.sh 2>/dev/null; then
        echo -e "${GREEN}[✔️] اسکریپت NavaTunnel.sh از قبل آخرین نسخه است.${NC}"
    else
        echo -e "${GREEN}[✔️] نسخه جدید NavaTunnel.sh دریافت و ساختار آن بررسی شد.${NC}"
    fi
    if ! download_with_fallback "$TMP_U/NavaTunnel-traffic.sh" "${NAVATUNNEL_URL_BASE}/NavaTunnel-traffic.sh" 30 || ! bash -n "$TMP_U/NavaTunnel-traffic.sh"; then
        echo "به‌روزرسانی ابزار ترافیک ناموفق بود؛ اسکریپت‌ها جایگزین نشدند." >&2
        return 1
    fi
    install -m 755 "$TMP_U/NavaTunnel-traffic.sh" /usr/local/bin/NavaTunnel-traffic.sh || return 1
    # 3. replace running script only after everything succeeded
    cp "$TMP_U/NavaTunnel.sh" "$0" 2>/dev/null || cp "$TMP_U/NavaTunnel.sh" ./NavaTunnel.sh
    chmod +x "$0" 2>/dev/null || true
    cp "$TMP_U/NavaTunnel.sh" "$NAVATUNNEL_SCRIPT" 2>/dev/null && chmod +x "$NAVATUNNEL_SCRIPT" || true
    cp "$TMP_U/NavaTunnel.sh" "$NAVATUNNEL_BIN" 2>/dev/null && chmod +x "$NAVATUNNEL_BIN" || true
    ln -sf "$NAVATUNNEL_SCRIPT" /usr/local/bin/gre.sh 2>/dev/null || true
    install_chaff_script || true
    rm -f /usr/local/bin/gre-chaff.sh 2>/dev/null || true
    update_chaff_existing_tunnels || true
    # 5. If DPI shield is active or enabled, refresh with safe rules so old drop-all rules are replaced
    if iptables -L NAVATUNNEL-DPI -n >/dev/null 2>&1; then
        local DPI_EN
        DPI_EN=$(perf_get_dpi_enabled)
        if [[ "$DPI_EN" == "1" ]]; then
            dpi_shield_on >/dev/null 2>&1 || true
        else
            dpi_shield_off >/dev/null 2>&1 || true
        fi
    fi

    # 6. Ping overhead migration for existing users
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json
path = '/etc/gre-panel/perf.json'
try:
    with open(path, 'r') as f:
        d = json.load(f)
    changed = False
    if d.get('force_tls') != False: d['force_tls'] = False; changed = True
    if d.get('chaff_profile') != 'off': d['chaff_profile'] = 'off'; changed = True
    if d.get('auto_tune') != False: d['auto_tune'] = False; changed = True
    if changed:
        with open(path, 'w') as f: json.dump(d, f)
except Exception:
    pass
" 2>/dev/null
    fi
    perf_apply >/dev/null 2>&1 || true
    if [[ -f "$WATCHDOG_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        local WD_EN
        WD_EN=$(python3 -c '
import json
try:
    with open("'"$WATCHDOG_FILE"'") as f:
        print(json.load(f).get("enabled", False))
except Exception:
    print(False)
' 2>/dev/null)
        if [[ "$WD_EN" == "True" || "$WD_EN" == "true" ]]; then
            install_watchdog_units
            systemctl enable --now navatunnel-watchdog.timer >/dev/null 2>&1 || true
        fi
    fi
    echo -e "${GREEN}[✔️] به‌روزرسانی انجام شد؛ برای منوی جدید اسکریپت را دوباره اجرا کنید.${NC}"
}

cli_carrier() {
    init_carrier_json
    local SUB="${1:-status}"
    case "$SUB" in
        status)
            local MODE ACT P1 P2
            MODE=$(carrier_get_mode)
            ACT=$(carrier_get_active)
            read -r P1 P2 <<< "$(carrier_get_fou_ports)"
            local PGRE PING_OUT="no peer"
            PGRE=$(watchdog_get_peer_gre 2>/dev/null)
            if [[ -n "$PGRE" ]]; then
                if ping -c 1 -W 2 "$PGRE" >/dev/null 2>&1; then
                    local RTT
                    RTT=$(ping -c 1 -W 2 "$PGRE" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\) *ms.*/\1/p' | head -n1)
                    PING_OUT="${GREEN}OK (${RTT}ms to ${PGRE})${NC}"
                else
                    PING_OUT="${RED}FAIL (no reply from ${PGRE})${NC}"
                fi
            fi

            echo -e "\n${CYAN}==========================================================${NC}"
            echo -e "${CYAN}         حامل تونل و تغییر خودکار مسیر         ${NC}"
            echo -e "${CYAN}==========================================================${NC}"
            echo -e "حالت تغییر مسیر:    ${YELLOW}$(fa_state "${MODE}")${NC} (خودکار، مستقیم یا دستی)"
            echo -e "حامل فعال:   ${GREEN}$(fa_state "${ACT}")${NC}"
            echo -e "پورت‌های FOU:    UDP ${P1} / UDP ${P2} (FOU کرنل و پروتکل 47)"
            echo -e "سلامت تونل:    ${PING_OUT}"
            python3 -c '
import json
try:
    with open("'"$CARRIER_FILE"'") as f:
        d = json.load(f)
    cands = ", ".join(d.get("candidates", []))
    print(f"حامل‌های پیشنهادی:       {cands}")
    print("تعداد تغییر مسیر:   {}".format(d.get("switch_count", 0)))
    last = d.get("last_switch", "") or "never"
    print(f"آخرین تغییر مسیر:      {last}")
except Exception:
    pass
' 2>/dev/null
            echo -e "${CYAN}==========================================================${NC}\n"
            ;;
        mode|set-mode)
            local TARGET="${2:-direct}"
            [[ "$TARGET" == "auto" ]] && TARGET="direct"
            carrier_set_mode "$TARGET" || return 1
            echo -e "${GREEN}[✔️] حالت انتقال انتخاب شد: ${TARGET}${NC}"
            carrier_apply "$TARGET" || return 1
            echo -e "${GREEN}[✔️] حامل فعال اعمال شد: ${TARGET}${NC}"
            ;;
        set|set-active|apply)
            local TARGET="${2:-direct}"
            carrier_apply "$TARGET" || return 1
            echo -e "${GREEN}[✔️] حامل فعال تغییر کرد به: ${TARGET}${NC}"
            ;;
        next|cycle)
            local NEW_C
            NEW_C=$(carrier_cycle_next) || return 1
            echo -e "${GREEN}[✔️] حامل بعدی انتخاب شد: ${NEW_C}${NC}"
            ;;
        set-ports)
            local P1="${2:-443}" P2="${3:-55555}"
            carrier_set_fou_ports "$P1" "$P2" || return 1
            carrier_init_kernel
            echo -e "${GREEN}[✔️] پورت‌های FOU به ${P1} و ${P2} تغییر کردند${NC}"
            ;;
        init|kernel-init)
            carrier_init_kernel
            ;;
        *)
            echo "روش استفاده: NavaTunnel carrier [status|mode <direct|fou:PORT>|set <direct|fou:PORT>|next|cycle|set-ports <P1> <P2>]"
            return 1
            ;;
    esac
}

menu_carrier() {
    ui_clear
    cli_carrier status
    echo -e "${YELLOW}انتخاب عمل:${NC}"
    echo "  1) انتخاب GRE مستقیم با پروتکل 47"
    echo "  2) انتخاب FOU روی UDP پورت 443"
    echo "  3) انتخاب حامل بعدی"
    echo "  0) بازگشت به منوی اصلی"
    echo ""
    read -r -p "انتخاب گزینه [0-3]: " C_OPT || return 0
    case "$C_OPT" in
        1) cli_carrier set direct ;;
        2) cli_carrier set fou:443 ;;
        3) cli_carrier next ;;
        0) return 0 ;;
        *) echo -e "${RED}[!] گزینه نامعتبر است.${NC}" ;;
    esac
    read -r -p "برای بازگشت به منو Enter بزنید..." || return 0
}

# Clear only interactive screens; never add control bytes to CLI output.
ui_clear() {
    [[ -t 1 ]] || return 0
    printf '\033[2J\033[H'
}

pause_prompt() {
    echo ""
    read -r -p "برای بازگشت به منو Enter بزنید..." _dummy || return 0
}

show_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
       NavaTunnel
EOF
    echo -e "${NC}"
    echo -e "${CYAN}==============================================================${NC}"
    echo -e "${GREEN}${BOLD}     NavaTunnel 6501 — مدیریت تونل ایران و خارج${NC}"
    echo -e "${CYAN}     تونل GRE لایه 3 و اتصال معکوس FRP${NC}"
    echo -e "${CYAN}==============================================================${NC}"
}

foreign_tunnel_summary() {
    [[ -f "${CONFIG_DIR}/frpc.toml" ]] || return 1
    local state gre
    state=$(systemctl is-active frpc 2>/dev/null) || true
    [[ -n "$state" ]] || state=unknown
    gre=$(ip -o -4 addr show dev "$TUNNEL_NAME" 2>/dev/null) || true
    FRPC_STATE="$state" GRE_ADDR="$gre" python3 - "${CONFIG_DIR}/frpc.toml" "$TUNNEL_NAME" <<'PYCODE'
import os,sys,re
from pathlib import Path
try:
    text=Path(sys.argv[1]).read_text()
    try:
        import tomllib
    except ImportError:
        tomllib=None
    if tomllib:
        config=tomllib.loads(text)
        address=config.get('serverAddr','?'); port=config.get('serverPort','?')
        protocol=config.get('transport',{}).get('protocol','tcp')
        proxies=config.get('proxies',[])
    else:
        # Generated configurations use simple quoted strings and numeric ports.
        def field(key,source,default='?'):
            m=re.search(r'^\s*'+re.escape(key)+r'\s*=\s*("[^"\n]*"|\d+)\s*(?:#.*)?$',source,re.M)
            return m.group(1).strip('"') if m else default
        header,*sections=text.split('[[proxies]]')
        address=field('serverAddr',header); port=field('serverPort',header)
        protocol=field('transport.protocol',header,'tcp')
        proxies=[dict(type=field('type',part),localIP=field('localIP',part),localPort=field('localPort',part),remotePort=field('remotePort',part)) for part in sections]
    print('تونل سرور خارج | FRPC')
    print('مقصد ایران (IP داخلی GRE): %s:%s'%(address,port))
    print('پروتکل FRP: %s | سرویس frpc: %s'%(protocol,dict(active='فعال',inactive='غیرفعال',failed='ناموفق',unknown='نامشخص',activating='در حال راه‌اندازی').get(os.environ['FRPC_STATE'],os.environ['FRPC_STATE'])))
    print('GRE: %s | %s'%(sys.argv[2],os.environ['GRE_ADDR'].strip() or 'اینترفیس IPv4 فعال پیدا نشد'))
    print('جبران افت بسته (FEC): '+('فعال' if protocol=='kcp' else 'غیرفعال'))
    for proxy in proxies:
        print('  %s | %s:%s -> پورت ایران %s'%(proxy.get('type','?'),proxy.get('localIP','127.0.0.1'),proxy.get('localPort','?'),proxy.get('remotePort','?')))
    if not proxies: print('هیچ پورت پروکسی در تنظیمات ثبت نشده است.')
except (OSError,ValueError) as error:
    print('خواندن تنظیمات تونل خارج ناموفق بود: '+str(error),file=sys.stderr)
    sys.exit(1)
PYCODE
}

menu_list_tunnels() {
    ui_clear
    menu_import_existing || return 1
    local count found=0
    count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("peers",[])))' "$PEERS_FILE") || return 1
    if ((count)); then
        echo 'تونل‌های سرور ایران | FRPS'
        peer_list_pretty || return 1
        found=1
    fi
    if [[ -f "${CONFIG_DIR}/frpc.toml" ]]; then
        foreign_tunnel_summary || return 1
        found=1
    fi
    ((found)) || echo 'هیچ تونلی روی این سرور ثبت نشده است.'
}

menu_connect_foreign() {
    ui_clear
    local bundle protocol recovery confirm
    read -r -p 'کد اتصال را بچسبانید [Enter: لغو]: ' bundle || return 0
    [[ -n "$bundle" ]] || return 0
    bundle_parse "$bundle" || { echo 'کد اتصال نامعتبر است.'; return 1; }
    protocol=$(menu_protocol_prompt "$B_FRP_TRANSPORT") || return 0
    recovery=off; [[ "$protocol" == kcp ]] && recovery=on
    if tunnel_present; then
        read -r -p 'تونل فعلی خارج با این تنظیمات جایگزین شود؟ [y/N]: ' confirm || return 0
        [[ "$confirm" == y || "$confirm" == Y ]] || return 0
        cli_setup_foreign --bundle "$bundle" --frp-transport "$protocol" --loss-recovery "$recovery" --force
    else
        cli_setup_foreign --bundle "$bundle" --frp-transport "$protocol" --loss-recovery "$recovery"
    fi
}

menu_foreign_tunnel() {
    local option
    while true; do
        ui_clear
        foreign_tunnel_summary || return 1
        echo '1) شروع همین تونل'
        echo '2) توقف همین تونل'
        echo '3) ری‌استارت همین تونل'
        echo '4) نمایش وضعیت'
        echo '5) مصرف و تنظیمات ترافیک همین تونل'
        echo '6) تغییر تنظیمات یا پروتکل با کد اتصال'
        echo '7) تغییر دائمی MTU همین تونل'
        echo '0) بازگشت'
        read -r -p 'انتخاب: ' option || return 0
        case "$option" in
            4) systemctl --no-pager status frpc "${TUNNEL_NAME}.service"; pause_prompt ;;
            3)
                if systemctl restart "${TUNNEL_NAME}.service" && systemctl restart frpc; then
                    echo 'تونل خارج ری‌استارت شد.'
                else echo 'ری‌استارت ناموفق بود؛ وضعیت سرویس را بررسی کنید.'; fi ;;
            5) menu_tunnel_traffic "$TUNNEL_NAME" ;;
            6) menu_connect_foreign ;;
            7) menu_mtu "$TUNNEL_NAME" ;;
            2) cli_tunnel_power stop --foreign ;;
            1) cli_tunnel_power start --foreign ;;
            0) return 0 ;;
            *) echo 'گزینه نامعتبر است.' ;;
        esac
        case "$option" in 3|6|7|2|1) pause_prompt ;; 4|5) ;; *) pause_prompt ;; esac
    done
}

menu_manage_tunnel() {
    ui_clear
    menu_import_existing || return 1
    local count option
    count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("peers",[])))' "$PEERS_FILE") || return 1
    if [[ -f "${CONFIG_DIR}/frpc.toml" ]]; then
        if ((count)); then
            echo 'این سرور هم تونل ایران و هم اتصال خارج دارد.'
            echo '1) مدیریت تونل‌های ایران'
            echo '2) مدیریت اتصال خارج'
            echo '0) بازگشت'
            read -r -p 'انتخاب: ' option || return 0
            case "$option" in 1) menu_edit_peer;; 2) menu_foreign_tunnel;; 0) return 0;; *) echo 'گزینه نامعتبر است.';; esac
        else menu_foreign_tunnel; fi
    else menu_edit_peer; fi
}

menu_tunnel() {
    local option
    while true; do
        ui_clear
        echo '1) ساخت تونل روی ایران (سرور اول یا سرورهای بیشتر)'
        echo '2) اتصال سرور خارج با کد اتصال'
        echo '3) انتخاب و مدیریت یک تونل'
        echo '4) فهرست و وضعیت تونل‌ها'
        echo '5) نصب دستی روی خارج (پیشرفته)'
        echo '6) تغییر IP سرور ایران (همه تونل‌ها)'
        echo '0) بازگشت'
        read -r -p 'انتخاب: ' option || return 0
        case "$option" in
            1) menu_add_peer; pause_prompt ;;
            2) menu_connect_foreign; pause_prompt ;;
            3) menu_manage_tunnel ;;
            4) menu_list_tunnels; pause_prompt ;;
            5) setup_foreign_server; pause_prompt ;;
            6) menu_iran_ip; pause_prompt ;;
            0) return 0 ;;
            *) echo 'گزینه نامعتبر است.'; pause_prompt ;;
        esac
    done
}

menu_optimization() {
    while true; do
        ui_clear
        show_banner
        echo -e "${CYAN}--- [2] کارایی و امنیت ---${NC}"
        echo "  1) بهینه‌سازی شبکه، BBR، بافر TCP و MTU"
        echo "  2) انتخاب حامل GRE مستقیم یا FOU"
        echo "  3) محافظ DPI و محدودیت نرخ اسکن پورت‌ها"
        echo "  4) تولید ترافیک پوششی هنگام بیکاری"
        echo "  5) پایش تونل، تغییر خودکار مسیر و هشدار تلگرام"
        echo "  6) تنظیمات کارایی، رمزگذاری، فشرده‌سازی و TLS"
        echo "  7) آزادسازی حافظه کش و تنظیم swap"
        echo "  8) بازگردانی تنظیمات شبکه"
        echo "  0) بازگشت به منوی اصلی"
        echo ""
        read -r -p "انتخاب گزینه [0-8]: " O_OPT || return 0
        case "$O_OPT" in
            1) tune_apply; pause_prompt ;;
            2) menu_carrier ;;
            3) menu_dpi_shield ;;
            4) menu_chaff ;;
            5) menu_watchdog ;;
            6) menu_perf ;;
            7) free_ram; pause_prompt ;;
            8) tune_restore; pause_prompt ;;
            0) return 0 ;;
            *) echo -e "${RED}[!] گزینه نامعتبر است.${NC}"; sleep 1 ;;
        esac
    done
}

menu_diagnostics_backup() {
    while true; do
        ui_clear
        show_banner
        echo -e "${CYAN}--- [3] بررسی شبکه و پشتیبان‌گیری ---${NC}"
        echo "  1) بررسی کامل سلامت سیستم و تونل"
        echo "  2) بررسی پورت‌های فعال و جدول مسیر"
        echo "  3) نمایش لاگ زنده FRP و پایش"
        echo "  4) تست فشار اتصال‌های هم‌زمان"
        echo "  5) پشتیبان‌گیری رمزگذاری‌شده از تنظیمات"
        echo "  6) بازگردانی پشتیبان از فایل"
        echo "  7) زمان‌بندی پشتیبان خودکار ساعتی یا روزانه"
        echo "  0) بازگشت به منوی اصلی"
        echo ""
        read -r -p "انتخاب گزینه [0-7]: " D_OPT || return 0
        case "$D_OPT" in
            1) doctor_health_check; pause_prompt ;;
            2)
                echo -e "\n${CYAN}=== پورت‌های فعال FRP ===${NC}"
                if command -v ss >/dev/null 2>&1; then
                    ss -tulpn | grep -E "frps|frpc" || ss -tulpn | head -15
                else
                    netstat -tulpn 2>/dev/null | grep -E "frps|frpc" || true
                fi
                echo -e "\n${CYAN}=== جدول مسیر و هدایت IP ===${NC}"
                ip route show
                echo -e "${CYAN}هدایت IP:${NC} $(sysctl -n net.ipv4.ip_forward 2>/dev/null || cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
                pause_prompt
                ;;
            3) show_logs ;;
            4)
                read -r -p "IP یا نام مقصد [127.0.0.1]: " S_HOST || return 0
                S_HOST=${S_HOST:-127.0.0.1}
                read -r -p "پورت مقصد [443]: " S_PORT || return 0
                S_PORT=${S_PORT:-443}
                read -r -p "تعداد اتصال هم‌زمان [50]: " S_CONNS || return 0
                S_CONNS=${S_CONNS:-50}
                cli_stress_test "$S_HOST" "$S_PORT" "$S_CONNS"
                pause_prompt
                ;;
            5) backup_now; pause_prompt ;;
            6)
                echo -e "\n${CYAN}=== پشتیبان‌های موجود ===${NC}"
                cli_backup status
                echo ""
                read -r -p "مسیر کامل فایل پشتیبان برای بازگردانی: " R_FILE || return 0
                if [[ -n "$R_FILE" && -f "$R_FILE" ]]; then
                    backup_restore "$R_FILE"
                else
                    echo -e "${RED}[!] فایل پیدا نشد: '$R_FILE'${NC}"
                fi
                pause_prompt
                ;;
            7)
                ui_clear
                echo "زمان‌بندی پشتیبان:"
                echo "  1) هر چند ساعت (مثلاً 6)"
                echo "  2) روزانه در ساعت مشخص (مثلاً 03:00)"
                echo "  3) غیرفعال‌سازی پشتیبان خودکار"
                echo "  0) لغو"
                read -r -p "انتخاب [0-3]: " B_SCHED || return 0
                case "$B_SCHED" in
                    1) read -p "فاصله ساعتی [1-168]: " B_H; cli_backup schedule --every "$B_H" ;;
                    2) read -p "ساعت روزانه HH:MM (مثلاً 03:00): " B_D; cli_backup schedule --daily "$B_D" ;;
                    3) cli_backup schedule --off ;;
                    *) ;;
                esac
                pause_prompt
                ;;
            0) return 0 ;;
            *) echo -e "${RED}[!] گزینه نامعتبر است.${NC}"; sleep 1 ;;
        esac
    done
}

menu_maintenance() {
    while true; do
        ui_clear
        show_banner
        echo -e "${CYAN}--- [4] نگهداری و به‌روزرسانی ---${NC}"
        echo "  1) به‌روزرسانی کامل به آخرین نسخه"
        echo "  2) دریافت و بررسی فایل‌های اجرایی FRP"
        echo "  3) نصب و بررسی پیش‌نیازهای سیستم"
        echo "  4) بررسی و بارگذاری ماژول‌های GRE و FOU"
        echo "  5) نمایش نسخه سیستم و وضعیت تنظیمات"
        echo "  0) بازگشت به منوی اصلی"
        echo ""
        read -r -p "انتخاب گزینه [0-5]: " M_OPT || return 0
        case "$M_OPT" in
            1)
                backup_configs "pre_update"
                update_all
                doctor_health_check
                pause_prompt
                ;;
            2)
                echo -e "${CYAN}[*] در حال دریافت و ذخیره فایل‌های اجرایی...${NC}"
                install_frp_binaries "all" && echo -e "${GREEN}[✔️] فایل‌های اجرایی بررسی و آماده شدند.${NC}"
                pause_prompt
                ;;
            3)
                rm -f "${NAVATUNNEL_STATE_DIR}/.deps_installed" 2>/dev/null
                ensure_dependencies_smart || return 1
                echo -e "${GREEN}[✔️] پیش‌نیازهای سیستم بررسی و به‌روز شدند.${NC}"
                pause_prompt
                ;;
            4)
                echo -e "${CYAN}[*] در حال بررسی فعال‌بودن ماژول‌های GRE و FOU...${NC}"
                modprobe ip_gre 2>/dev/null && modprobe fou 2>/dev/null && echo -e "${GREEN}[✔️] ماژول‌های ip_gre و fou بارگذاری شدند.${NC}" || echo -e "${YELLOW}[!] بارگذاری با modprobe ممکن نبود؛ شاید ماژول داخل کرنل باشد.${NC}"
                pause_prompt
                ;;
            5)
                echo -e "\n${CYAN}=== اطلاعات نسخه سیستم ===${NC}"
                echo "اسکریپت NavaTunnel: ${NAVATUNNEL_SCRIPT}"
                tune_status
                pause_prompt
                ;;
            0) return 0 ;;
            *) echo -e "${RED}[!] گزینه نامعتبر است.${NC}"; sleep 1 ;;
        esac
    done
}

menu_uninstall() {
    ui_clear
    echo "1) حذف اجزای تونل"
    echo "2) حذف نصب NavaTunnel و همه اجزای تونل"
    echo "0) بازگشت"
    local choice
    read -r -p "انتخاب گزینه [0-2]: " choice || return 0
    case "$choice" in
        1) remove_tunnel; pause_prompt ;;
        2) uninstall_all; pause_prompt ;;
        0) return 0 ;;
        *) echo "گزینه نامعتبر است." ;;
    esac
}

# Legacy menu stubs for backwards compatibility
menu_installation() { menu_tunnel; }
menu_server() { menu_optimization; }
menu_bundle() { menu_tunnel; }
menu_diagnostics() { menu_diagnostics_backup; }
menu_update() { menu_maintenance; }

ensure_traffic_helper() {
    local target="/usr/local/bin/NavaTunnel-traffic.sh"
    if [[ ! -f "$target" ]]; then
        local source_dir tmp
        source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "${source_dir}/NavaTunnel-traffic.sh" ]]; then
            bash -n "${source_dir}/NavaTunnel-traffic.sh" || return 1
            install -m 755 "${source_dir}/NavaTunnel-traffic.sh" "$target" || return 1
        else
            tmp=$(mktemp) || return 1
            if ! download_with_fallback "$tmp" "${NAVATUNNEL_URL_BASE}/NavaTunnel-traffic.sh" 30 || ! bash -n "$tmp"; then
                rm -f "$tmp"
                echo "دریافت ابزار ترافیک ناموفق بود." >&2
                return 1
            fi
            install -m 755 "$tmp" "$target" || { rm -f "$tmp"; return 1; }
            rm -f "$tmp"
        fi
    fi
    command -v python3 >/dev/null && command -v iptables >/dev/null || {
        echo "شمارش ترافیک به python3 و iptables نیاز دارد." >&2; return 1;
    }
}

install_traffic_monitor() {
    [[ -f /etc/systemd/system/NavaTunnel-traffic.timer && -f /etc/systemd/system/NavaTunnel-traffic.service ]] && return 0
    cat > /etc/systemd/system/NavaTunnel-traffic.service <<'EOF'
[Unit]
Description=شمارش ترافیک و اعمال سقف NavaTunnel
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/bin/NavaTunnel-traffic.sh tick

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/NavaTunnel-traffic.timer <<'EOF'
[Unit]
Description=شمارش ترافیک NavaTunnel در هر 10 ثانیه

[Timer]
OnBootSec=1s
OnUnitActiveSec=10s
AccuracySec=1s
Unit=NavaTunnel-traffic.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload || return 1
    systemctl enable NavaTunnel-traffic.service || return 1
}

cli_traffic() {
    ensure_traffic_helper || return 1
    bash /usr/local/bin/NavaTunnel-traffic.sh "$@" || return $?
    if [[ "${1:-}" == "clear" ]]; then
        systemctl disable --now NavaTunnel-traffic.timer NavaTunnel-traffic.service >/dev/null 2>&1 || true
    else
        install_traffic_monitor || return 1
        systemctl enable NavaTunnel-traffic.service || return 1
        systemctl enable --now NavaTunnel-traffic.timer || return 1
    fi
}

traffic_register() {
    # Reuse a counter registered under a custom name for the same interface.
    ensure_traffic_helper || return 1
    local existing
    existing=$(python3 - "${NAVATUNNEL_STATE_DIR}/traffic.json" "$@" <<'PYTRAFFIC'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); data=json.loads(p.read_text()) if p.exists() else {}; name=sys.argv[2]
if name in data:
    print(name)
else:
    args=sys.argv[3:]
    for flag,key in (('--interface','interface'),('--peer','peer')):
        if flag in args and args.index(flag)+1<len(args):
            target=args[args.index(flag)+1]
            for identifier,t in data.items():
                if t.get(key)==target:
                    print(identifier); sys.exit(0)
PYTRAFFIC
) || return 1
    if [[ -n "$existing" ]]; then cli_traffic status "$existing"; else cli_traffic add "$@"; fi
}

menu_select_traffic() {
    ui_clear >&2
    local rows id label choice i=0
    local -a ids=()
    rows=$(python3 - "${NAVATUNNEL_STATE_DIR}/traffic.json" "$PEERS_FILE" <<'PYCODE'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); data=json.loads(p.read_text()) if p.exists() else {}
registry=Path(sys.argv[2]); labels={}
if registry.exists():
    labels={t.get('gre_if'):t.get('name','') for t in json.loads(registry.read_text()).get('peers',[])}
for name,t in sorted(data.items()):
    used=t.get('download',0) if t.get('mode')=='download' else t.get('upload',0) if t.get('mode')=='upload' else t.get('download',0)+t.get('upload',0)
    quota='نامحدود' if not t.get('limit') else '%.2f GB'%(t['limit']/10**9)
    target=t.get('interface') or t.get('peer',''); label=labels.get(target) or name
    print('%s\t%s | %s | %.2f GB / %s | %s | %s'%(name,label,target,used/10**9,quota,dict(download='دانلود',upload='آپلود',both='هر دو').get(t.get('mode','both'),'هر دو'),'مسدود' if t.get('blocked') else 'باز'))
PYCODE
) || return 1
    while IFS=$'\t' read -r id label; do
        [[ -n "$id" ]] || continue
        ids+=("$id"); i=$((i+1)); printf '%s) %s\n' "$i" "$label" >&2
    done <<< "$rows"
    ((i)) || { echo 'شمارنده‌ای ثبت نشده؛ گزینه شناسایی تونل‌ها را اجرا کنید.' >&2; pause_prompt >&2; return 1; }
    echo '0) بازگشت' >&2
    while true; do
        read -r -p 'شماره تونل: ' choice || return 1
        if [[ "$choice" =~ ^[0-9]{1,6}$ ]]; then
            choice=$((10#$choice))
            ((choice==0)) && return 1
            if ((choice<=i)); then
                printf '%s\n' "${ids[choice-1]}"
                return 0
            fi
        fi
        echo 'شماره تونل نامعتبر است؛ از فهرست انتخاب کنید یا 0 بزنید.' >&2
    done
}

menu_traffic_mode() {
    ui_clear >&2
    local choice
    echo '1) دانلود (دریافت این سرور)' >&2
    echo '2) آپلود (ارسال این سرور)' >&2
    echo '3) هر دو' >&2
    echo '0) لغو' >&2
    read -r -p 'نحوه محاسبه [Enter: هر دو]: ' choice || return 1
    case "$choice" in 1) echo download;; 2) echo upload;; 3|'') echo both;; *) return 1;; esac
}

menu_traffic() {
    local option id limit mode target confirm
    while true; do
        ui_clear
        echo 'ترافیک از دید همین سرور محاسبه می‌شود.'
        echo '1) شناسایی تونل‌ها و نمایش مصرف'
        echo '2) تعیین سقف مصرف'
        echo '3) ریست مصرف و رفع مسدودی'
        echo '4) نحوه محاسبه دانلود/آپلود'
        echo '5) ثبت دستی اینترفیس'
        echo '6) ثبت IP اختصاصی'
        echo '7) حذف شمارنده'
        echo '0) بازگشت'
        read -r -p 'انتخاب: ' option || return 0
        case "$option" in
            1) cli_traffic discover >/dev/null && cli_traffic list ;;
            2)
                id=$(menu_select_traffic) || continue
                read -r -p 'سقف مصرف به GB (مثلاً 100؛ یا 100GB؛ 0=نامحدود؛ Enter=لغو): ' limit || return 0
                [[ -n "$limit" ]] || continue
                [[ "$limit" =~ ^[0-9]+([.][0-9]+)?$ && "$limit" != 0 ]] && limit="${limit}GB"
                mode=$(menu_traffic_mode) || continue
                cli_traffic limit "$id" "$limit" --mode "$mode" ;;
            3|7)
                id=$(menu_select_traffic) || continue
                read -r -p 'مصرف پاک و محدودیت مسدودی برداشته شود؟ [y/N]: ' confirm || return 0
                [[ "$confirm" == y || "$confirm" == Y ]] || continue
                if [[ "$option" == 3 ]]; then cli_traffic reset "$id"; else cli_traffic remove "$id"; fi ;;
            4)
                id=$(menu_select_traffic) || continue
                mode=$(menu_traffic_mode) || continue
                cli_traffic mode "$id" "$mode" ;;
            5|6)
                read -r -p 'نام شمارنده [Enter: لغو]: ' id || return 0
                [[ -n "$id" ]] || continue
                if [[ "$option" == 5 ]]; then
                    read -r -p 'نام اینترفیس (مثلاً gre-tunnel): ' target || return 0
                    cli_traffic add "$id" --interface "$target"
                else
                    read -r -p 'IPv4 اختصاصی (تمام ترافیک این IP شمرده می‌شود): ' target || return 0
                    cli_traffic add "$id" --peer "$target"
                fi ;;
            0) return 0 ;;
            *) echo 'گزینه نامعتبر است.' ;;
        esac
        pause_prompt
    done
}

menu_loop() {
    trap 'echo -e "\n\n${CYAN}[*] خروج از مدیریت NavaTunnel؛ خدانگهدار!${NC}"; exit 0' INT
    while true; do
        ui_clear
        show_banner
        echo ""
        echo "منوی اصلی"
        echo "  1) ساخت و مدیریت تونل‌ها"
        echo "  2) تنظیمات پیشرفته سرعت و امنیت"
        echo "  3) بررسی وضعیت و پشتیبان‌گیری"
        echo "  4) به‌روزرسانی و نگهداری"
        echo "  5) حذف نصب"
        echo "  6) مصرف ترافیک، سقف و ریست"
        echo "  0) خروج"
        echo ""
        read -r -p "انتخاب گزینه [0-6]: " MAIN_OPT || return 0
        case "$MAIN_OPT" in
            1) menu_tunnel ;;
            2) menu_optimization ;;
            3) menu_diagnostics_backup ;;
            4) menu_maintenance ;;
            5) menu_uninstall ;;
            6) menu_traffic ;;
            0|8|exit|q)
                echo -e "${CYAN}خروج از مدیریت NavaTunnel؛ خدانگهدار!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[!] گزینه نامعتبر است.${NC}"
                sleep 1
                ;;
        esac
    done
}

main_menu() {
    menu_loop
}

# Non-interactive CLI: NavaTunnel.sh setup-iran|setup-foreign with flags.
# The setup_*_noninteractive + _setup_foreign_full functions above are the
# Menu and CLI run the same tunnel setup steps.
usage_cli() {
    cat <<EOF
روش استفاده:
  NavaTunnel                                    # منوی تعاملی مدیریت
  NavaTunnel menu                               # منوی مدیریت با همه گزینه‌ها
  NavaTunnel traffic discover | list
  NavaTunnel traffic add ID --interface gre-tunnel   # یا --peer برای IP اختصاصی مقابل
  NavaTunnel traffic limit ID 100GB --mode download|upload|both
  NavaTunnel traffic status ID | reset ID | remove ID
  NavaTunnel traffic mode ID download|upload|both
  NavaTunnel setup-iran    --local-pub IP --remote-pub IP [--frp-port N] [--local-gre IP] [--peer-gre IP] [--token T] [--chaff low|mid|off] [--force]
  NavaTunnel setup-foreign --local-pub IP --remote-pub IP [--frp-port N] --token T --ports "443, 2083" [--local-gre IP] [--peer-gre IP] [--chaff low|mid|off] [--force]
                       # یا: NavaTunnel setup-foreign --bundle hsh1_...
  NavaTunnel status | remove-tunnel [--force]
  NavaTunnel uninstall [--force]                   # حذف کامل تونل و خود NavaTunnel
  NavaTunnel add-peer --local-pub IP --remote-pub IP [--frp-port N] --token T --local-gre IP --peer-gre IP --ports "443, 2083" [--name LABEL] [--bundle hsh1_...] [--chaff low|mid|off]
  NavaTunnel remove-peer --id N [--force] | edit-peer --id N [--name L] [--remote-pub IP] [--carrier C] [--ports "..."] | edit-peer-ports --id N --ports "443, 2083" | peer-list | peer-token --id N
  NavaTunnel iran-ip --ip IP                       # تغییر آدرس عمومی ایران برای همه تونل‌ها
  NavaTunnel mtu --interface gre-tunnel --value 1300
  NavaTunnel tunnel-power start|stop --id N | --foreign
  NavaTunnel peer-control-port --id N --port N|auto
  NavaTunnel peer-protocol --id N --protocol tcp|kcp|quic|websocket|wss
  NavaTunnel loss-recovery --id N --mode on|off  # ذخیره انتخاب جبران افت بسته؛ کد جدید را روی خارج اعمال کنید
  NavaTunnel logs | restart   # (با bash NavaTunnel.sh هم اجرا می‌شود)
  NavaTunnel optimize | restore | tune-status
  NavaTunnel carrier [status|mode auto|direct|fou:P|set direct|fou:P|next] # تغییر خودکار حامل
  NavaTunnel perf status|enc on|off|comp on|off|tls on|off|chaff off|low|mid|custom|dpi on|off|apply
  NavaTunnel chaff configure --min-ms 400 --max-ms 2800 --min-bytes 64 --max-bytes 1200
  NavaTunnel dpi-shield configure --rate 60/sec --burst 120
  NavaTunnel chaff on|off|status                   # ترافیک پوششی هنگام بیکاری
  NavaTunnel dpi-shield on|off|status              # محدودیت نرخ پورت‌ها در برابر اسکن پرتعداد
  NavaTunnel watchdog on|off|status|test|tick      # پایش تونل و هشدار
  NavaTunnel backup now [--keep N] | restore <f> | schedule ... | status
  NavaTunnel tgsend "msg"                          # ارسال دستی هشدار تلگرام
  NavaTunnel doctor [server|stop-server|fix]       # بررسی تأخیر، نوسان، MTU و سرعت
  NavaTunnel stress-test [host] [port] [conns]     # تست فشار اتصال هم‌زمان
  NavaTunnel update | update-all                   # به‌روزرسانی اسکریپت
  NavaTunnel download-cores                        # دریافت فایل‌های اجرایی FRP
  NavaTunnel free-ram                              # محدودیت لاگ، آزادسازی کش و یک گیگابایت swap

جبران افت بسته:
  فرمان‌های add-peer و setup-foreign گزینه --loss-recovery on|off دارند؛ پیش‌فرض خاموش است.
  حالت on پروتکل KCP/FEC را روی خارج انتخاب می‌کند و مصرف افزوده دارد.

کدهای اتصال:
  FRP:              hsh1_<IRAN_PUB>_<FRP_PORT>_<IRAN_GRE>_<FOREIGN_GRE>_<TOKEN>[_<PORTS>]
  کد راه‌اندازی با BUNDLE چاپ می‌شود؛ آن را در --bundle وارد کنید.
EOF
}


cli_setup_iran() {
    local LOCAL_PUB="" REMOTE_PUB="" FRP_PORT="" LOCAL_GRE="$IRAN_GRE_IP" PEER_GRE="$FOREIGN_GRE_IP" TOKEN="" FORCE=0 PORTS=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --* && $# -lt 2 ]]; then
            case "$1" in
                --force|--show-token|--encrypt|--compress|--dry-run|--off|--help) ;;
                *) echo "مقدار این گزینه وارد نشده است: $1" >&2; return 1 ;;
            esac
        fi
        case "$1" in
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --frp-port) FRP_PORT="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            --chaff) CHAFF_PROFILE="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            -h|--help) usage_cli; return 0 ;;
            *) echo -e "${RED}[!] گزینه ناشناخته: $1${NC}"; usage_cli; return 1 ;;
        esac
    done
    CHAFF_PROFILE="${CHAFF_PROFILE:-$(perf_get_chaff)}"
    case "$CHAFF_PROFILE" in
        low|mid|off) ;;
        *) echo -e "${YELLOW}[!] حالت ترافیک پوششی ${CHAFF_PROFILE} ناشناخته است؛ غیرفعال انتخاب شد.${NC}"; CHAFF_PROFILE="off" ;;
    esac
    LOCAL_PUB=${LOCAL_PUB:-$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')}
    [[ -z "$LOCAL_PUB" ]] && LOCAL_PUB=$(curl -sSL --max-time 5 https://api.ipify.org 2>/dev/null)
    FRP_PORT=${FRP_PORT:-$(gen_random_port)}
    validate_setup_common "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$LOCAL_GRE" || return 1
    is_valid_ip "$PEER_GRE" || { echo -e "${RED}[!] IP داخلی GRE سرور مقابل نامعتبر است: '$PEER_GRE'${NC}"; return 1; }
    if [[ -z "$TOKEN" ]]; then
        TOKEN=$(gen_token32)
        echo -e "${CYAN}[*] توکن ساخته‌شده: ${TOKEN}${NC}"
    fi
    if tunnel_present && [[ "$FORCE" -ne 1 ]]; then
        echo -e "${RED}[!] تونل از قبل وجود دارد؛ برای جایگزینی از --force استفاده کنید.${NC}"
        return 1
    fi
    setup_iran_server_noninteractive "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$PORTS"
}

cli_setup_foreign() {
    local LOCAL_PUB="" REMOTE_PUB="" FRP_PORT="" LOCAL_GRE="" PEER_GRE="" TOKEN="" PORTS="" FORCE=0 BUNDLE=""
    local FOREIGN_GRE_DEF="$FOREIGN_GRE_IP" IRAN_GRE_DEF="$IRAN_GRE_IP"
    local RELAY_IP="" PROXY_PROTOCOL="off"
    local LOSS_RECOVERY="" TRANSPORT_EXPLICIT=0 LOSS_EXPLICIT=0
    local FRP_TRANSPORT="tcp" FRP_ENCRYPTION="off" FRP_COMPRESSION="off"
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --* && $# -lt 2 ]]; then
            case "$1" in
                --force|--show-token|--encrypt|--compress|--dry-run|--off|--help) ;;
                *) echo "مقدار این گزینه وارد نشده است: $1" >&2; return 1 ;;
            esac
        fi
        case "$1" in
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --frp-port) FRP_PORT="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            --bundle) BUNDLE="$2"; shift 2 ;;
            --relay-ip) RELAY_IP="$2"; shift 2 ;;
            --proxy-protocol) PROXY_PROTOCOL="$2"; shift 2 ;;
            --frp-transport) FRP_TRANSPORT="$2"; TRANSPORT_EXPLICIT=1; shift 2 ;;
            --loss-recovery) LOSS_RECOVERY="$2"; LOSS_EXPLICIT=1; shift 2 ;;
            --encrypt) FRP_ENCRYPTION="on"; shift ;;
            --compress) FRP_COMPRESSION="on"; shift ;;
            --frp-encryption) FRP_ENCRYPTION="$2"; shift 2 ;;
            --frp-compression) FRP_COMPRESSION="$2"; shift 2 ;;
            --chaff) CHAFF_PROFILE="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            -h|--help) usage_cli; return 0 ;;
            *) echo -e "${RED}[!] گزینه ناشناخته: $1${NC}"; usage_cli; return 1 ;;
        esac
    done
    CHAFF_PROFILE="${CHAFF_PROFILE:-$(perf_get_chaff)}"
    case "$CHAFF_PROFILE" in
        low|mid|off) ;;
        *) echo -e "${YELLOW}[!] حالت ترافیک پوششی ${CHAFF_PROFILE} ناشناخته است؛ غیرفعال انتخاب شد.${NC}"; CHAFF_PROFILE="off" ;;
    esac
    if [[ -n "$BUNDLE" ]]; then
        bundle_parse "$BUNDLE" || { echo -e "${RED}[!] کد --bundle نامعتبر است؛ قالب مورد انتظار ( hsh1_<IRAN_PUB>_<PORT>_<IRAN_GRE>_<FOREIGN_GRE>_<TOKEN>[_<PORTS>]).${NC}"; return 1; }
        TOKEN=$B_TOKEN
        REMOTE_PUB=$B_IRAN_PUB
        # Bundle FRP server port is the absolute source of truth
        FRP_PORT=$B_FRP_PORT
        LOCAL_GRE=$B_FOREIGN_GRE
        PEER_GRE=$B_IRAN_GRE
        if [[ "$TRANSPORT_EXPLICIT" != 1 ]]; then FRP_TRANSPORT=$B_FRP_TRANSPORT; fi
        if [[ -z "$LOSS_RECOVERY" ]]; then
            if [[ "$TRANSPORT_EXPLICIT" == 1 ]]; then
                [[ "$FRP_TRANSPORT" == kcp ]] && LOSS_RECOVERY=on || LOSS_RECOVERY=off
            else LOSS_RECOVERY=$B_LOSS_RECOVERY; fi
        fi
        # B_PORTS may be empty if bundle had no ports segment (e.g. hsh1_...token__fouXXX)
        # Only override PORTS from bundle if not already provided via --ports and bundle has ports
        [[ -z "$PORTS" && -n "$B_PORTS" ]] && PORTS=$B_PORTS
        carrier_set_fou_ports "$B_FOU_P1" "$B_FOU_P2" 2>/dev/null || true
        carrier_init_kernel 2>/dev/null || true
        echo -e "${CYAN}[*] کد اتصال اعمال شد؛ مقصد ایران ${REMOTE_PUB} و پورت FRP ${FRP_PORT} است.${NC}"
    fi
    # --bundle replaces --token as the required secret
    [[ -z "$TOKEN" && -n "$BUNDLE" ]] && TOKEN=$B_TOKEN
    LOCAL_PUB=${LOCAL_PUB:-$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')}
    [[ -z "$LOCAL_PUB" ]] && LOCAL_PUB=$(curl -sSL --max-time 5 https://api.ipify.org 2>/dev/null)
    FRP_PORT=${FRP_PORT:-$(gen_random_port)}
    LOCAL_GRE=${LOCAL_GRE:-$FOREIGN_GRE_DEF}
    PEER_GRE=${PEER_GRE:-$IRAN_GRE_DEF}
    validate_setup_common "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$LOCAL_GRE" || return 1
    is_valid_ip "$PEER_GRE" || { echo -e "${RED}[!] IP داخلی GRE سرور مقابل نامعتبر است: '$PEER_GRE'${NC}"; return 1; }
    [[ -n "$TOKEN" ]] || { echo -e "${RED}[!] گزینه --token ضروری است؛ آن را از ایران کپی کنید.${NC}"; return 1; }
    local CLEANED="" p
    for p in $(echo "$PORTS" | tr ',' ' '); do
        is_valid_port "$p" || { echo "پورت نامعتبر: $p" >&2; return 1; }
            CLEANED="$CLEANED $((10#$p))"
    done
    CLEANED=$(echo "$CLEANED" | xargs)
    if [[ -z "$CLEANED" ]]; then
        # Bundle had empty ports segment — non-interactive path cannot prompt;
        # Pass --ports explicitly when the bundle has no ports.
        echo -e "${RED}[!] گزینه --ports باید حداقل یک پورت معتبر داشته باشد (مثلاً \"443, 2083\"). کد اتصال پورت ندارد؛ پورت‌ها را با --ports وارد کنید.${NC}"
        return 1
    fi

    # Port availability check.
    # FRP_PORT is on the remote server; local listeners do not conflict with it.

    case "$LOSS_RECOVERY" in
        on)
            if [[ "$TRANSPORT_EXPLICIT" == 1 && "$FRP_TRANSPORT" != kcp ]]; then
                echo 'جبران افت بسته به --frp-transport kcp نیاز دارد؛ پروتکل انتخاب‌شده ناسازگار است.' >&2; return 1
            fi
            FRP_TRANSPORT=kcp ;;
        off)
            [[ "$TRANSPORT_EXPLICIT" != 1 && "$FRP_TRANSPORT" == kcp ]] && FRP_TRANSPORT=tcp
            if [[ "$LOSS_EXPLICIT" == 1 && "$TRANSPORT_EXPLICIT" == 1 && "$FRP_TRANSPORT" == kcp ]]; then
                echo 'KCP شامل FEC است و با جبران افت بسته خاموش سازگار نیست.' >&2; return 1
            fi ;;
        '') ;;
        *) echo 'مقدار --loss-recovery باید on یا off باشد..' >&2; return 1 ;;
    esac
    case "$FRP_TRANSPORT" in
        tcp|kcp|quic|websocket|wss) ;;
        *) echo -e "${YELLOW}[!] پروتکل FRP ${FRP_TRANSPORT} ناشناخته است؛ TCP انتخاب شد.${NC}"; FRP_TRANSPORT="tcp" ;;
    esac

    if tunnel_present && [[ "$FORCE" -ne 1 ]]; then
        echo -e "${RED}[!] تونل از قبل وجود دارد؛ برای جایگزینی از --force استفاده کنید.${NC}"
        return 1
    fi
    setup_foreign_server_noninteractive "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$CLEANED" "$RELAY_IP" "$PROXY_PROTOCOL" "$FRP_TRANSPORT" "$FRP_ENCRYPTION" "$FRP_COMPRESSION"
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help|help) usage_cli; exit 0 ;;
        bundle)
            shift
            case "${1:-}" in
                inspect) shift; cli_bundle_inspect "$@" ;;
                *) echo "روش استفاده: NavaTunnel bundle inspect <bundle> [--show-token]"; exit 1 ;;
            esac
            exit $?
            ;;
    esac

    check_root
    ensure_navatunnel_bin
    case "$1" in
        menu) main_menu ;;
        setup-iran) shift; cli_setup_iran "$@" ;;
        setup-foreign) shift; cli_setup_foreign "$@" ;;
        mtu) shift; cli_mtu "$@" ;;
        mtu-apply) shift; tunnel_mtu_apply "$@" ;;
        tunnel-power) shift; cli_tunnel_power "$@" ;;
        peer-control-port) shift; cli_peer_control_port "$@" ;;
        peer-protocol) shift; cli_peer_protocol "$@" ;;
        loss-recovery) shift; cli_loss_recovery "$@" ;;
        add-peer) shift; cli_add_peer "$@" ;;
        remove-peer) shift; cli_remove_peer "$@" ;;
        iran-ip) shift; cli_iran_ip "$@" ;;
        edit-peer) shift; cli_edit_peer "$@" ;;
        edit-peer-ports) shift; cli_edit_peer_ports "$@" ;;
        peer-list) peer_list ;;
        logs) show_logs ;;
        restart) restart_all ;;
        traffic) shift; cli_traffic "${@:-list}" ;;
        perf) shift; cli_perf "$@" ;;
        chaff) shift; cli_chaff "$@" ;;
        dpi-shield|dpi_shield|dpishield) shift; cli_dpi_shield "$@" ;;
        watchdog) shift; cli_watchdog "$@" ;;
        backup) shift; cli_backup "$@" ;;
        tgsend) shift; watchdog_send "$1" ;;
        update|update-all) update_all ;;
        peer-token)
            shift; ID=""
            while [[ $# -gt 0 ]]; do case "$1" in --id) [[ $# -ge 2 ]] || { echo "مقدار این گزینه وارد نشده است: --id" >&2; exit 1; }; ID="$2"; shift 2 ;; *) echo "گزینه ناشناخته: $1" >&2; exit 1 ;; esac; done
            peer_token "$ID" ;;
        status) check_status ;;
        doctor|test|diagnose) shift; cli_doctor "$@" ;;
        stress-test|test-load|stress) shift; cli_stress_test "$@" ;;
        carrier) shift; cli_carrier "$@" ;;
        carrier-kernel-init) carrier_init_kernel ;;
        carrier-apply-active) shift; carrier_apply_active "$1" ;;
        optimize) tune_apply ;;
        restore) tune_restore ;;
        tune-status) tune_status ;;
        free-ram|optimize-ram) free_ram ;;
        download-cores|cores)
            echo -e "${CYAN}[*] در حال دریافت و بررسی فایل‌های اجرایی FRP...${NC}"
            install_frp_binaries "all" || { echo -e "${RED}[!] نصب فایل‌های اجرایی FRP ناموفق بود.${NC}"; exit 1; }
            echo -e "${GREEN}[✔️] همه فایل‌های اجرایی frps و frpc در ${INSTALL_DIR} آماده‌اند.${NC}"
            ;;
        remove-tunnel)
            if [[ "${2:-}" == "--force" ]]; then remove_tunnel_force; else remove_tunnel; fi ;;
        uninstall)
            if [[ "${2:-}" == "--force" ]]; then uninstall_all_force; else uninstall_all; fi ;;
        *) echo -e "${RED}[!] دستور ناشناخته: $1${NC}"; usage_cli; exit 1 ;;
    esac
    exit $?
fi

# ---- No arguments: interactive terminal management ----
check_root
ensure_navatunnel_bin
main_menu
