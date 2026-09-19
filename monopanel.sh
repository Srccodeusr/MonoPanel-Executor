#!/usr/bin/env bash
#
# ==============================================================================
#  MonoPanel Executor
# ==============================================================================
#
#  MonoPanel is a UI-revamped fork of JexPanel (Jexactyl), which itself is
#  built on top of Pterodactyl Panel. This script is a management/installer
#  executor for MonoPanel only — it does not alter panel source code.
#
#  Repository : https://github.com/Srccodeusr/MonoPanel
#  Branch     : develop
#
#  CREDITS
#  -------
#  MonoPanel is owned and maintained by prime.dev1, who forked JexPanel to
#  build a customised panel for his business and commercial use. Full credit
#  for the underlying panel goes to the Jexactyl team and, by extension, the
#  Pterodactyl Panel project and community — this executor merely automates
#  installing, running, and maintaining that work. Thank you to the original
#  authors and the wider open-source community.
#
#  This executor script itself was generated with the assistance of Claude
#  (Anthropic).
#
# ==============================================================================

set -uo pipefail

# ------------------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------------------

REPO_URL="https://github.com/Srccodeusr/MonoPanel.git"
REPO_BRANCH="develop"
PANEL_DIR="/var/www/monopanel"
SCRIPT_VERSION="1.0.0"
LOG_FILE="/var/log/monopanel-executor.log"
STATE_FILE="/etc/monopanel/executor.state"

SERVICE_MODE=""     # systemd | supervisor | manual  (detected/selected)
WEBSERVER_USER="www-data"

# ------------------------------------------------------------------------------
# Colours
# ------------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[38;5;203m'
  C_GREEN=$'\033[38;5;114m'
  C_YELLOW=$'\033[38;5;221m'
  C_BLUE=$'\033[38;5;75m'
  C_CYAN=$'\033[38;5;80m'
  C_MAGENTA=$'\033[38;5;177m'
  C_ORANGE=$'\033[38;5;215m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_CYAN=""; C_MAGENTA=""; C_ORANGE=""
fi

# ------------------------------------------------------------------------------
# Logging / output helpers
# ------------------------------------------------------------------------------

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
  local level="$1"; shift
  local msg="$*"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo "[$(_ts)] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

say()      { echo -e "  $*"; }
info()     { echo -e "  ${C_BLUE}i${C_RESET}  $*"; log "INFO" "$*"; }
success()  { echo -e "  ${C_GREEN}✔${C_RESET}  $*"; log "OK" "$*"; }
warn()     { echo -e "  ${C_YELLOW}!${C_RESET}  $*"; log "WARN" "$*"; }
error()    { echo -e "  ${C_RED}✘${C_RESET}  $*"; log "ERROR" "$*"; }
step()     { echo -e "\n${C_CYAN}${C_BOLD}▶ $*${C_RESET}"; log "STEP" "$*"; }

die() {
  error "$*"
  exit 1
}

confirm() {
  # confirm "Question text" [default: y]
  local prompt="$1"
  local default="${2:-y}"
  local yn
  if [[ "$default" == "y" ]]; then
    read -r -p "  $(echo -e "${C_YELLOW}?${C_RESET}") $prompt [Y/n]: " yn
    yn="${yn:-y}"
  else
    read -r -p "  $(echo -e "${C_YELLOW}?${C_RESET}") $prompt [y/N]: " yn
    yn="${yn:-n}"
  fi
  [[ "$yn" =~ ^[Yy]$ ]]
}

ask() {
  # ask "Prompt" "default"
  local prompt="$1"
  local default="${2:-}"
  local val
  if [[ -n "$default" ]]; then
    read -r -p "  $(echo -e "${C_YELLOW}?${C_RESET}") $prompt [$default]: " val
    echo "${val:-$default}"
  else
    read -r -p "  $(echo -e "${C_YELLOW}?${C_RESET}") $prompt: " val
    echo "$val"
  fi
}

ask_required() {
  local prompt="$1"
  local val=""
  while [[ -z "$val" ]]; do
    val=$(ask "$prompt")
    [[ -z "$val" ]] && warn "This field is required."
  done
  echo "$val"
}

ask_secret() {
  local prompt="$1"
  local val
  read -r -s -p "  $(echo -e "${C_YELLOW}?${C_RESET}") $prompt: " val
  echo >&2
  echo "$val"
}

banner() {
  clear 2>/dev/null || true
  echo -e "${C_MAGENTA}${C_BOLD}"
  cat <<'EOF'
   __  __                  ____                 _
  |  \/  | ___  _ __   ___|  _ \ __ _ _ __   ___| |
  | |\/| |/ _ \| '_ \ / _ \ |_) / _` | '_ \ / _ \ |
  | |  | | (_) | | | | (_) |  __/ (_| | | | |  __/ |
  |_|  |_|\___/|_| |_|\___/|_|   \__,_|_| |_|\___|_|
EOF
  echo -e "${C_RESET}"
  echo -e "  ${C_DIM}Executor v${SCRIPT_VERSION} · fork of JexPanel · owned by prime.dev1${C_RESET}"
  echo -e "  ${C_DIM}https://github.com/Srccodeusr/MonoPanel  (branch: ${REPO_BRANCH})${C_RESET}\n"
}

hr() { echo -e "  ${C_DIM}--------------------------------------------------------------${C_RESET}"; }

pause_return() {
  echo
  read -r -p "  Press ENTER to return to the menu..." _
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (try: sudo bash $0)"
  fi
}

# ------------------------------------------------------------------------------
# Environment / init detection — makes the script work on real VPS, containers,
# systemd hosts, or supervisor-managed hosts, without assuming any of them.
# ------------------------------------------------------------------------------

is_container() {
  # Best-effort detection of running inside a Docker/LXC/OpenVZ container.
  if [[ -f /.dockerenv ]]; then return 0; fi
  if grep -qaE 'docker|lxc|containerd' /proc/1/cgroup 2>/dev/null; then return 0; fi
  if [[ -d /proc/vz && ! -d /proc/bc ]]; then return 0; fi
  return 1
}

has_systemd() {
  # systemd must actually be PID 1 and operable, not just installed.
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl list-units >/dev/null 2>&1 && return 0
  fi
  return 1
}

has_supervisor() {
  command -v supervisorctl >/dev/null 2>&1 || [[ -d /etc/supervisor/conf.d ]]
}

detect_service_mode() {
  if has_systemd; then
    SERVICE_MODE="systemd"
  elif has_supervisor; then
    SERVICE_MODE="supervisor"
  else
    SERVICE_MODE="manual"
  fi
  info "Detected init/process environment: ${C_BOLD}${SERVICE_MODE}${C_RESET}$( is_container && echo ' (container detected)')"
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
  else
    OS_ID="unknown"
    OS_VERSION="unknown"
  fi
  info "Detected OS: ${OS_ID} ${OS_VERSION}"
}

pkg_install() {
  # pkg_install pkg1 pkg2 ...
  case "$OS_ID" in
    ubuntu|debian)
      DEBIAN_FRONTEND=noninteractive apt-get update -y >>"$LOG_FILE" 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >>"$LOG_FILE" 2>&1
      ;;
    almalinux|rocky|centos|rhel|fedora)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@" >>"$LOG_FILE" 2>&1
      else
        yum install -y "$@" >>"$LOG_FILE" 2>&1
      fi
      ;;
    *)
      warn "Unrecognised OS ('$OS_ID'). Please make sure these are installed manually: $*"
      return 1
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Dependency checks / install (PHP 8.4+, Composer, Node, pnpm, MySQL/MariaDB,
# Redis, git, curl, tar, unzip)
# ------------------------------------------------------------------------------

check_cmd() { command -v "$1" >/dev/null 2>&1; }

php_version_ok() {
  check_cmd php || return 1
  local ver
  ver=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
  [[ -z "$ver" ]] && return 1
  local major minor
  major=$(echo "$ver" | cut -d. -f1)
  minor=$(echo "$ver" | cut -d. -f2)
  if [[ "$major" -gt 8 ]]; then return 0; fi
  if [[ "$major" -eq 8 && "$minor" -ge 4 ]]; then return 0; fi
  return 1
}

install_php() {
  case "$OS_ID" in
    ubuntu|debian)
      pkg_install software-properties-common ca-certificates lsb-release apt-transport-https curl gnupg
      if ! grep -rq "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        add-apt-repository -y ppa:ondrej/php >>"$LOG_FILE" 2>&1 || warn "Could not add ondrej/php PPA automatically."
        apt-get update -y >>"$LOG_FILE" 2>&1
      fi
      pkg_install php8.4 php8.4-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,sqlite3,posix}
      ;;
    almalinux|rocky|centos|rhel|fedora)
      pkg_install epel-release yum-utils || true
      dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm >>"$LOG_FILE" 2>&1 || true
      dnf module reset php -y >>"$LOG_FILE" 2>&1 || true
      dnf module enable php:remi-8.4 -y >>"$LOG_FILE" 2>&1 || true
      pkg_install php php-common php-cli php-gd php-mysqlnd php-mbstring php-bcmath php-xml php-fpm php-curl php-zip php-intl php-posix
      ;;
    *)
      die "Unsupported OS for automatic PHP install. Please install PHP 8.4+ manually and re-run."
      ;;
  esac
}

install_composer() {
  curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
  php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer >>"$LOG_FILE" 2>&1
  rm -f /tmp/composer-setup.php
}

install_node() {
  curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | bash - >>"$LOG_FILE" 2>&1 || true
  case "$OS_ID" in
    ubuntu|debian) pkg_install nodejs ;;
    almalinux|rocky|centos|rhel|fedora)
      curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - >>"$LOG_FILE" 2>&1 || true
      pkg_install nodejs
      ;;
    *) die "Unsupported OS for automatic Node.js install. Please install Node 20+ manually." ;;
  esac
}

install_pnpm() {
  npm install -g pnpm@9.0.6 >>"$LOG_FILE" 2>&1
}

install_mysql() {
  case "$OS_ID" in
    ubuntu|debian) pkg_install mariadb-server mariadb-client ;;
    almalinux|rocky|centos|rhel|fedora) pkg_install mariadb-server mariadb ;;
    *) warn "Please install MySQL/MariaDB manually." ; return 1 ;;
  esac
  systemctl enable --now mariadb >>"$LOG_FILE" 2>&1 || service mariadb start >>"$LOG_FILE" 2>&1 || true
}

install_redis() {
  case "$OS_ID" in
    ubuntu|debian) pkg_install redis-server ;;
    almalinux|rocky|centos|rhel|fedora) pkg_install redis ;;
    *) warn "Please install Redis manually." ; return 1 ;;
  esac
  systemctl enable --now redis-server >>"$LOG_FILE" 2>&1 \
    || systemctl enable --now redis >>"$LOG_FILE" 2>&1 \
    || service redis-server start >>"$LOG_FILE" 2>&1 || true
}

ensure_dependencies() {
  step "Checking system dependencies"

  detect_os
  pkg_install curl git unzip tar ca-certificates >/dev/null 2>&1 || true

  if php_version_ok; then
    success "PHP $(php -r 'echo PHP_VERSION;') found"
  else
    warn "PHP 8.4+ not found — installing"
    install_php
    php_version_ok && success "PHP $(php -r 'echo PHP_VERSION;') installed" \
      || die "PHP install failed — check $LOG_FILE"
  fi

  if check_cmd composer; then
    success "Composer found ($(composer --version --no-ansi 2>/dev/null | awk '{print $3}'))"
  else
    warn "Composer not found — installing"
    install_composer
    check_cmd composer && success "Composer installed" || die "Composer install failed — check $LOG_FILE"
  fi

  if check_cmd node && [[ "$(node -v | sed 's/v//' | cut -d. -f1)" -ge 18 ]]; then
    success "Node.js $(node -v) found"
  else
    warn "Node.js 18+ not found — installing Node 20.x"
    install_node
    check_cmd node && success "Node.js $(node -v) installed" || die "Node install failed — check $LOG_FILE"
  fi

  if check_cmd pnpm; then
    success "pnpm found ($(pnpm --version))"
  else
    warn "pnpm not found — installing"
    install_pnpm
    check_cmd pnpm && success "pnpm installed" || die "pnpm install failed — check $LOG_FILE"
  fi

  if check_cmd mysql || check_cmd mariadb; then
    success "MySQL/MariaDB client found"
  else
    warn "No MySQL/MariaDB found"
    if ! is_container; then
      confirm "Install MariaDB server locally now?" y && install_mysql
    else
      warn "Running inside a container — skipping local DB install. Point the panel at an external database when prompted."
    fi
  fi

  if check_cmd redis-cli; then
    success "Redis found"
  else
    warn "Redis not found"
    if ! is_container; then
      confirm "Install Redis locally now?" y && install_redis
    else
      warn "Running inside a container — skipping local Redis install. Point the panel at an external Redis when prompted."
    fi
  fi
}

# ------------------------------------------------------------------------------
# 1) Install Panel
# ------------------------------------------------------------------------------

clone_or_update_repo() {
  step "Fetching MonoPanel source (${REPO_BRANCH} branch)"
  if [[ -d "$PANEL_DIR/.git" ]]; then
    info "Existing installation detected at $PANEL_DIR"
    confirm "Re-clone from scratch? (choosing No will just pull latest)" n && {
      rm -rf "$PANEL_DIR"
    }
  fi

  mkdir -p "$(dirname "$PANEL_DIR")"

  if [[ -d "$PANEL_DIR/.git" ]]; then
    (cd "$PANEL_DIR" && git fetch origin "$REPO_BRANCH" >>"$LOG_FILE" 2>&1 \
      && git checkout "$REPO_BRANCH" >>"$LOG_FILE" 2>&1 \
      && git reset --hard "origin/$REPO_BRANCH" >>"$LOG_FILE" 2>&1) \
      || die "Failed to update existing repo — check $LOG_FILE"
    success "Repository updated"
  else
    git clone --branch "$REPO_BRANCH" --single-branch "$REPO_URL" "$PANEL_DIR" >>"$LOG_FILE" 2>&1 \
      || die "git clone failed — check $LOG_FILE"
    success "Repository cloned to $PANEL_DIR"
  fi
}

build_backend() {
  step "Installing PHP dependencies (composer)"
  (cd "$PANEL_DIR" && composer install --no-dev --optimize-autoloader --no-interaction >>"$LOG_FILE" 2>&1) \
    || die "composer install failed — check $LOG_FILE"
  success "Backend dependencies installed"
}

build_frontend() {
  step "Installing frontend dependencies and building assets (pnpm + vite)"
  (cd "$PANEL_DIR" && pnpm install --frozen-lockfile >>"$LOG_FILE" 2>&1) \
    || (cd "$PANEL_DIR" && pnpm install >>"$LOG_FILE" 2>&1) \
    || die "pnpm install failed — check $LOG_FILE"
  (cd "$PANEL_DIR" && pnpm run build >>"$LOG_FILE" 2>&1) \
    || die "frontend build (vite) failed — check $LOG_FILE"
  success "Frontend assets built"
}

configure_env_file() {
  step "Preparing environment file"
  if [[ ! -f "$PANEL_DIR/.env" ]]; then
    cp "$PANEL_DIR/.env.example" "$PANEL_DIR/.env"
    success ".env created from .env.example"
  else
    info ".env already exists — keeping it"
  fi
}

gather_db_settings() {
  echo
  info "Database configuration (MySQL/MariaDB):"
  DB_HOST=$(ask "Database host" "127.0.0.1")
  DB_PORT=$(ask "Database port" "3306")
  DB_NAME=$(ask "Database name" "monopanel")
  DB_USER=$(ask "Database username" "monopanel")
  DB_PASS=$(ask_secret "Database password")
}

gather_app_settings() {
  echo
  info "General application configuration:"
  APP_URL=$(ask "Panel URL (e.g. https://panel.example.com)" "http://$(hostname -I 2>/dev/null | awk '{print $1}')")
  APP_AUTHOR_EMAIL=$(ask "Author/service email (used for outgoing eggs, etc.)" "admin@$(echo "$APP_URL" | sed -E 's#https?://##')")
  APP_TIMEZONE=$(ask "Timezone" "UTC")
}

gather_admin_account() {
  echo
  info "Admin account for the panel:"
  ADMIN_EMAIL=$(ask_required "Admin email")
  ADMIN_USERNAME=$(ask_required "Admin username")
  ADMIN_FIRSTNAME=$(ask "Admin first name" "Admin")
  ADMIN_LASTNAME=$(ask "Admin last name" "User")
  local pass1 pass2
  while true; do
    pass1=$(ask_secret "Admin password")
    pass2=$(ask_secret "Confirm admin password")
    if [[ "$pass1" == "$pass2" && -n "$pass1" ]]; then
      ADMIN_PASSWORD="$pass1"
      break
    else
      warn "Passwords did not match or were empty — try again."
    fi
  done
}

run_env_setup_commands() {
  step "Writing configuration into .env"

  cd "$PANEL_DIR" || die "Cannot cd into $PANEL_DIR"

  if ! grep -q '^APP_KEY=base64' .env 2>/dev/null; then
    php artisan key:generate --force >>"$LOG_FILE" 2>&1
    success "APP_KEY generated"
  fi

  php artisan p:environment:setup \
    --author="$APP_AUTHOR_EMAIL" \
    --url="$APP_URL" \
    --timezone="$APP_TIMEZONE" \
    --cache=redis \
    --session=redis \
    --queue=redis \
    --redis-host=127.0.0.1 \
    --redis-pass=null \
    --redis-port=6379 \
    --settings-ui=true \
    --telemetry=true \
    --no-interaction >>"$LOG_FILE" 2>&1 \
    || warn "p:environment:setup reported an issue — check $LOG_FILE (you can re-run manually later)"
  success "Application environment configured"

  php artisan p:environment:database \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --database="$DB_NAME" \
    --username="$DB_USER" \
    --password="$DB_PASS" \
    --no-interaction >>"$LOG_FILE" 2>&1 \
    || die "p:environment:database failed — check $LOG_FILE"
  success "Database environment configured"
}

run_migrations() {
  step "Running database migrations and seeders"
  cd "$PANEL_DIR" || die "Cannot cd into $PANEL_DIR"
  php artisan migrate --seed --force >>"$LOG_FILE" 2>&1 \
    || die "Migrations failed — check $LOG_FILE (verify DB credentials/connectivity)"
  success "Database migrated and seeded"
}

create_admin_user() {
  step "Creating admin account"
  cd "$PANEL_DIR" || die "Cannot cd into $PANEL_DIR"
  php artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USERNAME" \
    --name-first="$ADMIN_FIRSTNAME" \
    --name-last="$ADMIN_LASTNAME" \
    --password="$ADMIN_PASSWORD" \
    --admin=1 \
    --no-interaction >>"$LOG_FILE" 2>&1 \
    || die "Admin user creation failed — check $LOG_FILE"
  success "Admin account created (${ADMIN_EMAIL})"
}

set_permissions() {
  step "Setting file permissions"
  cd "$PANEL_DIR" || die "Cannot cd into $PANEL_DIR"
  if id -u "$WEBSERVER_USER" >/dev/null 2>&1; then
    chown -R "${WEBSERVER_USER}:${WEBSERVER_USER}" "$PANEL_DIR" >>"$LOG_FILE" 2>&1
  else
    warn "User '$WEBSERVER_USER' not found on this system — skipping chown. Adjust ownership manually if needed."
  fi
  chmod -R 755 storage bootstrap/cache >>"$LOG_FILE" 2>&1
  success "Permissions set"
}

setup_cron() {
  step "Setting up the panel scheduler (cron)"
  local cron_line="* * * * * php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1"
  if ! crontab -l 2>/dev/null | grep -qF "$PANEL_DIR/artisan schedule:run"; then
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    success "Cron entry added for the scheduler"
  else
    info "Cron entry already present"
  fi
}

setup_queue_worker() {
  step "Setting up the queue worker (${SERVICE_MODE})"
  case "$SERVICE_MODE" in
    systemd)
      cat > /etc/systemd/system/monopanel-queue.service <<EOF
[Unit]
Description=MonoPanel Queue Worker
After=redis.service mariadb.service network.target

[Service]
User=${WEBSERVER_USER}
Group=${WEBSERVER_USER}
Restart=always
RestartSec=5
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload >>"$LOG_FILE" 2>&1
      systemctl enable --now monopanel-queue.service >>"$LOG_FILE" 2>&1
      success "systemd service 'monopanel-queue' created and started"
      ;;
    supervisor)
      mkdir -p /etc/supervisor/conf.d
      cat > /etc/supervisor/conf.d/monopanel-queue.conf <<EOF
[program:monopanel-queue]
process_name=%(program_name)s
command=php ${PANEL_DIR}/artisan queue:work --sleep=3 --tries=3
autostart=true
autorestart=true
user=${WEBSERVER_USER}
numprocs=1
redirect_stderr=true
stdout_logfile=${PANEL_DIR}/storage/logs/queue-worker.log
EOF
      supervisorctl reread >>"$LOG_FILE" 2>&1 || true
      supervisorctl update >>"$LOG_FILE" 2>&1 || true
      supervisorctl start monopanel-queue:* >>"$LOG_FILE" 2>&1 || true
      success "Supervisor program 'monopanel-queue' created and started"
      ;;
    manual)
      warn "No systemd or supervisor detected. Start the queue worker manually with:"
      say "${C_DIM}php ${PANEL_DIR}/artisan queue:work --sleep=3 --tries=3${C_RESET}"
      ;;
  esac
}

install_panel() {
  banner
  step "MonoPanel — Full Installation"
  say "This will install MonoPanel end-to-end: dependency checks, clone,"
  say "build, environment/database configuration, admin account, migrations,"
  say "permissions, cron, and a queue worker service."
  echo
  confirm "Continue with installation?" y || return

  require_root
  detect_service_mode
  ensure_dependencies
  clone_or_update_repo
  configure_env_file
  gather_db_settings
  gather_app_settings
  gather_admin_account
  build_backend
  run_env_setup_commands
  run_migrations
  create_admin_user
  build_frontend
  set_permissions
  setup_cron
  setup_queue_worker

  mkdir -p "$(dirname "$STATE_FILE")"
  cat > "$STATE_FILE" <<EOF
installed_at=$(_ts)
panel_dir=${PANEL_DIR}
service_mode=${SERVICE_MODE}
branch=${REPO_BRANCH}
EOF

  echo
  hr
  success "MonoPanel installation complete!"
  say "Panel directory : ${C_BOLD}${PANEL_DIR}${C_RESET}"
  say "Panel URL       : ${C_BOLD}${APP_URL}${C_RESET}"
  say "Admin email     : ${C_BOLD}${ADMIN_EMAIL}${C_RESET}"
  say "Next steps      : use ${C_BOLD}Run Panel${C_RESET} to start it, and"
  say "                  ${C_BOLD}Configure Nodes${C_RESET} to add a Wings node."
  hr
  pause_return
}

# ------------------------------------------------------------------------------
# 2) Run Panel (Production / Development)
# ------------------------------------------------------------------------------

require_installed() {
  if [[ ! -d "$PANEL_DIR" || ! -f "$PANEL_DIR/artisan" ]]; then
    error "MonoPanel doesn't appear to be installed yet at $PANEL_DIR."
    warn "Run option 1 (Install Panel) first."
    pause_return
    return 1
  fi
  return 0
}

run_production_systemd() {
  cat > /etc/systemd/system/monopanel.service <<EOF
[Unit]
Description=MonoPanel (Production - PHP-FPM/Octane web process)
After=network.target mariadb.service redis.service

[Service]
Type=simple
User=${WEBSERVER_USER}
Group=${WEBSERVER_USER}
WorkingDirectory=${PANEL_DIR}
ExecStart=/usr/bin/php artisan serve --host=0.0.0.0 --port=8000 --env=production
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >>"$LOG_FILE" 2>&1
  systemctl enable --now monopanel.service >>"$LOG_FILE" 2>&1
  success "MonoPanel started via systemd (service: monopanel.service) on port 8000"
  say "For a real production deployment, put nginx/Caddy in front of PHP-FPM"
  say "instead of the built-in server. See ${PANEL_DIR}/Dockerfile for a reference config."
}

run_production_supervisor() {
  mkdir -p /etc/supervisor/conf.d
  cat > /etc/supervisor/conf.d/monopanel-web.conf <<EOF
[program:monopanel-web]
process_name=%(program_name)s
directory=${PANEL_DIR}
command=/usr/bin/php artisan serve --host=0.0.0.0 --port=8000 --env=production
autostart=true
autorestart=true
user=${WEBSERVER_USER}
redirect_stderr=true
stdout_logfile=${PANEL_DIR}/storage/logs/web.log
EOF
  supervisorctl reread >>"$LOG_FILE" 2>&1 || true
  supervisorctl update >>"$LOG_FILE" 2>&1 || true
  supervisorctl start monopanel-web:* >>"$LOG_FILE" 2>&1 || true
  success "MonoPanel started via Supervisor (program: monopanel-web) on port 8000"
}

run_production_manual() {
  info "No systemd/supervisor available — running in foreground."
  warn "Use tmux/screen to keep this alive after you disconnect, or install"
  warn "systemd/supervisor for a persistent setup."
  echo
  (cd "$PANEL_DIR" && php artisan serve --host=0.0.0.0 --port=8000 --env=production)
}

run_production() {
  step "Starting MonoPanel — Production Mode"
  detect_service_mode
  case "$SERVICE_MODE" in
    systemd)    run_production_systemd ;;
    supervisor) run_production_supervisor ;;
    manual)     run_production_manual ;;
  esac
}

run_development() {
  step "Starting MonoPanel — Development Mode"
  info "This runs the Laravel dev server and the Vite dev server together."
  info "Press CTRL+C to stop both when you're done."
  echo
  cd "$PANEL_DIR" || die "Cannot cd into $PANEL_DIR"

  local artisan_pid vite_pid
  php artisan serve --host=0.0.0.0 --port=8000 --env=local &
  artisan_pid=$!
  pnpm run dev &
  vite_pid=$!

  trap 'kill '"$artisan_pid"' '"$vite_pid"' 2>/dev/null' INT TERM
  wait "$artisan_pid" "$vite_pid" 2>/dev/null
  trap - INT TERM
}

run_panel_menu() {
  require_installed || return
  banner
  step "Run Panel"
  echo -e "  ${C_BOLD}1${C_RESET}) Run Production Mode  ${C_DIM}(backgrounded service, port 8000)${C_RESET}"
  echo -e "  ${C_BOLD}2${C_RESET}) Run Development Mode ${C_DIM}(foreground, hot-reload via vite)${C_RESET}"
  echo -e "  ${C_BOLD}0${C_RESET}) Back"
  echo
  local choice
  choice=$(ask "Select an option" "1")
  case "$choice" in
    1) run_production ;;
    2) run_development ;;
    0) return ;;
    *) warn "Invalid option." ;;
  esac
  pause_return
}

# ------------------------------------------------------------------------------
# 3) Configure Nodes
# ------------------------------------------------------------------------------

configure_nodes() {
  require_installed || return
  banner
  step "Configure Nodes"
  say "This creates a node record in the panel database and shows you the"
  say "Wings configuration needed on the machine that will run game servers."
  echo

  cd "$PANEL_DIR" || die "Cannot cd into $PANEL_DIR"

  local name desc fqdn scheme public proxy maintenance
  name=$(ask_required "Node name (short identifier)")
  desc=$(ask "Node description" "Managed by MonoPanel")
  fqdn=$(ask_required "Node FQDN or IP (e.g. node1.example.com)")

  if confirm "Enable SSL for this node? (recommended, requires a resolvable FQDN)" y; then
    scheme="https"
  else
    scheme="http"
  fi

  confirm "Should this node be public (visible for auto-deploy)?" y && public=1 || public=0
  confirm "Is this node behind a proxy (e.g. Cloudflare)?" n && proxy=1 || proxy=0
  confirm "Enable maintenance mode on creation?" n && maintenance=1 || maintenance=0

  local max_memory over_memory max_disk over_disk upload_size listen_port sftp_port daemon_base
  max_memory=$(ask "Max memory (MB)" "4096")
  over_memory=$(ask "Memory overallocation % (-1 for unlimited)" "0")
  max_disk=$(ask "Max disk (MB)" "20480")
  over_disk=$(ask "Disk overallocation % (-1 for unlimited)" "0")
  upload_size=$(ask "Max upload filesize (MB)" "100")
  listen_port=$(ask "Wings listening port" "8080")
  sftp_port=$(ask "Wings SFTP port" "2022")
  daemon_base=$(ask "Wings server data directory" "/var/lib/pterodactyl/volumes")

  php artisan p:node:make \
    --name="$name" \
    --description="$desc" \
    --fqdn="$fqdn" \
    --public="$public" \
    --scheme="$scheme" \
    --proxy="$proxy" \
    --maintenance="$maintenance" \
    --maxMemory="$max_memory" \
    --overallocateMemory="$over_memory" \
    --maxDisk="$max_disk" \
    --overallocateDisk="$over_disk" \
    --uploadSize="$upload_size" \
    --daemonListeningPort="$listen_port" \
    --daemonSFTPPort="$sftp_port" \
    --daemonBase="$daemon_base" \
    --no-interaction >>"$LOG_FILE" 2>&1

  if [[ $? -ne 0 ]]; then
    error "Node creation failed — check $LOG_FILE"
    pause_return
    return
  fi
  success "Node '${name}' created in the panel"

  echo
  info "Fetching node ID for configuration export..."
  local node_id
  node_id=$(php artisan p:node:list --format=json 2>/dev/null \
    | grep -o "\"name\":\"${name}\"[^}]*\"id\":[0-9]*" \
    | grep -o '"id":[0-9]*' | grep -o '[0-9]*' | tail -1)

  if [[ -z "$node_id" ]]; then
    warn "Could not auto-detect the new node's ID. Run 'php artisan p:node:list' to find it,"
    warn "then 'php artisan p:node:configuration <id>' to view its Wings config."
  else
    step "Wings configuration for node #${node_id}"
    php artisan p:node:configuration "$node_id" --format=yaml | tee "/tmp/monopanel-node-${node_id}.yaml"
    echo
    success "Saved a copy to /tmp/monopanel-node-${node_id}.yaml"
    say "Copy this file to ${C_BOLD}/etc/pterodactyl/config.yml${C_RESET} on the node running Wings,"
    say "then use option ${C_BOLD}4) Start the Nodes${C_RESET} on that machine (or install Wings"
    say "manually — see https://github.com/pterodactyl/wings)."
  fi

  pause_return
}

# ------------------------------------------------------------------------------
# 4) Start the Nodes (Wings)
# ------------------------------------------------------------------------------

install_wings_if_needed() {
  if check_cmd wings; then
    success "Wings binary already installed"
    return 0
  fi

  warn "Wings (the node daemon) is not installed on this machine."
  confirm "Install Wings now?" y || return 1

  step "Installing Docker (required by Wings)"
  if ! check_cmd docker; then
    curl -fsSL https://get.docker.com | sh >>"$LOG_FILE" 2>&1 \
      && success "Docker installed" \
      || { error "Docker install failed — check $LOG_FILE"; return 1; }
    systemctl enable --now docker >>"$LOG_FILE" 2>&1 || true
  else
    success "Docker already installed"
  fi

  step "Installing Wings binary"
  mkdir -p /etc/pterodactyl
  local arch
  arch=$(uname -m)
  [[ "$arch" == "x86_64" ]] && arch="amd64"
  [[ "$arch" == "aarch64" ]] && arch="arm64"

  curl -L -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${arch}" \
    >>"$LOG_FILE" 2>&1 \
    && chmod u+x /usr/local/bin/wings \
    && success "Wings binary installed to /usr/local/bin/wings" \
    || { error "Wings download failed — check $LOG_FILE"; return 1; }
}

start_nodes() {
  banner
  step "Start the Nodes (Wings)"
  say "This runs Wings, the daemon that actually powers game servers on this"
  say "machine. Run this on each node — it may be the same box as the panel"
  say "for small setups, or a separate machine for larger ones."
  echo

  require_root
  detect_service_mode

  install_wings_if_needed || { pause_return; return; }

  if [[ ! -f /etc/pterodactyl/config.yml ]]; then
    warn "No Wings config found at /etc/pterodactyl/config.yml."
    warn "Paste the config generated by 'Configure Nodes' there before starting."
    pause_return
    return
  fi

  case "$SERVICE_MODE" in
    systemd)
      cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
WorkingDirectory=/etc/pterodactyl
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload >>"$LOG_FILE" 2>&1
      systemctl enable --now wings >>"$LOG_FILE" 2>&1
      success "Wings started via systemd (service: wings.service)"
      ;;
    supervisor)
      mkdir -p /etc/supervisor/conf.d
      cat > /etc/supervisor/conf.d/wings.conf <<'EOF'
[program:wings]
command=/usr/local/bin/wings
directory=/etc/pterodactyl
autostart=true
autorestart=true
user=root
redirect_stderr=true
stdout_logfile=/var/log/wings.log
EOF
      supervisorctl reread >>"$LOG_FILE" 2>&1 || true
      supervisorctl update >>"$LOG_FILE" 2>&1 || true
      supervisorctl start wings:* >>"$LOG_FILE" 2>&1 || true
      success "Wings started via Supervisor (program: wings)"
      ;;
    manual)
      warn "No systemd or supervisor detected — running Wings in the foreground."
      warn "Use tmux/screen to keep it alive after you disconnect."
      (cd /etc/pterodactyl && wings)
      ;;
  esac
  pause_return
}

# ------------------------------------------------------------------------------
# 5) Connect Cloudflared
# ------------------------------------------------------------------------------

install_cloudflared_if_needed() {
  if check_cmd cloudflared; then
    success "cloudflared already installed"
    return 0
  fi

  step "Installing cloudflared"
  case "$OS_ID" in
    ubuntu|debian)
      mkdir -p --mode=0755 /usr/share/keyrings
      curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        -o /usr/share/keyrings/cloudflare-main.gpg >>"$LOG_FILE" 2>&1
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs 2>/dev/null || echo bookworm) main" \
        > /etc/apt/sources.list.d/cloudflared.list
      apt-get update -y >>"$LOG_FILE" 2>&1
      pkg_install cloudflared
      ;;
    almalinux|rocky|centos|rhel|fedora)
      curl -fsSL -o /etc/yum.repos.d/cloudflared.repo \
        https://pkg.cloudflare.com/cloudflared.repo >>"$LOG_FILE" 2>&1
      pkg_install cloudflared
      ;;
    *)
      local arch
      arch=$(uname -m)
      [[ "$arch" == "x86_64" ]] && arch="amd64"
      [[ "$arch" == "aarch64" ]] && arch="arm64"
      curl -L -o /usr/local/bin/cloudflared \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" \
        >>"$LOG_FILE" 2>&1
      chmod u+x /usr/local/bin/cloudflared
      ;;
  esac

  check_cmd cloudflared && success "cloudflared installed" || { error "cloudflared install failed — check $LOG_FILE"; return 1; }
}

connect_cloudflared() {
  banner
  step "Connect Cloudflared"
  say "This connects your panel to a Cloudflare Tunnel using a tunnel token"
  say "(from Zero Trust → Networks → Tunnels) and points it at your domain."
  echo

  require_root
  detect_service_mode
  detect_os
  install_cloudflared_if_needed || { pause_return; return; }

  local token domain local_port
  token=$(ask_secret "Cloudflare Tunnel token")
  domain=$(ask_required "Domain/hostname to route to this panel (e.g. panel.example.com)")
  local_port=$(ask "Local port the panel is running on" "8000")

  if [[ -z "$token" ]]; then
    error "No token provided — aborting."
    pause_return
    return
  fi

  case "$SERVICE_MODE" in
    systemd)
      cloudflared service install "$token" >>"$LOG_FILE" 2>&1
      systemctl enable --now cloudflared >>"$LOG_FILE" 2>&1
      success "cloudflared installed and started as a systemd service"
      ;;
    supervisor)
      mkdir -p /etc/supervisor/conf.d
      cat > /etc/supervisor/conf.d/cloudflared.conf <<EOF
[program:cloudflared]
command=/usr/local/bin/cloudflared tunnel run --token ${token}
autostart=true
autorestart=true
user=root
redirect_stderr=true
stdout_logfile=/var/log/cloudflared.log
EOF
      supervisorctl reread >>"$LOG_FILE" 2>&1 || true
      supervisorctl update >>"$LOG_FILE" 2>&1 || true
      supervisorctl start cloudflared:* >>"$LOG_FILE" 2>&1 || true
      success "cloudflared started via Supervisor"
      ;;
    manual)
      warn "No systemd or supervisor detected — running cloudflared in the foreground."
      (cloudflared tunnel run --token "$token")
      ;;
  esac

  echo
  success "Tunnel connected."
  say "In the Cloudflare Zero Trust dashboard, make sure a Public Hostname"
  say "route exists: ${C_BOLD}${domain}${C_RESET} → ${C_BOLD}http://localhost:${local_port}${C_RESET}"
  pause_return
}

# ------------------------------------------------------------------------------
# 6) Update Panel
# ------------------------------------------------------------------------------

update_panel() {
  require_installed || return
  banner
  step "Update Panel"
  say "Pulls the latest changes from ${REPO_BRANCH} on"
  say "${REPO_URL}, rebuilds, and re-runs migrations."
  echo
  confirm "Continue with update?" y || return

  require_root
  cd "$PANEL_DIR" || die "Cannot cd into $PANEL_DIR"

  step "Putting panel into maintenance mode"
  php artisan down >>"$LOG_FILE" 2>&1 || true

  step "Pulling latest changes from GitHub (${REPO_BRANCH})"
  git fetch origin "$REPO_BRANCH" >>"$LOG_FILE" 2>&1 || die "git fetch failed — check $LOG_FILE"
  local before after
  before=$(git rev-parse HEAD)
  git checkout "$REPO_BRANCH" >>"$LOG_FILE" 2>&1
  git reset --hard "origin/$REPO_BRANCH" >>"$LOG_FILE" 2>&1 || die "git reset failed — check $LOG_FILE"
  after=$(git rev-parse HEAD)

  if [[ "$before" == "$after" ]]; then
    info "Already up to date (${after:0:7})."
  else
    success "Updated ${before:0:7} → ${after:0:7}"
  fi

  build_backend
  run_migrations
  build_frontend
  set_permissions

  step "Clearing caches"
  php artisan config:clear >>"$LOG_FILE" 2>&1
  php artisan cache:clear >>"$LOG_FILE" 2>&1
  php artisan view:clear >>"$LOG_FILE" 2>&1
  success "Caches cleared"

  step "Bringing panel back up"
  php artisan up >>"$LOG_FILE" 2>&1
  success "Panel is back online"

  echo
  detect_service_mode
  case "$SERVICE_MODE" in
    systemd)
      systemctl restart monopanel-queue.service >>"$LOG_FILE" 2>&1 && success "Queue worker restarted"
      ;;
    supervisor)
      supervisorctl restart monopanel-queue:* >>"$LOG_FILE" 2>&1 && success "Queue worker restarted"
      ;;
    manual)
      warn "Remember to restart your manually-run queue worker."
      ;;
  esac

  pause_return
}

# ------------------------------------------------------------------------------
# Extra: Info / Status
# ------------------------------------------------------------------------------

show_info() {
  banner
  step "MonoPanel Status"
  if [[ -f "$STATE_FILE" ]]; then
    say "Executor state (${STATE_FILE}):"
    sed 's/^/    /' "$STATE_FILE"
  else
    warn "No installation recorded by this executor yet."
  fi
  echo
  if [[ -d "$PANEL_DIR/.git" ]]; then
    say "Current commit : $(cd "$PANEL_DIR" && git rev-parse --short HEAD 2>/dev/null)"
    say "Branch         : $(cd "$PANEL_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  fi
  detect_service_mode
  is_container && say "Environment    : container"
  echo
  command -v php >/dev/null && (cd "$PANEL_DIR" 2>/dev/null && php artisan p:info 2>/dev/null | sed 's/^/  /')
  pause_return
}

# ------------------------------------------------------------------------------
# Main menu
# ------------------------------------------------------------------------------

main_menu() {
  while true; do
    banner
    echo -e "  ${C_ORANGE}${C_BOLD}1${C_RESET}) Install Panel"
    echo -e "  ${C_ORANGE}${C_BOLD}2${C_RESET}) Run Panel              ${C_DIM}(Production / Development)${C_RESET}"
    echo -e "  ${C_ORANGE}${C_BOLD}3${C_RESET}) Configure Nodes"
    echo -e "  ${C_ORANGE}${C_BOLD}4${C_RESET}) Start the Nodes        ${C_DIM}(Wings daemon)${C_RESET}"
    echo -e "  ${C_ORANGE}${C_BOLD}5${C_RESET}) Connect Cloudflared    ${C_DIM}(tunnel + domain)${C_RESET}"
    echo -e "  ${C_ORANGE}${C_BOLD}6${C_RESET}) Update Panel           ${C_DIM}(git pull + rebuild)${C_RESET}"
    hr
    echo -e "  ${C_DIM}7) Status / Info    0) Exit${C_RESET}"
    echo
    local choice
    choice=$(ask "Select an option" "")
    case "$choice" in
      1) install_panel ;;
      2) run_panel_menu ;;
      3) configure_nodes ;;
      4) start_nodes ;;
      5) connect_cloudflared ;;
      6) update_panel ;;
      7) show_info ;;
      0) echo; success "Goodbye — thanks for using MonoPanel."; exit 0 ;;
      *) warn "Invalid option — please choose a number from the menu." ; sleep 1 ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
log "INFO" "===== MonoPanel executor started (v${SCRIPT_VERSION}) ====="

main_menu
