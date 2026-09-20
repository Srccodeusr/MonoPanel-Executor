#!/usr/bin/env bash
# ============================================================================
#  __  __                  ____                  _
# |  \/  | ___  _ __   ___|  _ \ __ _ _ __   ___| |
# | |\/| |/ _ \| '_ \ / _ \ |_) / _` | '_ \ / _ \ |
# | |  | | (_) | | | | (_) |  __/ (_| | | | |  __/ |
# |_|  |_|\___/|_| |_|\___/|_|   \__,_|_| |_|\___|_|
#
#  MonoPanel Installer & Executer
#  Made by prime.dev1
#
#  One numbered menu to install, run, update and expose MonoPanel on ANY
#  Linux VPS or sandbox container — with or without systemd — plus full
#  node (Wings) setup and Cloudflare Tunnel support.
#
#  Panel source : https://github.com/Srccodeusr/MonoPanel   (branch: develop)
#  Panel base   : Jexactyl / Pterodactyl (MIT) — full credit to the original
#                 authors and community.
#
#  Usage
#    sudo bash monopanel.sh                 # interactive menu
#    sudo bash monopanel.sh <command>       # run one action and exit
#
#  Commands
#    install | run-prod | run-dev | stop | restart | update | admin
#    node-setup | node-start | node-stop | node-sync | tunnel | status
#    logs | backup | self-update | help
#
#  Useful environment variables (all optional)
#    MONOPANEL_REPO        panel git URL          (default: Srccodeusr/MonoPanel)
#    MONOPANEL_BRANCH      panel git branch       (default: develop)
#    MONOPANEL_DIR         where the panel lives  (default: /var/www/monopanel)
#    MONOPANEL_HOME        state/logs/pids dir    (default: /var/lib/monopanel)
#    MONOPANEL_GIT_TOKEN   GitHub token if the panel repo is private
#    MONOPANEL_SCRIPT_URL  raw URL of this script (enables "Update this script")
#    MP_INIT               force service backend: systemd | builtin
#    MP_ASSUME_DEFAULTS=1  never prompt, accept every default (automation)
#    MP_BUILD_MEM          Node heap (MB) used for the frontend build
#    MP_VITE_PUBLIC_URL    public URL of the Vite dev server (remote dev mode)
# ============================================================================

set -uo pipefail
PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin"

MP_VERSION="1.0.0"
MP_AUTHOR="prime.dev1"

# ----------------------------------------------------------------------------
# Defaults (edit these, or override through environment variables)
# ----------------------------------------------------------------------------
REPO_URL_DEFAULT="https://github.com/Srccodeusr/MonoPanel.git"
BRANCH_DEFAULT="develop"
# Raw URL of THIS script inside your installer repo (main branch). Example:
#   https://raw.githubusercontent.com/Srccodeusr/<installer-repo>/main/monopanel.sh
SCRIPT_URL_DEFAULT=""
WINGS_DATA_DEFAULT="/var/lib/pterodactyl/volumes"

# ----------------------------------------------------------------------------
# Colors
# ----------------------------------------------------------------------------
RESET='\033[0m'
BOLD='\033[1m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD_CYAN='\033[1;36m'
BOLD_GREEN='\033[1;32m'
BOLD_YELLOW='\033[1;33m'
BOLD_RED='\033[1;31m'
BOLD_MAGENTA='\033[1;35m'
GRAY='\033[0;90m'

# ----------------------------------------------------------------------------
# UI helpers
# ----------------------------------------------------------------------------
line() { printf "${GRAY}────────────────────────────────────────────────────────────${RESET}\n"; }

banner() {
  if [[ -t 1 && "${MP_CLI:-0}" != "1" ]]; then clear 2>/dev/null || true; fi
  printf "${BOLD_CYAN}"
  cat <<'EOF'
 __  __                  ____                  _
|  \/  | ___  _ __   ___|  _ \ __ _ _ __   ___| |
| |\/| |/ _ \| '_ \ / _ \ |_) / _` | '_ \ / _ \ |
| |  | | (_) | | | | (_) |  __/ (_| | | | |  __/ |
|_|  |_|\___/|_| |_|\___/|_|   \__,_|_| |_|\___|_|
EOF
  printf "${RESET}"
  printf "${BOLD}${MAGENTA}        MonoPanel Installer & Executer  v%s${RESET}\n" "$MP_VERSION"
  printf "${GRAY}                  Made by %s${RESET}\n" "$MP_AUTHOR"
  line
}

info()    { printf "${CYAN}➤ %s${RESET}\n" "$1"; }
success() { printf "${BOLD_GREEN}✔ %s${RESET}\n" "$1"; }
warn()    { printf "${BOLD_YELLOW}⚠ %s${RESET}\n" "$1"; }
error()   { printf "${BOLD_RED}✖ %s${RESET}\n" "$1" >&2; }
step()    { printf "${BLUE}${BOLD}[STEP]${RESET} ${BOLD}%s${RESET}\n" "$1"; }
note()    { printf "${GRAY}  %s${RESET}\n" "$1"; }

press_enter() {
  [[ "${MP_CLI:-0}" == "1" || "${MP_ASSUME_DEFAULTS:-0}" == "1" ]] && return 0
  printf "\n${GRAY}Press Enter to return to the menu...${RESET}"
  read -r _ || true
}

# ask "Prompt" "default"  -> answer on stdout (prompt goes to stderr)
ask() {
  local prompt="$1" def="${2:-}" reply=""
  if [[ "${MP_ASSUME_DEFAULTS:-0}" == "1" ]]; then printf '%s' "$def"; return 0; fi
  if [[ -n $def ]]; then
    printf "${YELLOW}%s ${GRAY}[%s]${YELLOW}: ${RESET}" "$prompt" "$def" >&2
  else
    printf "${YELLOW}%s: ${RESET}" "$prompt" >&2
  fi
  read -r reply || reply=""
  printf '%s' "${reply:-$def}"
}

ask_secret() {
  local prompt="$1" reply=""
  [[ "${MP_ASSUME_DEFAULTS:-0}" == "1" ]] && return 0   # never block automation on a hidden prompt
  printf "${YELLOW}%s: ${RESET}" "$prompt" >&2
  read -rs reply || reply=""
  printf '\n' >&2
  printf '%s' "$reply"
}

# confirm "Prompt" [y|n default]
confirm() {
  local prompt="$1" def="${2:-n}" reply="" hint="[y/N]"
  [[ $def == y ]] && hint="[Y/n]"
  if [[ "${MP_ASSUME_DEFAULTS:-0}" == "1" ]]; then [[ $def == y ]]; return $?; fi
  printf "${YELLOW}%s %s: ${RESET}" "$prompt" "$hint" >&2
  read -r reply || reply=""
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ----------------------------------------------------------------------------
# Tiny key=value stores (state file + .env editing)
# ----------------------------------------------------------------------------
kv_set() {  # kv_set <file> <key> <value>   (replaces or appends KEY=value)
  local f="$1" k="$2" v="$3" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/mp.XXXXXX")" || return 1
  K="$k" V="$v" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; done = 0 }
    { if (index($0, k "=") == 1) { if (!done) { print k "=" v; done = 1 } next } print }
    END { if (!done) print k "=" v }' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

kv_get() {  # kv_get <file> <key> [default]
  local f="$1" k="$2" d="${3:-}" v=""
  [[ -f $f ]] && v="$(grep -E "^${k}=" "$f" 2>/dev/null | tail -n1 | cut -d= -f2-)"
  v="${v%\"}"; v="${v#\"}"
  printf '%s' "${v:-$d}"
}

cfg_get() { kv_get "$CONFIG_FILE" "$1" "${2:-}"; }
cfg_set() { touch "$CONFIG_FILE" 2>/dev/null; kv_set "$CONFIG_FILE" "$1" "$2"; }

env_get() { kv_get "$PANEL_DIR/.env" "$1" "${2:-}"; }
env_set() {  # quotes the value when .env syntax requires it
  local k="$1" v="$2"
  if [[ "$v" =~ [[:space:]\#\"\'\\] ]]; then
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="\"$v\""
  fi
  kv_set "$PANEL_DIR/.env" "$k" "$v"
}

rand_alnum() {  # rand_alnum [length]  (status is always 0; tr gets SIGPIPE by design)
  local s
  s="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "${1:-24}")"
  printf '%s' "$s"
  return 0
}

# ----------------------------------------------------------------------------
# Environment / paths
# ----------------------------------------------------------------------------
init_env() {
  MP_HOME_DEFAULT_ROOT="/var/lib/monopanel"
  if (( IS_ROOT )); then
    MP_HOME="${MONOPANEL_HOME:-$MP_HOME_DEFAULT_ROOT}"
    LOG_DIR="${MONOPANEL_LOGS:-/var/log/monopanel}"
    BIN_DIR="/usr/local/bin"
    DEF_PANEL_DIR="/var/www/monopanel"
  else
    MP_HOME="${MONOPANEL_HOME:-${HOME:-/tmp}/.monopanel}"
    LOG_DIR="$MP_HOME/logs"
    BIN_DIR="${HOME:-/tmp}/.local/bin"
    DEF_PANEL_DIR="${HOME:-/tmp}/monopanel"
    PATH="$BIN_DIR:$PATH"
  fi
  CONFIG_FILE="$MP_HOME/config.env"
  SVC_DIR="$MP_HOME/services"
  INSTALL_LOG="$LOG_DIR/install.log"
  WEB_HOME="$MP_HOME/webhome"

  if ! mkdir -p "$MP_HOME" "$LOG_DIR" "$SVC_DIR" "$MP_HOME/run" "$MP_HOME/tmp" "$MP_HOME/backups" "$MP_HOME/secrets" 2>/dev/null; then
    error "Cannot create $MP_HOME — run as root (sudo) or set MONOPANEL_HOME to a writable folder."
    return 1
  fi
  chmod 755 "$MP_HOME" "$SVC_DIR" "$MP_HOME/run" 2>/dev/null
  chmod 700 "$MP_HOME/secrets" 2>/dev/null
  touch "$CONFIG_FILE" "$INSTALL_LOG" 2>/dev/null

  PANEL_DIR="${MONOPANEL_DIR:-$(cfg_get PANEL_DIR "$DEF_PANEL_DIR")}"
  PANEL_REPO="${MONOPANEL_REPO:-$(cfg_get PANEL_REPO "$REPO_URL_DEFAULT")}"
  PANEL_BRANCH="${MONOPANEL_BRANCH:-$(cfg_get PANEL_BRANCH "$BRANCH_DEFAULT")}"
  PANEL_PORT="$(cfg_get PANEL_PORT "")"
  SCRIPT_URL="${MONOPANEL_SCRIPT_URL:-$(cfg_get SCRIPT_URL "$SCRIPT_URL_DEFAULT")}"
  FPM_PORT="$(cfg_get FPM_PORT 9074)"
  VITE_PORT="$(cfg_get VITE_PORT 5173)"
  return 0
}

# ----------------------------------------------------------------------------
# System detection
# ----------------------------------------------------------------------------
detect_system() {
  ARCH_RAW="$(uname -m)"
  case "$ARCH_RAW" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv6l) ARCH="arm" ;;
    i386|i686)     ARCH="386" ;;
    *)             ARCH="$ARCH_RAW" ;;
  esac

  OS_ID="unknown"; OS_LIKE=""; OS_VER=""; OS_CODENAME=""; OS_PRETTY="Linux"
  if [[ -r /etc/os-release ]]; then
    OS_ID="$(. /etc/os-release; echo "${ID:-unknown}")"
    OS_LIKE="$(. /etc/os-release; echo "${ID_LIKE:-}")"
    OS_VER="$(. /etc/os-release; echo "${VERSION_ID:-}")"
    OS_CODENAME="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"
    OS_PRETTY="$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")"
  fi

  if   command -v apt-get >/dev/null 2>&1; then PKG="apt"
  elif command -v dnf     >/dev/null 2>&1; then PKG="dnf"
  elif command -v yum     >/dev/null 2>&1; then PKG="yum"
  elif command -v apk     >/dev/null 2>&1; then PKG="apk"
  elif command -v pacman  >/dev/null 2>&1; then PKG="pacman"
  elif command -v zypper  >/dev/null 2>&1; then PKG="zypper"
  else PKG="none"; fi

  IN_CONTAINER=0
  if [[ -f /.dockerenv || -f /run/.containerenv ]]; then IN_CONTAINER=1
  elif grep -qaE 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then IN_CONTAINER=1; fi
}

# Is a real systemd running as PID 1?  (MP_INIT=builtin|systemd overrides)
is_systemd() {
  case "${MP_INIT:-auto}" in
    builtin) return 1 ;;
    systemd) return 0 ;;
  esac
  [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}
# systemd units can only be written by root
use_systemd() { (( IS_ROOT )) && is_systemd; }
init_label() { if use_systemd; then echo "systemd"; else echo "built-in supervisor (no systemd needed)"; fi; }

mem_total_mb() { awk '/^MemTotal:/ { printf "%d", $2/1024 }' /proc/meminfo 2>/dev/null; }
mem_limit_mb() {  # container-aware (cgroup v1/v2)
  local total lim f
  total="$(mem_total_mb)"; total="${total:-0}"
  for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
    if [[ -r $f ]]; then
      lim="$(cat "$f" 2>/dev/null)"
      if [[ $lim =~ ^[0-9]+$ ]]; then
        lim=$(( lim / 1024 / 1024 ))
        (( lim > 0 && lim < total )) && total=$lim
      fi
    fi
  done
  printf '%s' "$total"
}
disk_free_mb() { df -Pm "${1:-/}" 2>/dev/null | awk 'NR==2 { print $4 }'; }

public_ip() {
  local ip=""
  ip="$(curl -fsS4 --max-time 4 https://api.ipify.org 2>/dev/null)"
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "${ip:-127.0.0.1}"
}

port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -E "[:.]${p}\$" >/dev/null
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk 'NR>2 {print $4}' | grep -E "[:.]${p}\$" >/dev/null
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
  fi
}

default_panel_port() {
  local p
  [[ -n ${PANEL_PORT:-} ]] && { printf '%s' "$PANEL_PORT"; return; }
  if (( IS_ROOT )) && ! port_in_use 80; then printf '80'; return; fi
  for p in 8080 8081 8082 8090 8000; do
    port_in_use "$p" || { printf '%s' "$p"; return; }
  done
  printf '8080'
}

detect_timezone() {
  local tz=""
  [[ -r /etc/timezone ]] && tz="$(head -n1 /etc/timezone 2>/dev/null)"
  [[ -z $tz ]] && tz="$(readlink -f /etc/localtime 2>/dev/null | sed -n 's|.*/zoneinfo/||p')"
  printf '%s' "${tz:-UTC}"
}

run_root() {
  if (( IS_ROOT )); then "$@"
  elif [[ -n "${SUDO:-}" ]]; then sudo "$@"
  else "$@"; fi
}

need_root() {  # need_root "what needs it"
  (( IS_ROOT )) && return 0
  error "$1 needs root. Re-run with: sudo bash monopanel.sh"
  return 1
}

# ----------------------------------------------------------------------------
# Logged command runners
# ----------------------------------------------------------------------------
run_logged() {  # run_logged "Label" cmd...   (output -> install.log)
  local label="$1"; shift
  info "$label"
  if "$@" >>"$INSTALL_LOG" 2>&1; then return 0; fi
  error "Failed: $label   (details: $INSTALL_LOG)"
  tail -n 12 "$INSTALL_LOG" 2>/dev/null | sed 's/^/    /'
  return 1
}

run_live() {  # run_live "Label" cmd...      (streams output + logs it)
  local label="$1" rc; shift
  info "$label"
  "$@" 2>&1 | tee -a "$INSTALL_LOG"
  rc=${PIPESTATUS[0]}
  (( rc == 0 )) || error "Failed: $label (exit code $rc)"
  return "$rc"
}

# ----------------------------------------------------------------------------
# Package management (apt / dnf / yum / apk; others: detection only)
# ----------------------------------------------------------------------------
PKG_UPDATED=0
POLICY_MADE=0

policy_block() {  # stop apt from auto-starting daemons in non-systemd containers
  if [[ $PKG == apt ]] && ! is_systemd && (( IS_ROOT )) && [[ ! -e /usr/sbin/policy-rc.d ]]; then
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d && POLICY_MADE=1
  fi
}
policy_unblock() { if (( POLICY_MADE )); then rm -f /usr/sbin/policy-rc.d; POLICY_MADE=0; fi; }

pkg_update() {
  (( PKG_UPDATED )) && return 0
  case "$PKG" in
    apt) run_root env DEBIAN_FRONTEND=noninteractive apt-get update -y >>"$INSTALL_LOG" 2>&1 ;;
    apk) run_root apk update >>"$INSTALL_LOG" 2>&1 ;;
    *)   : ;;
  esac
  PKG_UPDATED=1
}

pkg_install() {
  (( $# )) || return 0
  local rc=0
  pkg_update
  case "$PKG" in
    apt)
      policy_block
      run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold "$@" >>"$INSTALL_LOG" 2>&1; rc=$?
      policy_unblock ;;
    dnf) run_root dnf install -y "$@" >>"$INSTALL_LOG" 2>&1; rc=$? ;;
    yum) run_root yum install -y "$@" >>"$INSTALL_LOG" 2>&1; rc=$? ;;
    apk) run_root apk add --no-cache "$@" >>"$INSTALL_LOG" 2>&1; rc=$? ;;
    *)   rc=1 ;;
  esac
  return "$rc"
}

pkg_install_logged() {  # pkg_install_logged "Label" pkgs...
  local label="$1"; shift
  info "$label"
  if pkg_install "$@"; then return 0; fi
  error "Package install failed: $*   (details: $INSTALL_LOG)"
  tail -n 12 "$INSTALL_LOG" 2>/dev/null | sed 's/^/    /'
  return 1
}

pkg_install_optional() { pkg_install "$@" || warn "Optional package(s) unavailable: $*"; return 0; }

ensure_base_deps() {
  step "Base packages"
  local need=() nice=() c
  for c in curl git tar unzip openssl; do command -v "$c" >/dev/null 2>&1 || need+=("$c"); done
  [[ -d /etc/ssl/certs ]] || need+=(ca-certificates)
  # Nice-to-have (port checks / process listing) — never fatal.
  case "$PKG" in
    apt)     command -v ss >/dev/null 2>&1 || nice+=(iproute2); command -v ps >/dev/null 2>&1 || nice+=(procps) ;;
    dnf|yum) command -v ss >/dev/null 2>&1 || nice+=(iproute);  command -v ps >/dev/null 2>&1 || nice+=(procps-ng) ;;
    apk)     command -v ss >/dev/null 2>&1 || nice+=(iproute2); command -v ps >/dev/null 2>&1 || nice+=(procps)
             command -v bash >/dev/null 2>&1 || need+=(bash) ;;
  esac
  if (( ${#need[@]} == 0 )); then
    success "curl, git, tar, unzip, openssl already present."
  else
    need_root "Installing packages (${need[*]})" || return 1
    if [[ $PKG == none ]]; then
      error "Missing: ${need[*]} — and no supported package manager (apt/dnf/yum/apk) was found."
      warn "Install PHP >= 8.4 (+fpm), Composer, Node >= 18, nginx, MariaDB, git, curl manually, then re-run."
      return 1
    fi
    pkg_install_logged "Installing: ${need[*]}" "${need[@]}" || return 1
  fi
  if (( ${#nice[@]} && IS_ROOT )) && [[ $PKG != none ]]; then pkg_install "${nice[@]}" >/dev/null 2>&1; fi
  return 0
}

# ----------------------------------------------------------------------------
# Web user (owner of the panel files / runner of php-fpm, queue, scheduler)
# ----------------------------------------------------------------------------
detect_web_user() {
  local u
  if (( ! IS_ROOT )); then WEB_USER="$(id -un)"; WEB_GROUP="$(id -gn)"; return 0; fi
  WEB_USER="$(cfg_get WEB_USER "")"
  if [[ -z $WEB_USER ]] || ! id "$WEB_USER" >/dev/null 2>&1; then
    WEB_USER=""
    for u in www-data nginx apache http; do
      if id "$u" >/dev/null 2>&1; then WEB_USER="$u"; break; fi
    done
  fi
  if [[ -z $WEB_USER ]]; then
    mkdir -p "$WEB_HOME"
    if command -v useradd >/dev/null 2>&1; then
      useradd --system --home-dir "$WEB_HOME" --shell /usr/sbin/nologin monopanel >>"$INSTALL_LOG" 2>&1
    elif command -v adduser >/dev/null 2>&1; then
      adduser -S -D -H -h "$WEB_HOME" -s /sbin/nologin monopanel >>"$INSTALL_LOG" 2>&1
    fi
    WEB_USER="monopanel"
  fi
  WEB_GROUP="$(id -gn "$WEB_USER" 2>/dev/null || echo "$WEB_USER")"
  cfg_set WEB_USER "$WEB_USER"
}

as_user() {  # as_user <user> cmd...   (no-op switch when already that user)
  local u="$1"; shift
  if [[ -z $u || $u == "$(id -un)" ]]; then "$@"; return $?; fi
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$u" -- "$@"
  else
    su -s /bin/bash "$u" -c "$(printf '%q ' "$@")"
  fi
}

# ----------------------------------------------------------------------------
# Service manager: systemd units when available, otherwise a tiny built-in
# supervisor (auto-restart, PID files, log files) that works in ANY container.
# ----------------------------------------------------------------------------
SVC_UNIT_AFTER=""; SVC_UNIT_REQUIRES=""; SVC_UNIT_EXTRA=""

svc_unit() { case "$1" in wings) echo wings ;; docker) echo docker ;; *) echo "monopanel-$1" ;; esac; }

svc_define() {  # svc_define <name> <workdir> <user|""> <envfile|""> <description> <cmd...>
  local name="$1" dir="$2" user="$3" envf="$4" desc="$5"; shift 5
  local exe="$SVC_DIR/$name.exec"
  {
    echo '#!/usr/bin/env bash'
    printf 'cd %q || exit 1\n' "$dir"
    if [[ -n $envf ]]; then printf 'set -a; . %q; set +a\n' "$envf"; fi
    printf 'exec'; printf ' %q' "$@"; printf '\n'
  } > "$exe"
  chmod 755 "$exe"
  printf '%s' "$user" > "$SVC_DIR/$name.user"
  if use_systemd; then svc_write_unit "$name" "$user" "$desc" "$exe"; fi
  SVC_UNIT_AFTER=""; SVC_UNIT_REQUIRES=""; SVC_UNIT_EXTRA=""
  return 0
}

svc_write_unit() {
  local name="$1" user="$2" desc="$3" exe="$4" unit
  unit="$(svc_unit "$name")"
  {
    echo "[Unit]"
    echo "Description=$desc"
    echo "After=network.target ${SVC_UNIT_AFTER}"
    [[ -n $SVC_UNIT_REQUIRES ]] && echo "Requires=${SVC_UNIT_REQUIRES}"
    echo
    echo "[Service]"
    echo "Type=simple"
    [[ -n $user ]] && echo "User=$user"
    echo "ExecStart=$exe"
    echo "Restart=always"
    echo "RestartSec=3"
    echo "LimitNOFILE=65535"
    echo "StandardOutput=append:$LOG_DIR/$name.log"
    echo "StandardError=append:$LOG_DIR/$name.log"
    [[ -n $SVC_UNIT_EXTRA ]] && printf '%b\n' "$SVC_UNIT_EXTRA"
    echo
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } > "/etc/systemd/system/$unit.service"
  systemctl daemon-reload >/dev/null 2>&1
  return 0
}

svc_ensure_runner() {
  cat > "$SVC_DIR/mp-runner.sh" <<'RUNNER_EOF'
#!/usr/bin/env bash
# MonoPanel built-in supervisor — keeps one service alive without systemd.
# Usage: mp-runner.sh <name> [user]    (env: MP_SVC_DIR, MP_LOG_DIR)
set -m
name="$1"; user="${2:-}"
base="${MP_SVC_DIR:?}"; log="${MP_LOG_DIR:?}/$name.log"
pidf="$base/$name.pid"; cpidf="$base/$name.cpid"
echo $$ > "$pidf"
child=""; stopping=0; fails=0

on_term() {
  stopping=1
  if [[ -n $child ]]; then
    kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null
  fi
}
trap on_term TERM INT HUP

if [[ -n $user && $user != "$(id -un)" ]]; then
  if command -v runuser >/dev/null 2>&1; then cmd=(runuser -u "$user" -- "$base/$name.exec")
  else cmd=(su -s /bin/bash "$user" -c "$base/$name.exec"); fi
else
  cmd=("$base/$name.exec")
fi

while (( ! stopping )); do
  started=$SECONDS
  echo "[$(date '+%F %T')] starting $name" >> "$log"
  "${cmd[@]}" >> "$log" 2>&1 &
  child=$!
  echo "$child" > "$cpidf"
  wait "$child"; code=$?
  if (( stopping )); then
    for _ in $(seq 1 100); do kill -0 "$child" 2>/dev/null || break; sleep 0.1; done
    kill -KILL -- "-$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null
    break
  fi
  echo "[$(date '+%F %T')] $name exited with code $code" >> "$log"
  if (( SECONDS - started < 5 )); then fails=$(( fails + 1 )); else fails=0; fi
  if (( fails >= 5 )); then
    echo "[$(date '+%F %T')] $name is crash-looping — giving up. Fix the error above, then start it again." >> "$log"
    break
  fi
  sleep 3
done
rm -f "$pidf" "$cpidf"
RUNNER_EOF
  chmod 755 "$SVC_DIR/mp-runner.sh"
}

svc_running() {
  local name="$1" pid
  if use_systemd; then systemctl is-active --quiet "$(svc_unit "$name")"; return $?; fi
  pid="$(cat "$SVC_DIR/$name.pid" 2>/dev/null)"
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null
}

svc_pid() {
  if use_systemd; then systemctl show -p MainPID --value "$(svc_unit "$1")" 2>/dev/null; return; fi
  cat "$SVC_DIR/$1.cpid" 2>/dev/null
}

svc_start() {
  local name="$1" unit i
  [[ -x "$SVC_DIR/$name.exec" ]] || { error "Service '$name' is not defined yet."; return 1; }
  svc_running "$name" && return 0
  if use_systemd; then
    unit="$(svc_unit "$name")"
    systemctl enable "$unit" >>"$LOG_DIR/services.log" 2>&1
    if ! systemctl start "$unit" >>"$LOG_DIR/services.log" 2>&1; then
      error "systemctl start $unit failed (see: journalctl -u $unit)"; return 1
    fi
  else
    svc_ensure_runner
    rm -f "$SVC_DIR/$name.pid" "$SVC_DIR/$name.cpid"
    export MP_SVC_DIR="$SVC_DIR" MP_LOG_DIR="$LOG_DIR"
    if command -v setsid >/dev/null 2>&1; then
      setsid nohup "$SVC_DIR/mp-runner.sh" "$name" "$(cat "$SVC_DIR/$name.user" 2>/dev/null)" >/dev/null 2>&1 &
    else
      nohup "$SVC_DIR/mp-runner.sh" "$name" "$(cat "$SVC_DIR/$name.user" 2>/dev/null)" >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
      [[ -s "$SVC_DIR/$name.pid" ]] && break
      sleep 0.3
    done
    sleep 2   # a real start survives this; an instant crash does not
    local cp; cp="$(cat "$SVC_DIR/$name.cpid" 2>/dev/null)"
    [[ -n $cp ]] && kill -0 "$cp" 2>/dev/null
    return $?
  fi
  sleep 1
  svc_running "$name"
}

svc_stop() {
  local name="$1" pid i
  if use_systemd; then
    # disable too, so a service you stopped does not come back at the next reboot
    systemctl disable --now "$(svc_unit "$name")" >>"$LOG_DIR/services.log" 2>&1
    return 0
  fi
  pid="$(cat "$SVC_DIR/$name.pid" 2>/dev/null)"
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    for i in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  fi
  rm -f "$SVC_DIR/$name.pid" "$SVC_DIR/$name.cpid"
  return 0
}

svc_restart() { svc_stop "$1"; svc_start "$1"; }

svc_defined() { [[ -x "$SVC_DIR/$1.exec" ]]; }

svc_state() {  # colored one-liner for status pages
  local name="$1" pid
  if ! svc_defined "$name"; then printf "${GRAY}not configured${RESET}"; return; fi
  if svc_running "$name"; then
    pid="$(svc_pid "$name")"
    printf "${BOLD_GREEN}running${RESET}${GRAY}%s${RESET}" "${pid:+ (pid $pid)}"
  else
    printf "${BOLD_RED}stopped${RESET}"
  fi
}

# ----------------------------------------------------------------------------
# PHP (>= 8.4)
# ----------------------------------------------------------------------------
detect_php() {
  local c
  PHP_BIN=""
  for c in php8.5 php8.4 php85 php84 php; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -r 'exit(PHP_VERSION_ID >= 80400 ? 0 : 1);' >/dev/null 2>&1; then
      PHP_BIN="$(command -v "$c")"; return 0
    fi
  done
  return 1
}

detect_fpm() {
  local c f
  FPM_BIN=""
  for c in php-fpm8.5 php-fpm8.4 php-fpm85 php-fpm84 php-fpm8 php-fpm; do
    if command -v "$c" >/dev/null 2>&1; then FPM_BIN="$(command -v "$c")"; return 0; fi
  done
  for f in /usr/sbin/php-fpm* /usr/local/sbin/php-fpm*; do
    [[ -x $f ]] && { FPM_BIN="$f"; return 0; }
  done
  return 1
}

missing_php_exts() {
  [[ -n ${PHP_BIN:-} ]] || return 0
  "$PHP_BIN" -r '$need = ["bcmath","ctype","curl","dom","fileinfo","gd","mbstring","openssl","pdo","pdo_mysql","posix","tokenizer","xml","zip","intl"];
    $m = []; foreach ($need as $e) { if (!extension_loaded($e)) { $m[] = $e; } } echo implode(" ", $m);' 2>/dev/null
}

install_php_apt() {
  local v="8.4" cand
  cand="$(apt-cache policy "php${v}-cli" 2>/dev/null | awk '/Candidate:/ {print $2}')"
  if [[ -z $cand || $cand == "(none)" ]]; then
    info "PHP ${v} is not in the default repositories — adding a PHP repository"
    pkg_install_logged "Installing repository helpers" ca-certificates curl gnupg lsb-release apt-transport-https || return 1
    if [[ $OS_ID == ubuntu || $OS_LIKE == *ubuntu* ]]; then
      pkg_install software-properties-common >/dev/null 2>&1
      run_logged "Adding ppa:ondrej/php" run_root env LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php || return 1
    else
      local codename="${OS_CODENAME:-$(lsb_release -sc 2>/dev/null)}"
      run_logged "Fetching the Sury PHP signing key" run_root curl -fsSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg || return 1
      echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ ${codename} main" \
        | run_root tee /etc/apt/sources.list.d/sury-php.list >/dev/null
    fi
    PKG_UPDATED=0; pkg_update
  fi
  local list=(cli fpm common mysql mbstring xml curl zip gd bcmath intl gmp)
  local pk=() e
  for e in "${list[@]}"; do pk+=("php${v}-${e}"); done
  pkg_install_logged "Installing PHP ${v} + extensions" "${pk[@]}" || return 1
  pkg_install_optional "php${v}-opcache"
  return 0
}

install_php_rpm() {
  local rel
  rel="$(rpm -E %rhel 2>/dev/null)"
  if [[ -n $rel && $rel != "%rhel" && $OS_ID != fedora ]]; then
    info "Enabling EPEL + Remi (PHP 8.4)"
    pkg_install epel-release >/dev/null 2>&1
    pkg_install "https://rpms.remirepo.net/enterprise/remi-release-${rel}.rpm" >/dev/null 2>&1
    run_root dnf -y module reset php >>"$INSTALL_LOG" 2>&1
    run_root dnf -y module enable php:remi-8.4 >>"$INSTALL_LOG" 2>&1
  fi
  pkg_install_logged "Installing PHP + extensions" php-cli php-fpm php-common php-mysqlnd php-mbstring php-xml php-gd php-bcmath php-intl php-gmp php-process || return 1
  pkg_install_optional php-pecl-zip php-zip php-opcache
  return 0
}

install_php_apk() {
  local v="84" pk=() e
  for e in "" -fpm -common -mysqlnd -pdo -pdo_mysql -mbstring -xml -dom -simplexml -xmlwriter -xmlreader -tokenizer -fileinfo -openssl -curl -zip -gd -bcmath -intl -gmp -session -ctype -posix -iconv -phar -sodium -pcntl; do
    pk+=("php${v}${e}")
  done
  pkg_install_logged "Installing PHP ${v} + extensions (Alpine)" "${pk[@]}" || return 1
  [[ -e /usr/bin/php ]] || run_root ln -s "/usr/bin/php${v}" /usr/bin/php
  return 0
}

install_php() {
  step "PHP >= 8.4 (+ php-fpm)"
  detect_php; detect_fpm
  local miss=""
  [[ -n ${PHP_BIN:-} ]] && miss="$(missing_php_exts)"
  if [[ -z ${PHP_BIN:-} || -z ${FPM_BIN:-} || -n $miss ]]; then
    need_root "Installing PHP" || return 1
    case "$PKG" in
      apt)     install_php_apt || return 1 ;;
      dnf|yum) install_php_rpm || return 1 ;;
      apk)     install_php_apk || return 1 ;;
      *)       error "Unsupported package manager. Install PHP >= 8.4 with fpm + extensions (${miss:-bcmath gd mbstring xml zip intl pdo_mysql posix}) manually."; return 1 ;;
    esac
    detect_php
    detect_fpm
  fi
  if [[ -z ${PHP_BIN:-} ]]; then error "PHP >= 8.4 is still not available after installation."; return 1; fi
  success "PHP $("$PHP_BIN" -r 'echo PHP_VERSION;') → $PHP_BIN"
  miss="$(missing_php_exts)"
  if [[ -n $miss ]]; then error "Missing PHP extensions: $miss"; return 1; fi
  if [[ -z ${FPM_BIN:-} ]]; then error "php-fpm binary not found (install the php-fpm package)."; return 1; fi
  success "php-fpm → $FPM_BIN"
  return 0
}

# ----------------------------------------------------------------------------
# Composer
# ----------------------------------------------------------------------------
ensure_composer() {
  COMPOSER_BIN="$(command -v composer 2>/dev/null || true)"
  if [[ -n $COMPOSER_BIN ]]; then success "Composer found: $COMPOSER_BIN"; return 0; fi
  info "Installing Composer"
  local setup="$MP_HOME/tmp/composer-setup.php"
  curl -fsSL https://getcomposer.org/installer -o "$setup" >>"$INSTALL_LOG" 2>&1 || { error "Could not download the Composer installer."; return 1; }
  mkdir -p "$BIN_DIR"
  "$PHP_BIN" "$setup" --quiet --install-dir="$BIN_DIR" --filename=composer >>"$INSTALL_LOG" 2>&1
  rm -f "$setup"
  COMPOSER_BIN="$BIN_DIR/composer"
  [[ -x $COMPOSER_BIN ]] || { error "Composer installation failed."; return 1; }
  success "Composer installed: $COMPOSER_BIN"
}

composer_run() { ( cd "$PANEL_DIR" && COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1 "$PHP_BIN" "$COMPOSER_BIN" "$@" ); }

# ----------------------------------------------------------------------------
# Node.js (>= 18) + pnpm
# ----------------------------------------------------------------------------
node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null; }

ensure_pnpm() {
  command -v pnpm >/dev/null 2>&1 && return 0
  if command -v corepack >/dev/null 2>&1; then
    run_root corepack enable >>"$INSTALL_LOG" 2>&1
    run_root corepack prepare pnpm@9.0.6 --activate >>"$INSTALL_LOG" 2>&1
    command -v pnpm >/dev/null 2>&1 && return 0
  fi
  run_root npm install -g pnpm@9 >>"$INSTALL_LOG" 2>&1
  command -v pnpm >/dev/null 2>&1
}

install_node() {
  step "Node.js (>= 18) + pnpm"
  local major=0
  command -v node >/dev/null 2>&1 && major="$(node_major)"
  if (( ${major:-0} < 18 )); then
    need_root "Installing Node.js" || return 1
    case "$PKG" in
      apt)     run_logged "Adding NodeSource repository (Node 22)" run_root bash -c 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash -' || return 1
               pkg_install_logged "Installing Node.js" nodejs || return 1 ;;
      dnf|yum) run_logged "Adding NodeSource repository (Node 22)" run_root bash -c 'curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -' || return 1
               pkg_install_logged "Installing Node.js" nodejs || return 1 ;;
      apk)     pkg_install_logged "Installing Node.js" nodejs npm || return 1 ;;
      *)       error "Install Node.js >= 18 manually, then re-run."; return 1 ;;
    esac
  fi
  command -v node >/dev/null 2>&1 || { error "Node.js is still missing."; return 1; }
  success "Node.js $(node -v)"
  if ! ensure_pnpm; then error "Could not set up pnpm."; return 1; fi
  success "pnpm $(pnpm -v 2>/dev/null)"
  NODE_BIN="$(command -v node)"
  return 0
}

# ----------------------------------------------------------------------------
# nginx
# ----------------------------------------------------------------------------
detect_nginx() { NGINX_BIN="$(command -v nginx 2>/dev/null || true)"; [[ -n $NGINX_BIN ]]; }

ensure_nginx() {
  step "nginx"
  if detect_nginx; then success "nginx found: $NGINX_BIN"; return 0; fi
  need_root "Installing nginx" || return 1
  pkg_install_logged "Installing nginx" nginx || return 1
  detect_nginx || { error "nginx binary not found after install."; return 1; }
  # We run our own nginx instance (own config/port), so park the distro one.
  if use_systemd; then
    systemctl disable --now nginx >/dev/null 2>&1
  fi
  success "nginx installed: $NGINX_BIN"
}

# ----------------------------------------------------------------------------
# MariaDB / MySQL + Redis
# ----------------------------------------------------------------------------
detect_db_bins() {
  DB_SERVER_BIN="$(command -v mariadbd 2>/dev/null || command -v mysqld 2>/dev/null || true)"
  DB_CLIENT_BIN="$(command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null || true)"
  DB_ADMIN_BIN="$(command -v mariadb-admin 2>/dev/null || command -v mysqladmin 2>/dev/null || true)"
  DB_DUMP_BIN="$(command -v mariadb-dump 2>/dev/null || command -v mysqldump 2>/dev/null || true)"
  [[ -n $DB_SERVER_BIN && -n $DB_CLIENT_BIN ]]
}

install_db_server() {
  step "MariaDB (local database)"
  if ! detect_db_bins; then
    need_root "Installing MariaDB" || return 1
    case "$PKG" in
      apt)     pkg_install_logged "Installing MariaDB" mariadb-server mariadb-client || return 1 ;;
      dnf|yum) pkg_install_logged "Installing MariaDB" mariadb-server || return 1 ;;
      apk)     pkg_install_logged "Installing MariaDB" mariadb mariadb-client || return 1 ;;
      *)       error "Install MariaDB/MySQL manually (or pick an external database)."; return 1 ;;
    esac
    detect_db_bins || { error "MariaDB binaries not found after install."; return 1; }
  fi
  success "Database server: $DB_SERVER_BIN"
  return 0
}

db_ping() {
  detect_db_bins >/dev/null 2>&1
  [[ -n ${DB_ADMIN_BIN:-} ]] || return 1
  "$DB_ADMIN_BIN" ping >/dev/null 2>&1 || "$DB_ADMIN_BIN" --protocol=tcp -h127.0.0.1 ping >/dev/null 2>&1
}

init_db_datadir() {
  local dd="/var/lib/mysql" inst
  [[ -d $dd/mysql ]] && return 0
  mkdir -p "$dd"; chown mysql:mysql "$dd" 2>/dev/null
  inst="$(command -v mariadb-install-db 2>/dev/null || command -v mysql_install_db 2>/dev/null || true)"
  [[ -n $inst ]] || return 1
  info "Initialising the database data directory"
  "$inst" --user=mysql --datadir="$dd" --auth-root-authentication-method=socket >>"$INSTALL_LOG" 2>&1 \
    || "$inst" --user=mysql --datadir="$dd" >>"$INSTALL_LOG" 2>&1
}

ensure_db_running() {
  [[ "$(cfg_get DB_MODE local)" == "local" ]] || return 0
  detect_db_bins || { error "MariaDB is not installed. Run 'Install Panel' first."; return 1; }
  db_ping && return 0
  info "Starting MariaDB"
  local u started=0
  if use_systemd; then
    for u in mariadb mysql mysqld; do
      if systemctl cat "$u.service" >/dev/null 2>&1 && systemctl start "$u" >>"$LOG_DIR/services.log" 2>&1; then
        systemctl enable "$u" >/dev/null 2>&1; started=1; break
      fi
    done
  fi
  if (( ! started )); then
    init_db_datadir
    svc_define mariadb / "" "" "MariaDB (MonoPanel)" bash -c \
      "mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld; exec '$DB_SERVER_BIN' --user=mysql --datadir=/var/lib/mysql --bind-address=127.0.0.1 --innodb-buffer-pool-size=${MP_DB_BUFFER:-128M}"
    svc_start mariadb
  fi
  local i
  for i in $(seq 1 60); do db_ping && { success "MariaDB is up."; return 0; }; sleep 1; done
  error "MariaDB did not come up. Last log lines:"
  tail -n 15 "$LOG_DIR/mariadb.log" 2>/dev/null | sed 's/^/    /'
  return 1
}

install_redis() {
  step "Redis (cache / queue / sessions)"
  if command -v redis-server >/dev/null 2>&1; then success "Redis found: $(command -v redis-server)"; return 0; fi
  need_root "Installing Redis" || return 1
  case "$PKG" in
    apt) pkg_install_logged "Installing Redis" redis-server || return 1 ;;
    dnf|yum|apk) pkg_install_logged "Installing Redis" redis || return 1 ;;
    *) error "Install Redis manually."; return 1 ;;
  esac
  command -v redis-server >/dev/null 2>&1
}

redis_ping() { command -v redis-cli >/dev/null 2>&1 && [[ "$(redis-cli -h 127.0.0.1 -p 6379 ping 2>/dev/null)" == "PONG" ]]; }

ensure_redis_running() {
  [[ "$(cfg_get USE_REDIS yes)" == "yes" ]] || return 0
  redis_ping && return 0
  info "Starting Redis"
  local u started=0 ruser=""
  if use_systemd; then
    for u in redis-server redis; do
      if systemctl cat "$u.service" >/dev/null 2>&1 && systemctl start "$u" >>"$LOG_DIR/services.log" 2>&1; then
        systemctl enable "$u" >/dev/null 2>&1; started=1; break
      fi
    done
  fi
  if (( ! started )); then
    mkdir -p "$MP_HOME/redis"
    if (( IS_ROOT )) && id redis >/dev/null 2>&1; then ruser="redis"; chown redis "$MP_HOME/redis" 2>/dev/null; fi
    svc_define redis "$MP_HOME/redis" "$ruser" "" "Redis (MonoPanel)" \
      "$(command -v redis-server)" --bind 127.0.0.1 --port 6379 --daemonize no --dir "$MP_HOME/redis" --save "300 10" --appendonly no
    svc_start redis
  fi
  local i
  for i in $(seq 1 20); do redis_ping && { success "Redis is up."; return 0; }; sleep 1; done
  error "Redis did not respond on 127.0.0.1:6379."
  tail -n 10 "$LOG_DIR/redis.log" 2>/dev/null | sed 's/^/    /'
  return 1
}

# ----------------------------------------------------------------------------
# Panel helpers
# ----------------------------------------------------------------------------
panel_installed() { [[ -f "$PANEL_DIR/artisan" && -f "$PANEL_DIR/.env" && -d "$PANEL_DIR/vendor" ]]; }

require_panel() {
  if panel_installed; then return 0; fi
  error "MonoPanel is not installed in $PANEL_DIR. Choose 'Install Panel' first."
  return 1
}

# Load everything needed to run artisan/services; used by every non-install action.
load_runtime() {
  detect_system
  detect_web_user
  detect_php   || { error "PHP >= 8.4 not found. Run 'Install Panel' first."; return 1; }
  detect_fpm   >/dev/null 2>&1
  detect_nginx >/dev/null 2>&1
  NODE_BIN="$(command -v node 2>/dev/null || true)"
  COMPOSER_BIN="$(command -v composer 2>/dev/null || true)"
  detect_db_bins >/dev/null 2>&1
  PANEL_PORT="$(cfg_get PANEL_PORT "$(default_panel_port)")"
  return 0
}

artisan() { ( cd "$PANEL_DIR" && as_user "$WEB_USER" env HOME="$WEB_HOME" "$PHP_BIN" artisan "$@" ); }

fix_perms() {
  mkdir -p "$PANEL_DIR/storage/logs" "$PANEL_DIR/storage/framework/cache" "$PANEL_DIR/storage/framework/sessions" \
           "$PANEL_DIR/storage/framework/views" "$PANEL_DIR/bootstrap/cache" "$WEB_HOME"
  if (( IS_ROOT )); then
    chown -R "$WEB_USER:$WEB_GROUP" "$PANEL_DIR" "$WEB_HOME" 2>/dev/null
  fi
  chmod -R u+rwX,g+rX,o+rX "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null
  [[ -f "$PANEL_DIR/.env" ]] && chmod 640 "$PANEL_DIR/.env"
  return 0
}

# ----------------------------------------------------------------------------
# Git (supports private repos through a GitHub token)
# ----------------------------------------------------------------------------
git_token() {
  if [[ -n ${MONOPANEL_GIT_TOKEN:-} ]]; then printf '%s' "$MONOPANEL_GIT_TOKEN"; return; fi
  cat "$MP_HOME/secrets/git.token" 2>/dev/null
}

mp_git() {
  local tok hdr
  tok="$(git_token)"
  export GIT_TERMINAL_PROMPT=0
  if [[ -n $tok ]]; then
    hdr="$(printf 'x-access-token:%s' "$tok" | base64 | tr -d '\n')"
    git -c "http.extraHeader=Authorization: Basic ${hdr}" -c "safe.directory=${PANEL_DIR}" "$@"
  else
    git -c "safe.directory=${PANEL_DIR}" "$@"
  fi
}

clone_panel() {
  step "Fetching MonoPanel ($PANEL_BRANCH) from GitHub"
  mkdir -p "$(dirname "$PANEL_DIR")"
  if [[ -d "$PANEL_DIR/.git" ]]; then success "Existing checkout found at $PANEL_DIR"; return 0; fi
  if [[ -d $PANEL_DIR && -n "$(ls -A "$PANEL_DIR" 2>/dev/null)" ]]; then
    error "$PANEL_DIR already exists and is not a git checkout — pick another MONOPANEL_DIR or empty it."
    return 1
  fi
  info "$PANEL_REPO"
  local out rc tok
  out="$(mp_git clone --depth 1 --branch "$PANEL_BRANCH" "$PANEL_REPO" "$PANEL_DIR" 2>&1)"; rc=$?
  if (( rc != 0 )); then
    printf '%s\n' "$out" >>"$INSTALL_LOG"
    if [[ "${MP_ASSUME_DEFAULTS:-0}" != "1" ]] && grep -qiE 'authentication|could not read|not found|403|401' <<<"$out"; then
      warn "GitHub refused access — the repository may be private."
      note "Create a token at github.com/settings/tokens (read access to the repo)."
      tok="$(ask_secret "GitHub token (Enter to abort)")"
      [[ -n $tok ]] || return 1
      printf '%s' "$tok" > "$MP_HOME/secrets/git.token"; chmod 600 "$MP_HOME/secrets/git.token"
      out="$(mp_git clone --depth 1 --branch "$PANEL_BRANCH" "$PANEL_REPO" "$PANEL_DIR" 2>&1)"; rc=$?
    fi
  fi
  if (( rc != 0 )); then
    error "git clone failed:"; printf '%s\n' "$out" | tail -n 8 | sed 's/^/    /'
    return 1
  fi
  success "Cloned → $PANEL_DIR ($(mp_git -C "$PANEL_DIR" rev-parse --short HEAD 2>/dev/null))"
}

# ----------------------------------------------------------------------------
# Database provisioning
# ----------------------------------------------------------------------------
setup_local_db() {  # setup_local_db <db> <user> <pass>
  local name="$1" user="$2" pass="$3" sql
  sql="CREATE DATABASE IF NOT EXISTS \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${user}'@'127.0.0.1' IDENTIFIED BY '${pass}';
CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pass}';
ALTER USER '${user}'@'127.0.0.1' IDENTIFIED BY '${pass}';
ALTER USER '${user}'@'localhost' IDENTIFIED BY '${pass}';
GRANT ALL PRIVILEGES ON \`${name}\`.* TO '${user}'@'127.0.0.1' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON \`${name}\`.* TO '${user}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;"
  if ! printf '%s\n' "$sql" | "$DB_CLIENT_BIN" -uroot >>"$INSTALL_LOG" 2>&1; then
    error "Could not create the database/user (see $INSTALL_LOG)."
    return 1
  fi
  success "Database '${name}' and user '${user}' are ready."
}

test_db_connection() {  # host port db user pass
  MP_H="$1" MP_P="$2" MP_D="$3" MP_U="$4" MP_W="$5" "$PHP_BIN" -r '
    try { new PDO("mysql:host=".getenv("MP_H").";port=".getenv("MP_P").";dbname=".getenv("MP_D"), getenv("MP_U"), getenv("MP_W")); exit(0); }
    catch (Throwable $e) { fwrite(STDERR, $e->getMessage().PHP_EOL); exit(1); }'
}

# ----------------------------------------------------------------------------
# .env
# ----------------------------------------------------------------------------
setup_env() {  # expects: W_URL W_TZ W_EMAIL DB_HOST DB_PORT DB_NAME DB_USER DB_PASS USE_REDIS
  local f="$PANEL_DIR/.env"
  [[ -f $f ]] || cp "$PANEL_DIR/.env.example" "$f" || { error "Missing .env.example in the panel repo."; return 1; }
  [[ -n "$(env_get APP_KEY)" ]]      || env_set APP_KEY "base64:$(openssl rand -base64 32)"
  [[ -n "$(env_get HASHIDS_SALT)" ]] || env_set HASHIDS_SALT "$(rand_alnum 20)"
  env_set APP_URL "$W_URL"
  env_set APP_TIMEZONE "$W_TZ"
  env_set APP_SERVICE_AUTHOR "$W_EMAIL"
  env_set APP_ENVIRONMENT_ONLY "false"
  env_set DB_CONNECTION "mysql"
  env_set DB_HOST "$DB_HOST"
  env_set DB_PORT "$DB_PORT"
  env_set DB_DATABASE "$DB_NAME"
  env_set DB_USERNAME "$DB_USER"
  env_set DB_PASSWORD "$DB_PASS"
  if [[ $USE_REDIS == yes ]]; then
    env_set CACHE_DRIVER "redis"; env_set SESSION_DRIVER "redis"; env_set QUEUE_CONNECTION "redis"
    env_set REDIS_HOST "127.0.0.1"; env_set REDIS_PORT "6379"; env_set REDIS_PASSWORD "null"
  else
    env_set CACHE_DRIVER "file"; env_set SESSION_DRIVER "file"; env_set QUEUE_CONNECTION "database"
  fi
  if [[ $W_URL == https://* ]]; then
    env_set SESSION_SECURE_COOKIE "true"
    env_set TRUSTED_PROXIES "*"
  fi
  fix_perms
  success ".env written ($f)"
}

# ----------------------------------------------------------------------------
# nginx + php-fpm configs (own instances, own ports — never touches system sites)
# ----------------------------------------------------------------------------
write_web_configs() {
  local port="$PANEL_PORT" mime="" m user_line="" fpm_user="" mc mem
  mkdir -p "$MP_HOME/nginx/tmp" "$MP_HOME/php-fpm"

  for m in /etc/nginx/mime.types /usr/local/nginx/conf/mime.types /usr/local/etc/nginx/mime.types; do
    [[ -f $m ]] && { mime="include $m;"; break; }
  done
  if [[ -z $mime ]]; then
    mime='types { text/html html htm; text/css css; application/javascript js mjs; application/json json; image/svg+xml svg; image/png png; image/jpeg jpg jpeg; image/gif gif; image/webp webp; image/x-icon ico; font/woff2 woff2; font/woff woff; font/ttf ttf; application/wasm wasm; text/plain txt; application/gzip gz; }'
  fi
  if (( IS_ROOT )); then
    user_line="user ${WEB_USER} ${WEB_GROUP};"
    fpm_user=$'user = '"${WEB_USER}"$'\ngroup = '"${WEB_GROUP}"
  fi

  cat > "$MP_HOME/nginx/fastcgi_params" <<'FCGI_EOF'
fastcgi_param QUERY_STRING       $query_string;
fastcgi_param REQUEST_METHOD     $request_method;
fastcgi_param CONTENT_TYPE       $content_type;
fastcgi_param CONTENT_LENGTH     $content_length;
fastcgi_param SCRIPT_NAME        $fastcgi_script_name;
fastcgi_param REQUEST_URI        $request_uri;
fastcgi_param DOCUMENT_URI       $document_uri;
fastcgi_param DOCUMENT_ROOT      $document_root;
fastcgi_param SERVER_PROTOCOL    $server_protocol;
fastcgi_param REQUEST_SCHEME     $scheme;
fastcgi_param HTTPS              $https if_not_empty;
fastcgi_param GATEWAY_INTERFACE  CGI/1.1;
fastcgi_param SERVER_SOFTWARE    nginx/$nginx_version;
fastcgi_param REMOTE_ADDR        $remote_addr;
fastcgi_param REMOTE_PORT        $remote_port;
fastcgi_param SERVER_ADDR        $server_addr;
fastcgi_param SERVER_PORT        $server_port;
fastcgi_param SERVER_NAME        $server_name;
fastcgi_param REDIRECT_STATUS    200;
FCGI_EOF

  cat > "$MP_HOME/nginx/nginx.conf" <<EOF
# Generated by monopanel.sh — do not edit by hand (re-generated on install/run).
worker_processes auto;
${user_line}
pid ${MP_HOME}/run/nginx.pid;
error_log ${LOG_DIR}/nginx-error.log warn;

events { worker_connections 1024; }

http {
    ${mime}
    default_type application/octet-stream;
    access_log off;
    sendfile off;
    server_tokens off;
    client_max_body_size 100m;
    client_body_timeout 120s;
    client_body_temp_path ${MP_HOME}/nginx/tmp/body;
    proxy_temp_path       ${MP_HOME}/nginx/tmp/proxy;
    fastcgi_temp_path     ${MP_HOME}/nginx/tmp/fastcgi;
    uwsgi_temp_path       ${MP_HOME}/nginx/tmp/uwsgi;
    scgi_temp_path        ${MP_HOME}/nginx/tmp/scgi;

    server {
        listen ${port} default_server;
        server_name _;
        root ${PANEL_DIR}/public;
        index index.php;
        charset utf-8;

        location / {
            try_files \$uri \$uri/ /index.php?\$query_string;
        }

        location = /favicon.ico { access_log off; log_not_found off; }
        location = /robots.txt  { access_log off; log_not_found off; }

        location ~ \.php\$ {
            fastcgi_split_path_info ^(.+\.php)(/.+)\$;
            fastcgi_pass 127.0.0.1:${FPM_PORT};
            fastcgi_index index.php;
            include ${MP_HOME}/nginx/fastcgi_params;
            fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_param HTTP_PROXY "";
            fastcgi_intercept_errors off;
            fastcgi_buffer_size 16k;
            fastcgi_buffers 4 16k;
            fastcgi_connect_timeout 300;
            fastcgi_send_timeout 300;
            fastcgi_read_timeout 300;
        }

        location ~ /\.ht { deny all; }
    }
}
EOF

  mem="$(mem_limit_mb)"; mc=$(( mem / 100 ))
  (( mc < 3 )) && mc=3
  (( mc > 25 )) && mc=25
  cat > "$MP_HOME/php-fpm/php-fpm.conf" <<EOF
; Generated by monopanel.sh
[global]
pid = ${MP_HOME}/run/php-fpm.pid
error_log = ${LOG_DIR}/php-fpm.log
daemonize = no

[monopanel]
${fpm_user}
listen = 127.0.0.1:${FPM_PORT}
pm = ondemand
pm.max_children = ${mc}
pm.process_idle_timeout = 10s
pm.max_requests = 200
clear_env = no
catch_workers_output = yes
php_admin_value[memory_limit] = 256M
php_admin_value[upload_max_filesize] = 100M
php_admin_value[post_max_size] = 100M
EOF
  return 0
}

nginx_test() {
  local out
  out="$("$NGINX_BIN" -t -c "$MP_HOME/nginx/nginx.conf" 2>&1)" && return 0
  error "nginx config test failed:"; printf '%s\n' "$out" | sed 's/^/    /'
  return 1
}

# ----------------------------------------------------------------------------
# Service definitions for both run modes
# ----------------------------------------------------------------------------
define_panel_services() {  # define_panel_services production|development
  local mode="$1"
  svc_define queue "$PANEL_DIR" "$WEB_USER" "" "MonoPanel queue worker" \
    env HOME="$WEB_HOME" "$PHP_BIN" artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
  svc_define scheduler "$PANEL_DIR" "$WEB_USER" "" "MonoPanel scheduler" \
    env HOME="$WEB_HOME" "$PHP_BIN" artisan schedule:work
  if [[ $mode == production ]]; then
    write_web_configs
    svc_define php-fpm "$PANEL_DIR" "" "" "MonoPanel PHP-FPM" \
      "$FPM_BIN" --nodaemonize --fpm-config "$MP_HOME/php-fpm/php-fpm.conf"
    svc_define nginx "$PANEL_DIR" "" "" "MonoPanel nginx" \
      "$NGINX_BIN" -c "$MP_HOME/nginx/nginx.conf" -g "daemon off;"
  else
    svc_define serve "$PANEL_DIR" "$WEB_USER" "" "MonoPanel dev server (artisan serve)" \
      env HOME="$WEB_HOME" PHP_CLI_SERVER_WORKERS=4 "$PHP_BIN" artisan serve --host=0.0.0.0 --port="${RUN_PORT:-$PANEL_PORT}"
    svc_define vite "$PANEL_DIR" "$WEB_USER" "" "MonoPanel Vite dev server" \
      env HOME="$WEB_HOME" "$NODE_BIN" node_modules/vite/bin/vite.js --host 0.0.0.0 --port "$VITE_PORT" --strictPort
  fi
}

# ----------------------------------------------------------------------------
# Frontend build
# ----------------------------------------------------------------------------
assets_built() { [[ -f "$PANEL_DIR/public/build/manifest.json" || -f "$PANEL_DIR/public/build/.vite/manifest.json" ]]; }

node_heap_mb() {
  local mem cap="${MP_BUILD_MEM:-}"
  mem="$(mem_limit_mb)"
  if [[ -z $cap ]]; then
    cap=$(( mem * 75 / 100 ))
    (( cap > 4096 )) && cap=4096
    (( cap < 1024 )) && cap=1024
  fi
  printf '%s' "$cap"
}

install_node_modules() {
  ensure_pnpm || { error "pnpm is not available."; return 1; }
  export NODE_OPTIONS="--max-old-space-size=$(node_heap_mb)" CI=true
  if ( cd "$PANEL_DIR" && run_live "pnpm install --frozen-lockfile" pnpm install --frozen-lockfile ); then return 0; fi
  warn "Frozen install failed — retrying without the lockfile constraint."
  ( cd "$PANEL_DIR" && run_live "pnpm install" pnpm install --no-frozen-lockfile )
}

build_assets() {
  step "Building the frontend (pnpm build)"
  [[ -f "$PANEL_DIR/package.json" ]] || { error "package.json not found in $PANEL_DIR"; return 1; }
  local mem; mem="$(mem_limit_mb)"
  if (( mem > 0 && mem < 1800 )); then
    warn "Only ${mem} MB of RAM is available — the Vite build can run out of memory."
    note "Tip: free RAM (stop other services), raise the container limit, or set MP_BUILD_MEM."
  fi
  install_node_modules || return 1
  export NODE_OPTIONS="--max-old-space-size=$(node_heap_mb)"
  ( cd "$PANEL_DIR" && run_live "pnpm build" pnpm build ) || return 1
  if ! assets_built; then error "Build finished but public/build/manifest.json is missing."; return 1; fi
  rm -f "$PANEL_DIR/public/hot"
  success "Frontend built → public/build"
}

# ----------------------------------------------------------------------------
# Admin user
# ----------------------------------------------------------------------------
create_admin() {
  step "Create an administrator account"
  require_panel || return 1
  load_runtime || return 1
  ensure_db_running || return 1
  local email user pass pass2
  email="$(ask "Admin email" "$(env_get APP_SERVICE_AUTHOR "")")"
  [[ $email =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { error "That does not look like an email address."; return 1; }
  user="$(ask "Admin username (letters/numbers/._-)" "admin")"
  [[ $user =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,}[A-Za-z0-9]$ ]] || { error "Invalid username (min 3 chars, must start/end alphanumeric)."; return 1; }
  if [[ "${MP_ASSUME_DEFAULTS:-0}" == "1" ]]; then
    pass="${MP_ADMIN_PASSWORD:-$(rand_alnum 16)}"
    info "Generated admin password: $pass"
  else
    pass="$(ask_secret "Admin password (min 8 chars)")"
    pass2="$(ask_secret "Repeat password")"
    [[ $pass == "$pass2" ]] || { error "Passwords do not match."; return 1; }
  fi
  (( ${#pass} >= 8 )) || { error "Password must be at least 8 characters."; return 1; }
  if artisan p:user:make --email="$email" --username="$user" --password="$pass" --admin=1 --no-interaction; then
    success "Admin '$user' created — log in at $(env_get APP_URL)"
  else
    error "User creation failed (does the user already exist?). See: $PANEL_DIR/storage/logs"
    return 1
  fi
}

# ----------------------------------------------------------------------------
# 1) Install Panel
# ----------------------------------------------------------------------------
install_panel() {
  banner
  step "MonoPanel — full installation"
  detect_system
  info "System : $OS_PRETTY ($ARCH_RAW) · package manager: $PKG"
  info "Init   : $(init_label)$( (( IN_CONTAINER )) && echo ' · running inside a container')"
  info "Memory : $(mem_limit_mb) MB · panel dir: $PANEL_DIR"
  (( IS_ROOT )) || warn "Not running as root — package installs will fail unless everything is already present."
  line

  if panel_installed; then
    warn "MonoPanel is already installed in $PANEL_DIR."
    note "Re-running keeps your .env, APP_KEY and database; it re-checks dependencies and rebuilds."
    confirm "Continue anyway?" n || { press_enter; return 0; }
  fi

  # ---- wizard ----
  local def_port def_url def_tz def_email
  def_port="$(default_panel_port)"
  PANEL_PORT="$(ask "Panel HTTP port" "$def_port")"
  [[ $PANEL_PORT =~ ^[0-9]+$ ]] || { error "Port must be a number."; press_enter; return 1; }
  if port_in_use "$PANEL_PORT" && ! svc_running nginx; then
    warn "Port $PANEL_PORT is already in use by another program."
    confirm "Use it anyway?" n || { press_enter; return 1; }
  fi
  local ipshow; ipshow="$(public_ip)"
  if [[ -f "$PANEL_DIR/.env" ]]; then def_url="$(env_get APP_URL "")"; fi
  if [[ -z ${def_url:-} ]]; then
    if [[ $PANEL_PORT == 80 ]]; then def_url="http://${ipshow}"; else def_url="http://${ipshow}:${PANEL_PORT}"; fi
  fi
  W_URL="$(ask "Panel URL (what users type in the browser)" "$def_url")"
  W_URL="${W_URL%/}"
  [[ $W_URL =~ ^https?:// ]] || { error "The URL must start with http:// or https://"; press_enter; return 1; }
  W_TZ="$(ask "Timezone" "$(env_get APP_TIMEZONE "$(detect_timezone)")")"
  def_email="$(env_get APP_SERVICE_AUTHOR "")"
  W_EMAIL="$(ask "Admin / egg-author email" "${def_email:-admin@example.com}")"

  local dbmode dbchoice
  dbmode="$(cfg_get DB_MODE local)"
  dbchoice="$(ask "Database: 1) install local MariaDB   2) use an existing MySQL/MariaDB server" "$([[ $dbmode == local ]] && echo 1 || echo 2)")"
  if [[ $dbchoice == 2 ]]; then
    dbmode="external"
    DB_HOST="$(ask "DB host" "127.0.0.1")"; DB_PORT="$(ask "DB port" "3306")"
    DB_NAME="$(ask "DB name" "panel")";    DB_USER="$(ask "DB user (not root)" "monopanel")"
    DB_PASS="$(ask_secret "DB password")"
  else
    dbmode="local"; DB_HOST="127.0.0.1"; DB_PORT="3306"; DB_NAME="monopanel"; DB_USER="monopanel"; DB_PASS=""
  fi
  USE_REDIS="no"
  confirm "Use Redis for cache/queue/sessions? (recommended)" y && USE_REDIS="yes"

  cfg_set PANEL_DIR "$PANEL_DIR"; cfg_set PANEL_REPO "$PANEL_REPO"; cfg_set PANEL_BRANCH "$PANEL_BRANCH"
  cfg_set PANEL_PORT "$PANEL_PORT"; cfg_set DB_MODE "$dbmode"; cfg_set USE_REDIS "$USE_REDIS"
  line

  # ---- dependencies ----
  ensure_base_deps || { press_enter; return 1; }
  install_php      || { press_enter; return 1; }
  ensure_composer  || { press_enter; return 1; }
  install_node     || { press_enter; return 1; }
  ensure_nginx     || { press_enter; return 1; }
  if [[ $dbmode == local ]]; then install_db_server || { press_enter; return 1; }; fi
  if [[ $USE_REDIS == yes ]]; then install_redis || { warn "Redis unavailable — falling back to file/database drivers."; USE_REDIS="no"; cfg_set USE_REDIS no; }; fi
  detect_web_user

  # ---- source ----
  clone_panel || { press_enter; return 1; }

  # ---- database ----
  if [[ $dbmode == local ]]; then
    local old_pw; old_pw="$(env_get DB_PASSWORD "")"
    if [[ -n $old_pw && $old_pw != null ]]; then DB_PASS="$old_pw"; else DB_PASS="$(rand_alnum 24)"; fi
    ensure_db_running || { press_enter; return 1; }
    setup_local_db "$DB_NAME" "$DB_USER" "$DB_PASS" || { press_enter; return 1; }
  else
    info "Testing the database connection"
    if ! test_db_connection "$DB_HOST" "$DB_PORT" "$DB_NAME" "$DB_USER" "$DB_PASS"; then
      error "Could not connect with those credentials."; press_enter; return 1
    fi
    success "Database connection OK."
  fi

  # ---- configuration + dependencies of the app ----
  setup_env || { press_enter; return 1; }
  step "Installing PHP dependencies (composer)"
  run_live "composer install" composer_run install --no-dev --optimize-autoloader --no-interaction || { press_enter; return 1; }
  build_assets || { press_enter; return 1; }
  fix_perms

  [[ $USE_REDIS == yes ]] && { ensure_redis_running || warn "Redis is not running yet; start it via Run Panel."; }
  step "Preparing the database (migrate + seed)"
  artisan migrate --seed --force --no-interaction 2>&1 | tee -a "$INSTALL_LOG"
  if (( PIPESTATUS[0] != 0 )); then error "Migration failed — see the output above."; press_enter; return 1; fi
  artisan storage:link --no-interaction >>"$INSTALL_LOG" 2>&1 || true
  fix_perms

  step "Writing service definitions"
  define_panel_services production
  cfg_set INSTALLED yes
  cfg_set RUN_MODE production

  line
  success "MonoPanel is installed."
  if confirm "Create the first administrator account now?" y; then create_admin; fi
  if confirm "Start the panel in production mode now?" y; then run_panel production; return; fi
  press_enter
}

# ----------------------------------------------------------------------------
# Health check + URLs
# ----------------------------------------------------------------------------
wait_http() {  # wait_http <url> [tries]  -> prints the HTTP status code (000 = no answer)
  local url="$1" tries="${2:-40}" code="000" i
  for ((i = 0; i < tries; i++)); do
    code="$(curl -s -o /dev/null -m 4 -w '%{http_code}' "$url" 2>/dev/null)"
    [[ -n $code && $code != 000 ]] && break
    sleep 1
  done
  printf '%s' "${code:-000}"
}

apply_vite_public_url() {  # rewrite public/hot so a browser OUTSIDE this machine can reach Vite
  local url="$1" i
  for i in $(seq 1 30); do [[ -f "$PANEL_DIR/public/hot" ]] && break; sleep 1; done
  if [[ -f "$PANEL_DIR/public/hot" ]]; then printf '%s' "$url" > "$PANEL_DIR/public/hot"; return 0; fi
  warn "Vite did not create public/hot — HMR URL was not rewritten."
}

stop_panel_procs() {
  local s
  for s in nginx php-fpm serve vite queue scheduler; do
    if svc_defined "$s" && svc_running "$s"; then svc_stop "$s"; fi
  done
}

# ----------------------------------------------------------------------------
# 2) / 3) Run Panel (production | development)
# ----------------------------------------------------------------------------
run_panel() {  # run_panel production|development [nobanner]
  local mode="$1" code s
  RUN_PORT="$PANEL_PORT"
  [[ "${2:-}" == nobanner ]] || banner
  step "Starting MonoPanel — ${mode} mode"
  require_panel || { press_enter; return 1; }
  load_runtime  || { press_enter; return 1; }

  if [[ $mode == production ]]; then
    [[ -n ${FPM_BIN:-} && -n ${NGINX_BIN:-} ]] || { error "nginx/php-fpm missing. Run 'Install Panel' again."; press_enter; return 1; }
  else
    [[ -n ${NODE_BIN:-} ]] || { error "Node.js missing. Run 'Install Panel' again."; press_enter; return 1; }
  fi

  stop_panel_procs
  ensure_db_running || { press_enter; return 1; }
  ensure_redis_running || warn "Redis is not running — the panel may fail to queue jobs."

  if [[ $mode == production ]]; then
    env_set APP_ENV production; env_set APP_DEBUG false
    local pu; pu="$(cfg_get APP_URL_PROD "")"
    if [[ -n $pu ]]; then env_set APP_URL "$pu"; cfg_set APP_URL_PROD ""; info "Restored the production URL: $pu"; fi
    rm -f "$PANEL_DIR/public/hot"
    if ! assets_built; then
      warn "No production build found (public/build)."
      if confirm "Build the frontend now?" y; then build_assets || { press_enter; return 1; }
      else error "Cannot serve production without assets."; press_enter; return 1; fi
    fi
    fix_perms
    define_panel_services production
    nginx_test || { press_enter; return 1; }
    artisan optimize:clear --no-interaction >>"$INSTALL_LOG" 2>&1
    for s in php-fpm nginx queue scheduler; do
      if svc_start "$s"; then success "$s started"; else error "$s failed to start — see $LOG_DIR/$s.log"; tail -n 8 "$LOG_DIR/$s.log" 2>/dev/null | sed 's/^/    /'; fi
    done
  else
    env_set APP_ENV local; env_set APP_DEBUG true
    if [[ ! -d "$PANEL_DIR/node_modules/vite" ]]; then install_node_modules || { press_enter; return 1; }; fi
    # The dev server runs as the web user, so it cannot bind ports < 1024.
    local dp; dp="$(cfg_get DEV_PORT "")"
    if [[ -z $dp ]]; then if (( PANEL_PORT < 1024 )); then dp=8000; else dp="$PANEL_PORT"; fi; fi
    RUN_PORT="$(ask "Dev server port" "$dp")"
    [[ $RUN_PORT =~ ^[0-9]+$ ]] && (( RUN_PORT >= 1024 )) || { error "Use a port between 1024 and 65535."; press_enter; return 1; }
    cfg_set DEV_PORT "$RUN_PORT"
    local pub cur def_pub; cur="$(env_get APP_URL)"; def_pub="$cur"
    if [[ $cur =~ ^(http://[^/:]+)(:[0-9]+)?$ ]]; then def_pub="${BASH_REMATCH[1]}:${RUN_PORT}"; fi
    pub="$(ask "Public URL of this dev panel" "$def_pub")"
    if [[ -n $pub && $pub != "$cur" ]]; then
      [[ -z "$(cfg_get APP_URL_PROD "")" ]] && cfg_set APP_URL_PROD "$cur"   # restored when you go back to production
      env_set APP_URL "${pub%/}"
    fi
    rm -f "$PANEL_DIR/public/hot"
    fix_perms
    define_panel_services development
    artisan optimize:clear --no-interaction >>"$INSTALL_LOG" 2>&1
    for s in serve vite queue scheduler; do
      if svc_start "$s"; then success "$s started"; else error "$s failed to start — see $LOG_DIR/$s.log"; tail -n 8 "$LOG_DIR/$s.log" 2>/dev/null | sed 's/^/    /'; fi
    done
    local vurl="${MP_VITE_PUBLIC_URL:-}"
    if [[ -z $vurl ]]; then
      vurl="$(ask "Public URL of the Vite dev server (remote sandboxes only, Enter to skip)" "")"
    fi
    [[ -n $vurl ]] && apply_vite_public_url "${vurl%/}"
  fi

  cfg_set RUN_MODE "$mode"
  code="$(wait_http "http://127.0.0.1:${RUN_PORT}/" "${MP_HTTP_WAIT:-40}")"
  line
  if [[ $code == 000 ]]; then
    warn "The panel did not answer on port ${RUN_PORT} yet. Check: View Logs."
  elif [[ $code =~ ^5 ]]; then
    warn "The panel answered HTTP ${code}. Check ${PANEL_DIR}/storage/logs and the service logs."
  else
    success "Panel is answering on http://127.0.0.1:${RUN_PORT}/ (HTTP ${code})"
  fi
  info "Public URL (APP_URL): $(env_get APP_URL)"
  [[ $mode == development ]] && info "Vite dev server: port ${VITE_PORT} (hot reload)"
  note "Manage it from the menu, or: bash monopanel.sh stop | status | logs"
  press_enter
}

stop_panel() {
  banner; step "Stopping MonoPanel"
  local s any=0
  for s in nginx php-fpm serve vite queue scheduler; do
    if svc_defined "$s" && svc_running "$s"; then svc_stop "$s"; success "$s stopped"; any=1; fi
  done
  (( any )) || info "No panel processes were running."
  note "MariaDB / Redis / Wings / tunnels were left alone (see 'Stop everything' in Tools)."
  press_enter
}

stop_everything() {
  banner; step "Stopping everything MonoPanel started"
  local s
  for s in nginx php-fpm serve vite queue scheduler wings cloudflared cloudflared-quick redis mariadb docker; do
    if svc_defined "$s" && svc_running "$s"; then svc_stop "$s"; success "$s stopped"; fi
  done
  press_enter
}

restart_panel() { run_panel "$(cfg_get RUN_MODE production)" "${1:-}"; }

# ----------------------------------------------------------------------------
# Backup
# ----------------------------------------------------------------------------
backup_panel() {
  banner; step "Backing up .env + database"
  require_panel || { press_enter; return 1; }
  detect_db_bins >/dev/null 2>&1
  local ts dir h p d u w rc
  ts="$(date +%Y%m%d-%H%M%S)"; dir="$MP_HOME/backups"; mkdir -p "$dir"
  cp "$PANEL_DIR/.env" "$dir/env-$ts" && chmod 600 "$dir/env-$ts" && success "Saved $dir/env-$ts"
  h="$(env_get DB_HOST 127.0.0.1)"; p="$(env_get DB_PORT 3306)"; d="$(env_get DB_DATABASE)"
  u="$(env_get DB_USERNAME)"; w="$(env_get DB_PASSWORD)"
  if [[ -z ${DB_DUMP_BIN:-} ]]; then
    warn "mysqldump/mariadb-dump not found — database was NOT backed up."
  else
    ensure_db_running || true
    MYSQL_PWD="$w" "$DB_DUMP_BIN" -h"$h" -P"$p" -u"$u" --single-transaction --routines "$d" 2>>"$INSTALL_LOG" | gzip > "$dir/db-$ts.sql.gz"
    rc=${PIPESTATUS[0]}
    if (( rc == 0 )); then chmod 600 "$dir/db-$ts.sql.gz"; success "Saved $dir/db-$ts.sql.gz"
    else error "Database dump failed (see $INSTALL_LOG)"; rm -f "$dir/db-$ts.sql.gz"; fi
  fi
  ls -1t "$dir"/db-*.sql.gz 2>/dev/null | tail -n +11 | xargs -r rm -f
  ls -1t "$dir"/env-* 2>/dev/null | tail -n +11 | xargs -r rm -f
  press_enter
}

# ----------------------------------------------------------------------------
# 5) Update Panel
# ----------------------------------------------------------------------------
update_panel() {
  banner; step "Updating MonoPanel from GitHub ($PANEL_BRANCH)"
  require_panel || { press_enter; return 1; }
  load_runtime  || { press_enter; return 1; }
  [[ -d "$PANEL_DIR/.git" ]] || { error "$PANEL_DIR is not a git checkout."; press_enter; return 1; }
  ensure_composer || { press_enter; return 1; }
  ensure_pnpm     || { error "pnpm unavailable."; press_enter; return 1; }

  local mode was_running=0 before after
  mode="$(cfg_get RUN_MODE production)"
  { svc_running nginx || svc_running serve; } && was_running=1
  before="$(mp_git -C "$PANEL_DIR" rev-parse --short HEAD 2>/dev/null)"

  if confirm "Back up the database and .env first?" y; then
    MP_CLI=1 backup_panel >/dev/null 2>&1 && success "Backup saved in $MP_HOME/backups"
  fi

  (( was_running )) && artisan down --retry=60 --no-interaction >>"$INSTALL_LOG" 2>&1

  info "Pulling the latest code…"
  mp_git -C "$PANEL_DIR" pull --ff-only origin "$PANEL_BRANCH" 2>&1 | tee -a "$INSTALL_LOG" | tail -n 5
  if (( PIPESTATUS[0] != 0 )); then
    warn "Fast-forward pull failed (local changes or diverged history)."
    if confirm "Discard local changes and hard-reset to origin/$PANEL_BRANCH?" n; then
      mp_git -C "$PANEL_DIR" fetch --depth 1 origin "$PANEL_BRANCH" >>"$INSTALL_LOG" 2>&1 \
        && mp_git -C "$PANEL_DIR" reset --hard FETCH_HEAD >>"$INSTALL_LOG" 2>&1 \
        || { error "Hard reset failed (see $INSTALL_LOG)"; (( was_running )) && artisan up >/dev/null 2>&1; press_enter; return 1; }
    else
      warn "Keeping the local copy untouched."
      (( was_running )) && artisan up >/dev/null 2>&1
      press_enter; return 1
    fi
  fi
  after="$(mp_git -C "$PANEL_DIR" rev-parse --short HEAD 2>/dev/null)"

  if [[ $before == "$after" ]]; then
    success "Already up to date ($after)."
    if ! confirm "Reinstall dependencies and rebuild anyway?" n; then
      (( was_running )) && artisan up >/dev/null 2>&1
      press_enter; return 0
    fi
  else
    success "Updated $before → $after"
  fi

  fix_perms
  step "PHP dependencies"
  run_live "composer install" composer_run install --no-dev --optimize-autoloader --no-interaction \
    || { error "composer failed"; (( was_running )) && artisan up >/dev/null 2>&1; press_enter; return 1; }
  build_assets || { (( was_running )) && artisan up >/dev/null 2>&1; press_enter; return 1; }
  fix_perms

  step "Migrating the database"
  artisan optimize:clear --no-interaction >>"$INSTALL_LOG" 2>&1
  artisan migrate --seed --force --no-interaction 2>&1 | tee -a "$INSTALL_LOG"
  (( PIPESTATUS[0] == 0 )) || warn "Migration reported errors — review the output above."
  fix_perms
  artisan queue:restart --no-interaction >>"$INSTALL_LOG" 2>&1
  artisan up --no-interaction >>"$INSTALL_LOG" 2>&1

  if (( was_running )); then
    info "Restarting services…"
    run_panel "$mode" nobanner
    return
  fi
  success "Panel updated. Start it from the menu when you are ready."
  press_enter
}

# ----------------------------------------------------------------------------
# Status
# ----------------------------------------------------------------------------
show_status() {
  banner; step "Status"
  detect_system
  detect_php >/dev/null 2>&1
  local mode; mode="$(cfg_get RUN_MODE -)"
  printf "${BOLD}System${RESET}   %s (%s) · %s · RAM limit %s MB\n" "$OS_PRETTY" "$ARCH_RAW" "$(init_label)" "$(mem_limit_mb)"
  if panel_installed; then
    printf "${BOLD}Panel${RESET}    %s · branch %s · commit %s · mode %s\n" "$PANEL_DIR" "$PANEL_BRANCH" \
      "$(mp_git -C "$PANEL_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')" "$mode"
    printf "${BOLD}URL${RESET}      %s   (port %s)\n" "$(env_get APP_URL)" "$(cfg_get PANEL_PORT '?')"
  else
    printf "${BOLD}Panel${RESET}    ${BOLD_YELLOW}not installed${RESET} (target: %s)\n" "$PANEL_DIR"
  fi
  printf "${BOLD}Runtime${RESET}  PHP %s · Node %s · pnpm %s\n" \
    "$([[ -n ${PHP_BIN:-} ]] && "$PHP_BIN" -r 'echo PHP_VERSION;' || echo -)" \
    "$(command -v node >/dev/null 2>&1 && node -v || echo -)" \
    "$(command -v pnpm >/dev/null 2>&1 && pnpm -v 2>/dev/null || echo -)"
  line
  local s
  detect_db_bins >/dev/null 2>&1
  printf "  %-16s %s\n" "database" "$(if [[ "$(cfg_get DB_MODE local)" != local ]]; then echo 'external'; elif db_ping; then printf "${BOLD_GREEN}up${RESET}"; else printf "${BOLD_RED}down${RESET}"; fi)"
  printf "  %-16s %s\n" "redis" "$(if [[ "$(cfg_get USE_REDIS yes)" != yes ]]; then echo 'not used'; elif redis_ping; then printf "${BOLD_GREEN}up${RESET}"; else printf "${BOLD_RED}down${RESET}"; fi)"
  for s in nginx php-fpm serve vite queue scheduler; do
    svc_defined "$s" && printf "  %-16s %b\n" "$s" "$(svc_state "$s")"
  done
  printf "  %-16s %s\n" "docker" "$(if command -v docker >/dev/null 2>&1; then if docker_ok; then printf "${BOLD_GREEN}running${RESET}"; else printf "${BOLD_RED}stopped${RESET}"; fi; else printf "${GRAY}not installed${RESET}"; fi)"
  printf "  %-16s %b\n" "wings (node)" "$([[ -x /usr/local/bin/wings ]] && svc_state wings || printf "${GRAY}not installed${RESET}")"
  printf "  %-16s %b\n" "cloudflared" "$(svc_state cloudflared)"
  if svc_defined cloudflared-quick; then
    printf "  %-16s %b  %s\n" "quick tunnel" "$(svc_state cloudflared-quick)" "$(quick_tunnel_url)"
  fi
  press_enter
}

# ----------------------------------------------------------------------------
# Logs
# ----------------------------------------------------------------------------
view_logs() {
  banner; step "Logs"
  local -a labels=() paths=()
  local lv f i=0
  lv="$(ls -t "$PANEL_DIR"/storage/logs/*.log 2>/dev/null | head -n1)"
  if [[ -n $lv ]]; then labels+=("Panel (Laravel)"); paths+=("$lv"); fi
  for f in nginx-error php-fpm serve vite queue scheduler mariadb redis docker wings cloudflared cloudflared-quick install services; do
    [[ -f "$LOG_DIR/$f.log" ]] && { labels+=("$f"); paths+=("$LOG_DIR/$f.log"); }
  done
  if (( ${#labels[@]} == 0 )); then warn "No logs yet."; press_enter; return 0; fi
  for i in "${!labels[@]}"; do printf "  ${BOLD_CYAN}%2d)${RESET} %s\n" "$((i + 1))" "${labels[$i]}"; done
  printf "  ${BOLD_RED} 0)${RESET} Back\n"
  local pick; pick="$(ask "Which log" "1")"
  [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#labels[@]} )) || return 0
  f="${paths[$((pick - 1))]}"
  line; tail -n 80 "$f"; line
  if confirm "Follow live? (Ctrl+C to stop)" n; then ( trap - INT; tail -n 0 -f "$f" ); fi
  press_enter
}

# ----------------------------------------------------------------------------
# Nodes: Docker + Wings (works next to the panel or on a separate machine)
# ----------------------------------------------------------------------------
WINGS_BIN="/usr/local/bin/wings"
WINGS_CONF="/etc/pterodactyl/config.yml"

docker_ok() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

wait_docker() {  # wait_docker <seconds>
  local i
  for ((i = 0; i < ${1:-30}; i++)); do docker_ok && return 0; sleep 1; done
  return 1
}

install_docker() {
  step "Docker"
  need_root "Installing Docker" || return 1
  if command -v docker >/dev/null 2>&1; then
    success "Docker CLI found: $(docker --version 2>/dev/null)"
  else
    info "Installing Docker (get.docker.com) — this can take a few minutes"
    curl -fsSL https://get.docker.com -o "$MP_HOME/tmp/get-docker.sh" >>"$INSTALL_LOG" 2>&1 \
      || { error "Could not download the Docker install script."; return 1; }
    policy_block
    run_root sh "$MP_HOME/tmp/get-docker.sh" >>"$INSTALL_LOG" 2>&1
    policy_unblock
    if ! command -v docker >/dev/null 2>&1; then
      warn "get.docker.com did not finish — trying the distro package."
      case "$PKG" in
        apt) pkg_install docker.io ;;
        dnf|yum|apk) pkg_install docker ;;
      esac
    fi
    command -v docker >/dev/null 2>&1 || { error "Docker installation failed (see $INSTALL_LOG)."; return 1; }
    success "Docker installed: $(docker --version 2>/dev/null)"
  fi
  start_docker
}

start_docker() {
  docker_ok && { success "Docker daemon is running."; return 0; }
  command -v docker >/dev/null 2>&1 || { error "Docker is not installed."; return 1; }
  info "Starting the Docker daemon"
  local dd u
  if use_systemd; then
    for u in docker docker.service; do
      systemctl enable --now "$u" >>"$LOG_DIR/services.log" 2>&1 && break
    done
    if wait_docker 30; then success "Docker daemon is running."; return 0; fi
  else
    dd="$(command -v dockerd 2>/dev/null)"
    [[ -n $dd ]] || { error "dockerd binary not found."; return 1; }
    mkdir -p /var/lib/docker /var/run
    svc_define docker / "" "" "Docker daemon" "$dd"
    svc_start docker
    if wait_docker 30; then success "Docker daemon is running (built-in supervisor)."; return 0; fi
    warn "Default storage driver failed — retrying with vfs (slower, uses more disk)."
    svc_stop docker
    svc_define docker / "" "" "Docker daemon" "$dd" --storage-driver=vfs
    svc_start docker
    if wait_docker 40; then success "Docker daemon is running (vfs storage)."; return 0; fi
  fi
  error "The Docker daemon could not start. Last log lines:"
  tail -n 12 "$LOG_DIR/docker.log" 2>/dev/null | sed 's/^/    /'
  note "Wings needs a real Docker daemon: root, cgroups and iptables. Locked-down sandboxes"
  note "(CodeSandbox, Codespaces, Replit, most shared containers) cannot provide that."
  note "Use a VPS, or run this container with --privileged / mount the host's /var/run/docker.sock."
  return 1
}

install_wings() {  # install_wings [force]
  step "Wings (node daemon)"
  need_root "Installing Wings" || return 1
  if [[ $ARCH != amd64 && $ARCH != arm64 ]]; then error "Wings only ships amd64/arm64 builds (this machine is $ARCH_RAW)."; return 1; fi
  mkdir -p /etc/pterodactyl /var/lib/pterodactyl/volumes /var/lib/pterodactyl/archives /var/lib/pterodactyl/backups /var/log/pterodactyl /tmp/pterodactyl
  if [[ -x $WINGS_BIN && "${1:-}" != force ]]; then success "Wings already installed: $WINGS_BIN"; return 0; fi
  info "Downloading Wings (latest release, linux/$ARCH)"
  if ! curl -fsSL "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH}" -o "$WINGS_BIN.new" >>"$INSTALL_LOG" 2>&1; then
    rm -f "$WINGS_BIN.new"; error "Wings download failed (see $INSTALL_LOG)."; return 1
  fi
  chmod 755 "$WINGS_BIN.new" && mv -f "$WINGS_BIN.new" "$WINGS_BIN"
  success "Wings installed: $("$WINGS_BIN" --version 2>/dev/null | head -n1)"
}

define_wings_service() {
  SVC_UNIT_AFTER="docker.service"; SVC_UNIT_REQUIRES="docker.service"
  SVC_UNIT_EXTRA="TasksMax=infinity"
  svc_define wings /etc/pterodactyl "" "" "MonoPanel node daemon (Wings)" "$WINGS_BIN"
}

wings_port() { awk '/^api:/ {f=1} f && /^ +port:/ {print $2; exit}' "$WINGS_CONF" 2>/dev/null; }

# ----------------------------------------------------------------------------
# Talk to the local panel (create node / allocations) without tinker or quoting hell
# ----------------------------------------------------------------------------
write_node_helper() {
  cat > "$MP_HOME/tmp/mp-node.php" <<'PHP_EOF'
<?php
// Generated by monopanel.sh — uses the panel's own service classes.
$root = getenv('MP_PANEL_DIR');
require $root . '/vendor/autoload.php';
$app = require $root . '/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

$mode = getenv('MP_MODE');
try {
    if ($mode === 'create') {
        $node = $app->make(Everest\Services\Nodes\NodeCreationService::class)->handle([
            'name' => getenv('MP_NAME'),
            'description' => getenv('MP_DESC') ?: 'Created by monopanel.sh',
            'fqdn' => getenv('MP_FQDN'),
            'scheme' => getenv('MP_SCHEME'),
            'behind_proxy' => getenv('MP_BEHIND_PROXY') === '1',
            'public' => true,
            'maintenance_mode' => false,
            'memory' => (int) getenv('MP_MEMORY'),
            'memory_overallocate' => (int) getenv('MP_MEM_OVER'),
            'disk' => (int) getenv('MP_DISK'),
            'disk_overallocate' => (int) getenv('MP_DISK_OVER'),
            'upload_size' => (int) getenv('MP_UPLOAD'),
            'listen_port_http' => (int) getenv('MP_HTTP_PORT'),
            'listen_port_sftp' => (int) getenv('MP_SFTP_PORT'),
            'public_port_http' => (int) getenv('MP_PUBLIC_HTTP'),
            'public_port_sftp' => (int) getenv('MP_SFTP_PORT'),
            'daemon_base' => getenv('MP_DAEMON_BASE'),
        ]);
        echo 'NODE_ID=' . $node->id . PHP_EOL;
    } elseif ($mode === 'allocate') {
        $node = Everest\Models\Node::query()->findOrFail((int) getenv('MP_NODE_ID'));
        $data = [
            'ip' => getenv('MP_IP'),
            'allocation_ports' => array_values(array_filter(array_map('trim', explode(',', (string) getenv('MP_PORTS'))))),
        ];
        if (getenv('MP_ALIAS')) {
            $data['alias'] = getenv('MP_ALIAS');
        }
        $app->make(Everest\Services\Allocations\AssignmentService::class)->handle($node, $data);
        echo 'ALLOCATIONS_OK' . PHP_EOL;
    }
} catch (Throwable $e) {
    fwrite(STDERR, get_class($e) . ': ' . $e->getMessage() . PHP_EOL);
    exit(1);
}
PHP_EOF
  chmod 644 "$MP_HOME/tmp/mp-node.php"
}

node_helper() {  # node_helper KEY=VAL ...   (runs mp-node.php as the web user)
  write_node_helper
  ( cd "$PANEL_DIR" && as_user "$WEB_USER" env HOME="$WEB_HOME" MP_PANEL_DIR="$PANEL_DIR" "$@" "$PHP_BIN" "$MP_HOME/tmp/mp-node.php" 2>>"$INSTALL_LOG" )
}

node_sync_config() {  # node_sync_config <node id>  -> /etc/pterodactyl/config.yml from the local panel
  local id="$1" out
  out="$( cd "$PANEL_DIR" && as_user "$WEB_USER" env HOME="$WEB_HOME" "$PHP_BIN" artisan p:node:configuration "$id" --format=yaml --no-interaction 2>>"$INSTALL_LOG" )"
  out="$(printf '%s\n' "$out" | sed -n '/^debug:/,$p')"
  if [[ $out != *"uuid:"* || $out != *"token:"* ]]; then
    error "The panel did not return a configuration for node $id (see $INSTALL_LOG)."
    return 1
  fi
  mkdir -p /etc/pterodactyl
  printf '%s\n' "$out" > "$WINGS_CONF"; chmod 600 "$WINGS_CONF"
  success "Wrote $WINGS_CONF from node #$id"
}

# ----------------------------------------------------------------------------
# Start / stop the node
# ----------------------------------------------------------------------------
start_node() {
  banner; step "Starting the node (Wings)"
  need_root "Starting Wings" || { press_enter; return 1; }
  detect_system
  [[ -x $WINGS_BIN ]]  || { error "Wings is not installed. Use 'Configure Node' first."; press_enter; return 1; }
  [[ -f $WINGS_CONF ]] || { error "$WINGS_CONF is missing. Use 'Configure Node' first."; press_enter; return 1; }
  start_docker || { press_enter; return 1; }
  define_wings_service
  svc_stop wings
  if ! svc_start wings; then
    error "Wings did not start. Last log lines:"; tail -n 15 "$LOG_DIR/wings.log" 2>/dev/null | sed 's/^/    /'
    press_enter; return 1
  fi
  sleep 3
  if svc_running wings; then
    success "Wings is running (API port $(wings_port))."
    note "In the panel the node's heartbeat turns green within ~30 seconds."
  else
    error "Wings exited right after starting:"; tail -n 15 "$LOG_DIR/wings.log" 2>/dev/null | sed 's/^/    /'
  fi
  press_enter
}

stop_node() {
  banner; step "Stopping the node (Wings)"
  if svc_defined wings && svc_running wings; then svc_stop wings; success "Wings stopped."; else info "Wings is not running."; fi
  note "Game servers already running in Docker keep running; Wings re-attaches on the next start."
  press_enter
}

# ----------------------------------------------------------------------------
# Configure node — this machine runs the panel AND a node
# ----------------------------------------------------------------------------
node_setup_local() {
  banner; step "Configure a node on THIS machine (local panel)"
  need_root "Node setup" || { press_enter; return 1; }
  require_panel || { press_enter; return 1; }
  load_runtime  || { press_enter; return 1; }
  ensure_db_running || { press_enter; return 1; }

  local name fqdn scheme https_def proxy mem disk over_m over_d upl hport sport base pub_http nid
  name="$(ask "Node name" "Node-$(hostname -s 2>/dev/null | head -c 20)")"
  [[ $name =~ ^[A-Za-z0-9_\ .-]{1,100}$ ]] || { error "Node name may only contain letters, numbers, spaces and . _ -"; press_enter; return 1; }
  fqdn="$(ask "Node address (domain or IP that browsers + the panel can reach)" "$(public_ip)")"
  [[ -n $fqdn ]] || { error "An address is required."; press_enter; return 1; }
  https_def=n; [[ $fqdn =~ ^[0-9.]+$ ]] || https_def=y
  proxy=0; scheme=http
  if confirm "Is this node behind a proxy / Cloudflare Tunnel (TLS handled outside Wings)?" n; then proxy=1; scheme=https
  elif confirm "Use HTTPS directly on Wings (needs a certificate)?" "$https_def"; then scheme=https; fi
  mem="$(ask "Memory available to servers (MB)" "$(mem_limit_mb)")"
  disk="$(ask "Disk available to servers (MB)" "$(disk_free_mb /var/lib)")"
  over_m="$(ask "Memory over-allocation % (-1 = unlimited)" "0")"
  over_d="$(ask "Disk over-allocation % (-1 = unlimited)" "0")"
  upl="$(ask "Max upload size (MB)" "100")"
  local hdef=8080
  if port_in_use 8080 || [[ ${PANEL_PORT:-} == 8080 ]]; then hdef=8081; fi
  hport="$(ask "Wings API port" "$hdef")"
  sport="$(ask "Wings SFTP port" "2022")"
  base="$(ask "Server data directory" "$WINGS_DATA_DEFAULT")"
  pub_http="$hport"; (( proxy )) && pub_http=443
  [[ $mem =~ ^[0-9]+$ && $disk =~ ^[0-9]+$ && $hport =~ ^[0-9]+$ && $sport =~ ^[0-9]+$ ]] || { error "Memory, disk and ports must be numbers."; press_enter; return 1; }
  line

  ensure_base_deps || { press_enter; return 1; }
  if ! install_docker; then
    warn "Docker is not usable on this machine."
    confirm "Continue anyway (create the node + config now, start Wings later)?" n || { press_enter; return 1; }
  fi
  install_wings    || { press_enter; return 1; }

  step "Creating the node in the panel"
  nid="$(node_helper MP_MODE=create MP_NAME="$name" MP_FQDN="$fqdn" MP_SCHEME="$scheme" MP_BEHIND_PROXY="$proxy" \
        MP_MEMORY="$mem" MP_MEM_OVER="$over_m" MP_DISK="$disk" MP_DISK_OVER="$over_d" MP_UPLOAD="$upl" \
        MP_HTTP_PORT="$hport" MP_SFTP_PORT="$sport" MP_PUBLIC_HTTP="$pub_http" MP_DAEMON_BASE="$base" | sed -n 's/^NODE_ID=//p' | head -n1)"
  if [[ ! $nid =~ ^[0-9]+$ ]]; then
    error "The panel refused to create the node (details: $INSTALL_LOG)."
    note "You can also create it in the admin area → Nodes, then use 'Re-sync config'."
    press_enter; return 1
  fi
  cfg_set NODE_ID "$nid"
  success "Node #$nid created."

  mkdir -p "$base"
  node_sync_config "$nid" || { press_enter; return 1; }

  if confirm "Add game-server port allocations now?" y; then node_add_allocations "$nid" "$fqdn"; fi

  if [[ $scheme == https && $proxy == 0 ]]; then
    warn "HTTPS without a proxy needs a certificate for $fqdn (/etc/letsencrypt/live/$fqdn/)."
    if confirm "Issue a Let's Encrypt certificate for $fqdn now?" n; then issue_node_cert "$fqdn"; fi
  fi

  if confirm "Start the node now?" y; then start_node; return; fi
  press_enter
}

node_add_allocations() {  # node_add_allocations <node id> [alias]
  local nid="$1" alias_in="${2:-}" ip ports pubip out
  pubip="$(public_ip)"
  ip="0.0.0.0"
  if hostname -I 2>/dev/null | tr ' ' '\n' | grep -Fx "$pubip" >/dev/null; then ip="$pubip"; fi
  ip="$(ask "IP the game servers bind to (0.0.0.0 = every interface)" "$ip")"
  ports="$(ask "Ports (comma separated, ranges allowed, >1024)" "25565-25600")"
  out="$(node_helper MP_MODE=allocate MP_NODE_ID="$nid" MP_IP="$ip" MP_PORTS="$ports" MP_ALIAS="$alias_in")"
  if [[ $out == *ALLOCATIONS_OK* ]]; then success "Allocations added ($ip : $ports)."
  else error "Could not add allocations (see $INSTALL_LOG). Add them in the panel: Nodes → Allocation."; return 1; fi
}

node_allocations_menu() {
  banner; step "Add port allocations to a node"
  require_panel || { press_enter; return 1; }
  load_runtime  || { press_enter; return 1; }
  ensure_db_running || { press_enter; return 1; }
  artisan p:node:list --no-interaction 2>/dev/null
  local nid; nid="$(ask "Node ID" "$(cfg_get NODE_ID "")")"
  [[ $nid =~ ^[0-9]+$ ]] || { error "Enter a numeric node ID."; press_enter; return 1; }
  node_add_allocations "$nid" "$(ask "Display alias (optional, e.g. play.example.com)" "")"
  press_enter
}

node_resync() {
  banner; step "Re-sync the node configuration from the local panel"
  need_root "Node setup" || { press_enter; return 1; }
  require_panel || { press_enter; return 1; }
  load_runtime  || { press_enter; return 1; }
  ensure_db_running || { press_enter; return 1; }
  artisan p:node:list --no-interaction 2>/dev/null
  local nid; nid="$(ask "Node ID" "$(cfg_get NODE_ID "")")"
  [[ $nid =~ ^[0-9]+$ ]] || { error "Enter a numeric node ID."; press_enter; return 1; }
  node_sync_config "$nid" || { press_enter; return 1; }
  cfg_set NODE_ID "$nid"
  if svc_defined wings && svc_running wings; then svc_restart wings && success "Wings restarted with the new configuration."; fi
  press_enter
}

# ----------------------------------------------------------------------------
# Configure node — this machine is ONLY a node; the panel runs elsewhere
# ----------------------------------------------------------------------------
read_block() {  # read lines until a line that only says EOF
  local l buf=""
  while IFS= read -r l; do [[ $l == EOF ]] && break; buf+="$l"$'\n'; done
  printf '%s' "$buf"
}

node_setup_remote() {
  banner; step "Set this machine up as a node for a REMOTE panel"
  need_root "Node setup" || { press_enter; return 1; }
  detect_system
  ensure_base_deps || { press_enter; return 1; }
  if ! install_docker; then
    warn "Docker is not usable on this machine."
    confirm "Continue anyway (download the config now, start Wings later)?" n || { press_enter; return 1; }
  fi
  install_wings    || { press_enter; return 1; }
  line
  printf "  ${BOLD_CYAN}1)${RESET} Paste the auto-deploy command from the panel ${GRAY}(Nodes → your node → Configuration)${RESET}\n"
  printf "  ${BOLD_CYAN}2)${RESET} Paste the config.yml contents\n"
  printf "  ${BOLD_CYAN}3)${RESET} Enter panel URL, API token and node ID by hand\n"
  local how; how="$(ask "Choose" "1")"
  local purl="" tok="" nid="" insecure=0 cmd re
  case "$how" in
    1)
      cmd="$(ask "Paste the command" "")"
      re='--panel-url[ =]+([^ ]+)';  [[ $cmd =~ $re ]] && purl="${BASH_REMATCH[1]}"
      re='--token[ =]+([^ ]+)';      [[ $cmd =~ $re ]] && tok="${BASH_REMATCH[1]}"
      re='--node[ =]+([^ ]+)';       [[ $cmd =~ $re ]] && nid="${BASH_REMATCH[1]}"
      [[ $cmd == *--allow-insecure* ]] && insecure=1
      ;;
    3)
      purl="$(ask "Panel URL (e.g. https://panel.example.com)" "")"
      tok="$(ask_secret "Application API token (ptla_…)")"
      nid="$(ask "Node ID" "1")"
      confirm "Allow an insecure (http / self-signed) panel URL?" n && insecure=1
      ;;
    2)
      info "Paste the config.yml, then type EOF on its own line and press Enter:"
      local yml; yml="$(read_block)"
      if [[ $yml != *"uuid:"* || $yml != *"token:"* ]]; then error "That does not look like a Wings config."; press_enter; return 1; fi
      mkdir -p /etc/pterodactyl; printf '%s' "$yml" > "$WINGS_CONF"; chmod 600 "$WINGS_CONF"
      success "Wrote $WINGS_CONF"
      if confirm "Start the node now?" y; then start_node; return; fi
      press_enter; return 0 ;;
    *) warn "Invalid choice."; press_enter; return 1 ;;
  esac
  if [[ -z $purl || -z $tok || -z $nid ]]; then error "Could not read panel URL / token / node ID."; press_enter; return 1; fi
  local -a args=(configure --panel-url "$purl" --token "$tok" --node "$nid" --override)
  (( insecure )) && args+=(--allow-insecure)
  info "Running: wings configure --panel-url $purl --node $nid …"
  if ( cd /etc/pterodactyl && "$WINGS_BIN" "${args[@]}" ) >>"$INSTALL_LOG" 2>&1 && [[ -f $WINGS_CONF ]]; then
    chmod 600 "$WINGS_CONF"; success "Configuration downloaded from the panel."
  else
    error "wings configure failed (see $INSTALL_LOG). Check the token, node ID and that this machine can reach the panel."
    tail -n 6 "$INSTALL_LOG" | sed 's/^/    /'
    press_enter; return 1
  fi
  if confirm "Start the node now?" y; then start_node; return; fi
  press_enter
}

issue_node_cert() {  # issue_node_cert <fqdn>
  local fqdn="$1" email
  need_root "Certificates" || return 1
  if ! command -v certbot >/dev/null 2>&1; then
    case "$PKG" in
      apt|dnf|yum|apk) pkg_install_logged "Installing certbot" certbot || return 1 ;;
      *) error "Install certbot manually."; return 1 ;;
    esac
  fi
  if port_in_use 80; then
    warn "Port 80 is busy (certbot --standalone needs it). Stop the service using it, or use a DNS-based certificate."
    confirm "Try anyway?" n || return 1
  fi
  email="$(ask "Email for Let's Encrypt" "$(env_get APP_SERVICE_AUTHOR "")")"
  [[ -n $email ]] || { error "Email required."; return 1; }
  if certbot certonly --standalone -d "$fqdn" -m "$email" --agree-tos -n >>"$INSTALL_LOG" 2>&1; then
    success "Certificate issued: /etc/letsencrypt/live/$fqdn/"
  else
    error "certbot failed (see $INSTALL_LOG). Make sure $fqdn points to this machine and port 80 is reachable."
    return 1
  fi
}

node_cert_menu() {
  banner; step "Let's Encrypt certificate for a node domain"
  local d; d="$(ask "Domain (must already point to this machine)" "")"
  [[ -n $d ]] || return 0
  issue_node_cert "$d"; press_enter
}

update_wings() {
  banner; step "Updating Wings"
  need_root "Updating Wings" || { press_enter; return 1; }
  detect_system
  local was=0
  svc_defined wings && svc_running wings && was=1
  (( was )) && svc_stop wings
  install_wings force || { (( was )) && svc_start wings; press_enter; return 1; }
  (( was )) && { define_wings_service; svc_start wings && success "Wings restarted."; }
  press_enter
}

# ----------------------------------------------------------------------------
# 7) Configure Nodes (menu)
# ----------------------------------------------------------------------------
node_menu() {
  while true; do
    banner
    printf "${BOLD}Configure Nodes${RESET}  ${GRAY}(Docker + Wings)${RESET}\n\n"
    printf "  ${BOLD_GREEN}1)${RESET} Local node        ${GRAY}— panel + node on THIS machine: create node, install, configure, start${RESET}\n"
    printf "  ${BOLD_GREEN}2)${RESET} Remote node       ${GRAY}— this machine is only a node for a panel elsewhere${RESET}\n"
    printf "  ${BOLD_YELLOW}3)${RESET} Install Docker + Wings only\n"
    printf "  ${BOLD_YELLOW}4)${RESET} Re-sync config from the local panel ${GRAY}(after a URL change)${RESET}\n"
    printf "  ${BOLD_YELLOW}5)${RESET} Add port allocations to a node\n"
    printf "  ${BOLD_YELLOW}6)${RESET} Issue a Let's Encrypt certificate\n"
    printf "  ${CYAN}7)${RESET} Update Wings\n"
    printf "  ${BOLD_RED}0)${RESET} Back\n\n"
    line
    local c; printf "${YELLOW}Select an option [0-7]: ${RESET}"; read -r c || return 0
    case "$c" in
      1) node_setup_local ;;
      2) node_setup_remote ;;
      3) banner; detect_system; install_docker && install_wings; press_enter ;;
      4) node_resync ;;
      5) node_allocations_menu ;;
      6) node_cert_menu ;;
      7) update_wings ;;
      0) return 0 ;;
      *) warn "Invalid selection: '$c'"; sleep 1 ;;
    esac
    [[ "${MP_CLI:-0}" == 1 ]] && return 0
  done
}

# ----------------------------------------------------------------------------
# Public URL (APP_URL) helper — also used after connecting a tunnel
# ----------------------------------------------------------------------------
apply_public_url() {  # apply_public_url https://panel.example.com
  local url="${1%/}" s
  panel_installed || { warn "Panel not installed — nothing to update."; return 1; }
  [[ $url =~ ^https?:// ]] || { error "The URL must start with http:// or https://"; return 1; }
  load_runtime >/dev/null 2>&1 || true
  cfg_set APP_URL_PROD ""   # an explicit URL choice wins over the saved production URL
  env_set APP_URL "$url"
  if [[ $url == https://* ]]; then
    env_set SESSION_SECURE_COOKIE true
    env_set TRUSTED_PROXIES '*'
  else
    env_set SESSION_SECURE_COOKIE false
  fi
  fix_perms
  artisan config:clear --no-interaction >>"$INSTALL_LOG" 2>&1
  for s in php-fpm queue serve; do
    if svc_defined "$s" && svc_running "$s"; then svc_restart "$s" >/dev/null 2>&1; fi
  done
  success "APP_URL is now $url"
  if [[ -f $WINGS_CONF && -n "$(cfg_get NODE_ID "")" ]]; then
    warn "This machine also runs a node whose config points at the old panel URL."
    if confirm "Re-sync the node config and restart Wings?" y; then
      node_sync_config "$(cfg_get NODE_ID)" && { svc_defined wings && svc_running wings && svc_restart wings; }
    fi
  fi
  return 0
}

set_panel_url_menu() {
  banner; step "Change the panel URL (APP_URL)"
  require_panel || { press_enter; return 1; }
  local cur new; cur="$(env_get APP_URL)"
  new="$(ask "New panel URL" "$cur")"
  [[ $new != "$cur" ]] && apply_public_url "$new"
  press_enter
}

# ----------------------------------------------------------------------------
# 10) Cloudflare Tunnel
# ----------------------------------------------------------------------------
CF_BIN=""

install_cloudflared() {
  step "cloudflared"
  CF_BIN="$(command -v cloudflared 2>/dev/null || true)"
  if [[ -z $CF_BIN && -x "$BIN_DIR/cloudflared" ]]; then CF_BIN="$BIN_DIR/cloudflared"; fi
  if [[ -n $CF_BIN ]]; then success "cloudflared found: $CF_BIN ($("$CF_BIN" --version 2>&1 | head -n1))"; return 0; fi
  detect_system
  info "Downloading cloudflared (linux/$ARCH)"
  mkdir -p "$BIN_DIR"
  if ! curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o "$BIN_DIR/cloudflared.new" >>"$INSTALL_LOG" 2>&1; then
    rm -f "$BIN_DIR/cloudflared.new"
    error "Download failed (see $INSTALL_LOG)."; return 1
  fi
  chmod 755 "$BIN_DIR/cloudflared.new" && mv -f "$BIN_DIR/cloudflared.new" "$BIN_DIR/cloudflared"
  CF_BIN="$BIN_DIR/cloudflared"
  success "cloudflared installed: $CF_BIN"
}

extract_tunnel_token() {  # accepts a bare token OR the whole "cloudflared service install <token>" command
  local in="$1" re='(eyJ[A-Za-z0-9_=-]{20,})'
  if [[ $in =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
  return 1
}

quick_tunnel_url() {
  [[ -f "$LOG_DIR/cloudflared-quick.log" ]] || return 0
  grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/cloudflared-quick.log" 2>/dev/null | tail -n1
}

tunnel_target_port() {
  local p; p="$(cfg_get PANEL_PORT "")"
  [[ -n $p ]] || p="$(default_panel_port)"
  if [[ "$(cfg_get RUN_MODE production)" == development && -n "$(cfg_get DEV_PORT "")" ]]; then p="$(cfg_get DEV_PORT)"; fi
  printf '%s' "$p"
}

tunnel_connect_token() {
  banner; step "Connect a Cloudflare Tunnel (your own domain)"
  install_cloudflared || { press_enter; return 1; }
  note "Cloudflare Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared."
  note "Copy the token OR the whole 'cloudflared service install …' command it shows."
  local raw tok
  raw="$(ask "Paste token / command" "")"
  tok="$(extract_tunnel_token "$raw")" || { error "No tunnel token found in what you pasted."; press_enter; return 1; }
  umask 077
  printf 'TUNNEL_TOKEN=%s\n' "$tok" > "$MP_HOME/secrets/cloudflared.env"
  umask 022
  chmod 600 "$MP_HOME/secrets/cloudflared.env"
  svc_define cloudflared "$MP_HOME" "" "$MP_HOME/secrets/cloudflared.env" "Cloudflare Tunnel (MonoPanel)" \
    "$CF_BIN" tunnel --no-autoupdate run
  svc_stop cloudflared
  svc_start cloudflared || { error "cloudflared did not start (see $LOG_DIR/cloudflared.log)."; press_enter; return 1; }
  info "Waiting for the tunnel to register with Cloudflare…"
  local i ok=0
  for i in $(seq 1 25); do
    if grep -q "Registered tunnel connection" "$LOG_DIR/cloudflared.log" 2>/dev/null; then ok=1; break; fi
    svc_running cloudflared || break
    sleep 1
  done
  if (( ok )); then success "Tunnel connected."
  else warn "No 'registered' message yet — check: View Logs → cloudflared."; tail -n 5 "$LOG_DIR/cloudflared.log" 2>/dev/null | sed 's/^/    /'; fi
  line
  local port; port="$(tunnel_target_port)"
  info "In the tunnel's Public Hostname tab, add your domain and point it to:"
  printf "    ${BOLD_CYAN}HTTP  →  http://localhost:%s${RESET}   ${GRAY}(the panel)${RESET}\n" "$port"
  note "For a node behind the tunnel: another hostname → http://localhost:<Wings port>."
  local host
  host="$(ask "Public hostname you mapped (e.g. panel.example.com, Enter to skip)" "")"
  if [[ -n $host ]]; then
    host="${host#http://}"; host="${host#https://}"; host="${host%/}"
    if panel_installed; then apply_public_url "https://${host}"; fi
  fi
  press_enter
}

tunnel_quick() {
  banner; step "Quick tunnel (temporary trycloudflare.com URL, no account needed)"
  install_cloudflared || { press_enter; return 1; }
  local port; port="$(tunnel_target_port)"
  info "Exposing http://127.0.0.1:${port}"
  : > "$LOG_DIR/cloudflared-quick.log"
  svc_define cloudflared-quick "$MP_HOME" "" "" "Cloudflare quick tunnel (MonoPanel)" \
    "$CF_BIN" tunnel --no-autoupdate --url "http://127.0.0.1:${port}"
  svc_stop cloudflared-quick
  svc_start cloudflared-quick || { error "cloudflared did not start."; press_enter; return 1; }
  local i url=""
  for i in $(seq 1 30); do url="$(quick_tunnel_url)"; [[ -n $url ]] && break; sleep 1; done
  if [[ -n $url ]]; then
    success "Your temporary public URL:  $url"
    note "It changes every time the tunnel restarts."
    if panel_installed && confirm "Set it as the panel URL (APP_URL) now?" y; then apply_public_url "$url"; fi
  else
    warn "No URL yet — check: View Logs → cloudflared-quick."
  fi
  press_enter
}

tunnel_start_saved() {
  banner; step "Start the saved tunnel"
  if svc_defined cloudflared; then svc_start cloudflared && success "cloudflared started." || error "Failed — see $LOG_DIR/cloudflared.log"
  elif svc_defined cloudflared-quick; then svc_start cloudflared-quick && success "Quick tunnel started: $(quick_tunnel_url)"
  else warn "No tunnel configured yet."; fi
  press_enter
}

tunnel_stop() {
  banner; step "Stop tunnels"
  local s any=0
  for s in cloudflared cloudflared-quick; do
    if svc_defined "$s" && svc_running "$s"; then svc_stop "$s"; success "$s stopped"; any=1; fi
  done
  (( any )) || info "No tunnel was running."
  press_enter
}

cloudflared_menu() {
  while true; do
    banner
    printf "${BOLD}Cloudflare Tunnel${RESET}\n\n"
    printf "  ${BOLD_GREEN}1)${RESET} Connect with a tunnel token   ${GRAY}— your own domain (recommended)${RESET}\n"
    printf "  ${BOLD_GREEN}2)${RESET} Quick tunnel                  ${GRAY}— random trycloudflare.com URL, no account${RESET}\n"
    printf "  ${BOLD_YELLOW}3)${RESET} Start saved tunnel\n"
    printf "  ${BOLD_YELLOW}4)${RESET} Stop tunnel(s)\n"
    printf "  ${CYAN}5)${RESET} Change the panel URL (APP_URL)\n"
    printf "  ${BOLD_RED}0)${RESET} Back\n\n"
    line
    printf "  cloudflared: %b   quick: %b   %s\n\n" "$(svc_state cloudflared)" "$(svc_state cloudflared-quick)" "$(quick_tunnel_url)"
    local c; printf "${YELLOW}Select an option [0-5]: ${RESET}"; read -r c || return 0
    case "$c" in
      1) tunnel_connect_token ;;
      2) tunnel_quick ;;
      3) tunnel_start_saved ;;
      4) tunnel_stop ;;
      5) set_panel_url_menu ;;
      0) return 0 ;;
      *) warn "Invalid selection: '$c'"; sleep 1 ;;
    esac
    [[ "${MP_CLI:-0}" == 1 ]] && return 0
  done
}

# ----------------------------------------------------------------------------
# Self-update (installer repo → main branch)
# ----------------------------------------------------------------------------
self_update() {
  banner; step "Updating this script"
  if [[ -z $SCRIPT_URL ]]; then
    note "Set the raw URL of monopanel.sh in your installer repo (main branch), e.g."
    note "https://raw.githubusercontent.com/Srccodeusr/<installer-repo>/main/monopanel.sh"
    SCRIPT_URL="$(ask "Script URL" "")"
    [[ -n $SCRIPT_URL ]] || { press_enter; return 0; }
    cfg_set SCRIPT_URL "$SCRIPT_URL"
  fi
  local tmp remote_v; tmp="$(mktemp "$MP_HOME/tmp/monopanel.XXXXXX")"
  if ! curl -fsSL "$SCRIPT_URL" -o "$tmp"; then error "Download failed: $SCRIPT_URL"; rm -f "$tmp"; press_enter; return 1; fi
  if ! bash -n "$tmp" 2>/dev/null; then error "The downloaded file is not a valid bash script — aborting."; rm -f "$tmp"; press_enter; return 1; fi
  remote_v="$(sed -n 's/^MP_VERSION="\(.*\)"/\1/p' "$tmp" | head -n1)"
  info "Installed: v$MP_VERSION   ·   Remote: v${remote_v:-?}"
  if [[ -z ${SELF:-} || ! -w $SELF ]]; then
    warn "This copy is not a writable file (piped run?). Saved the new version to $MP_HOME/monopanel.sh"
    install -m 755 "$tmp" "$MP_HOME/monopanel.sh"; rm -f "$tmp"; press_enter; return 0
  fi
  if cmp -s "$tmp" "$SELF"; then success "Already up to date."; rm -f "$tmp"; press_enter; return 0; fi
  install -m 755 "$tmp" "$SELF" && rm -f "$tmp"
  success "Updated $SELF — restarting the script."
  sleep 1
  exec bash "$SELF"
}

# ----------------------------------------------------------------------------
# Tools menu
# ----------------------------------------------------------------------------
tools_menu() {
  while true; do
    banner
    printf "${BOLD}Tools${RESET}\n\n"
    printf "  ${CYAN}1)${RESET} Status\n"
    printf "  ${CYAN}2)${RESET} View logs\n"
    printf "  ${CYAN}3)${RESET} Backup database + .env\n"
    printf "  ${CYAN}4)${RESET} Create an admin user\n"
    printf "  ${CYAN}5)${RESET} Change the panel URL (APP_URL)\n"
    printf "  ${CYAN}6)${RESET} Re-check / install dependencies\n"
    printf "  ${CYAN}7)${RESET} Update this script\n"
    printf "  ${BOLD_RED}8)${RESET} Stop everything MonoPanel started\n"
    printf "  ${BOLD_RED}0)${RESET} Back\n\n"
    line
    local c; printf "${YELLOW}Select an option [0-8]: ${RESET}"; read -r c || return 0
    case "$c" in
      1) show_status ;;
      2) view_logs ;;
      3) backup_panel ;;
      4) banner; create_admin; press_enter ;;
      5) set_panel_url_menu ;;
      6) banner; detect_system; ensure_base_deps && install_php && ensure_composer && install_node && ensure_nginx; press_enter ;;
      7) self_update ;;
      8) stop_everything ;;
      0) return 0 ;;
      *) warn "Invalid selection: '$c'"; sleep 1 ;;
    esac
  done
}

# ----------------------------------------------------------------------------
# Main menu
# ----------------------------------------------------------------------------
menu_badge() {  # menu_badge <label> <running 0/1>
  if (( $2 )); then printf "${BOLD_GREEN}● %s${RESET}" "$1"; else printf "${GRAY}○ %s${RESET}" "$1"; fi
}

main_menu() {
  while true; do
    banner
    local p=0 n=0 t=0 mode
    { svc_running nginx || svc_running serve; } && p=1
    svc_defined wings && svc_running wings && n=1
    { svc_defined cloudflared && svc_running cloudflared; } || { svc_defined cloudflared-quick && svc_running cloudflared-quick; } && t=1
    mode="$(cfg_get RUN_MODE -)"
    printf "  %b   %b   %b   ${GRAY}mode: %s · %s${RESET}\n" "$(menu_badge panel "$p")" "$(menu_badge node "$n")" "$(menu_badge tunnel "$t")" "$mode" "$(if use_systemd; then echo systemd; else echo built-in supervisor; fi)"
    printf "  ${GRAY}%s  ·  branch %s${RESET}\n\n" "$PANEL_DIR" "$PANEL_BRANCH"

    printf "  ${BOLD_GREEN} 1)${RESET} %-26s ${GRAY}%s${RESET}\n" "Install Panel" "dependencies, database, build, admin"
    printf "  ${BOLD_GREEN} 2)${RESET} %-26s ${GRAY}%s${RESET}\n" "Run Panel (Production)" "nginx + php-fpm + queue + scheduler"
    printf "  ${BOLD_GREEN} 3)${RESET} %-26s ${GRAY}%s${RESET}\n" "Run Panel (Development)" "artisan serve + Vite hot reload"
    printf "  ${BOLD_YELLOW} 4)${RESET} %-26s\n" "Stop Panel"
    printf "  ${BOLD_YELLOW} 5)${RESET} %-26s ${GRAY}%s${RESET}\n" "Update Panel" "pull, build, migrate, restart"
    printf "  ${BOLD_MAGENTA} 6)${RESET} %-26s ${GRAY}%s${RESET}\n" "Configure Nodes" "Docker + Wings, create & configure"
    printf "  ${BOLD_MAGENTA} 7)${RESET} %-26s\n" "Start Nodes"
    printf "  ${BOLD_MAGENTA} 8)${RESET} %-26s\n" "Stop Nodes"
    printf "  ${BOLD_CYAN} 9)${RESET} %-26s ${GRAY}%s${RESET}\n" "Connect Cloudflared" "tunnel token or quick tunnel"
    printf "  ${CYAN}10)${RESET} %-26s ${GRAY}%s${RESET}\n" "Tools" "status, logs, backup, admin, script update"
    printf "  ${BOLD_RED} 0)${RESET} Exit\n\n"
    line
    printf "${YELLOW}Select an option [0-10]: ${RESET}"
    local choice; read -r choice || { echo; exit 0; }

    case "$choice" in
      1)  install_panel ;;
      2)  run_panel production ;;
      3)  run_panel development ;;
      4)  stop_panel ;;
      5)  update_panel ;;
      6)  node_menu ;;
      7)  start_node ;;
      8)  stop_node ;;
      9)  cloudflared_menu ;;
      10) tools_menu ;;
      0)
        banner
        printf "${BOLD_MAGENTA}Goodbye from MonoPanel Installer & Executer.${RESET}\n"
        printf "${GRAY}Made by %s${RESET}\n\n" "$MP_AUTHOR"
        exit 0 ;;
      *)  warn "Invalid selection: '$choice' — choose a number from the menu."; sleep 1.2 ;;
    esac
  done
}

print_help() {
  cat <<EOF
MonoPanel Installer & Executer v${MP_VERSION} — made by ${MP_AUTHOR}

Usage: sudo bash monopanel.sh [command]

  (no command)   interactive menu
  install        install the panel (dependencies, database, build)
  run-prod       start the panel in production mode
  run-dev        start the panel in development mode (Vite hot reload)
  stop           stop the panel processes
  restart        restart the panel in its last mode
  update         pull the latest code, rebuild, migrate, restart
  admin          create an administrator account
  node-setup     node menu (Docker + Wings: local or remote)
  node-start     start Wings          node-stop   stop Wings
  node-sync      re-sync node config from the local panel
  tunnel         Cloudflare Tunnel menu
  status | logs | backup | self-update | help

Environment: MONOPANEL_REPO, MONOPANEL_BRANCH, MONOPANEL_DIR, MONOPANEL_HOME,
MONOPANEL_GIT_TOKEN, MONOPANEL_SCRIPT_URL, MP_INIT=systemd|builtin,
MP_ASSUME_DEFAULTS=1, MP_BUILD_MEM, MP_VITE_PUBLIC_URL
EOF
}

# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------
main() {
  local cmd="${1:-menu}" src

  IS_ROOT=0; (( EUID == 0 )) && IS_ROOT=1
  SUDO=""; if (( ! IS_ROOT )) && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
  SELF=""; src="${BASH_SOURCE[0]:-$0}"
  [[ -f $src ]] && SELF="$(readlink -f "$src" 2>/dev/null || echo "$src")"

  case "$cmd" in help|-h|--help) print_help; return 0 ;; esac
  [[ $cmd != menu ]] && MP_CLI=1

  # `curl … | bash` gives us a pipe as stdin — read answers from the terminal instead.
  if [[ ! -t 0 ]]; then
    if [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; then exec </dev/tty; else MP_ASSUME_DEFAULTS=1; fi
  fi

  # Most steps need root: offer to re-launch through sudo when we can.
  if (( ! IS_ROOT )) && [[ -n $SUDO && -n $SELF && "${MP_NO_SUDO:-0}" != 1 ]]; then
    if [[ "${MP_CLI:-0}" == 1 ]] || confirm "Not running as root — re-launch with sudo?" y; then
      exec sudo -E bash "$SELF" "$@"
    fi
  fi

  init_env || return 1
  detect_system

  case "$cmd" in
    menu)         trap 'printf "\n"; warn "Interrupted — use option 0 to exit."' INT; main_menu ;;
    install)      install_panel ;;
    run-prod|run) run_panel production ;;
    run-dev)      run_panel development ;;
    stop)         stop_panel ;;
    restart)      restart_panel ;;
    update)       update_panel ;;
    admin)        create_admin ;;
    node-setup)   node_menu ;;
    node-start)   start_node ;;
    node-stop)    stop_node ;;
    node-sync)    node_resync ;;
    tunnel)       cloudflared_menu ;;
    status)       show_status ;;
    logs)         view_logs ;;
    backup)       backup_panel ;;
    self-update)  self_update ;;
    *)            error "Unknown command: $cmd"; print_help; return 1 ;;
  esac
}

# Sourcing for tests: MONOPANEL_SOURCE_ONLY=1 . monopanel.sh
# (keep `main` and `exit` on ONE line so `curl … | bash` can safely swap stdin)
if [[ "${MONOPANEL_SOURCE_ONLY:-0}" != "1" ]]; then main "$@"; exit $?; fi
