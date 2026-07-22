#!/usr/bin/env bash
set -Eeuo pipefail

PANEL_DIR="${PANEL_DIR:-/var/www/pterodactyl}"
REPO_OWNER="${REPO_OWNER:-ACTVTEAM}"
REPO_NAME="${REPO_NAME:-apasih-qoupaylu}"
REPO_BRANCH="${REPO_BRANCH:-main}"
BACKUP_DIR="${BACKUP_DIR:-/root/ptero-backup-manager-backups}"
ZIP_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.zip"
RAW_BASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
REMOTE_INSTALL_URL="${RAW_BASE_URL}/install.sh"
REMOTE_VERSION_URL="${RAW_BASE_URL}/version.txt"
SELF_INSTALL_PATH="${SELF_INSTALL_PATH:-/root/ptero-backup-manager-install.sh}"
NODE_REQUIRED_MAJOR="${NODE_REQUIRED_MAJOR:-22}"
YARN_REQUIRED_VERSION="${YARN_REQUIRED_VERSION:-1.22.22}"
BUILD_LOG="${BUILD_LOG:-/tmp/ptero-backup-manager-build.log}"
WINGS_WAS_ACTIVE="unknown"

TMP=""
SRC=""
PATCH_BACKUP_DIR=""
MAINTENANCE_ENTERED=0

green(){ echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
red(){ echo -e "\033[31m$*\033[0m"; }
info(){ echo -e "\033[36m$*\033[0m"; }
die(){ red "[ERROR] $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -f "$PANEL_DIR/artisan" ]] || die "Pterodactyl not found at $PANEL_DIR."
command -v python3 >/dev/null 2>&1 || die "python3 is required."
command -v curl >/dev/null 2>&1 || die "curl is required."
command -v unzip >/dev/null 2>&1 || die "unzip is required."

WEB_USER="www-data"
if ! id www-data >/dev/null 2>&1; then
    WEB_USER="$(stat -c %U "$PANEL_DIR")"
fi
WEB_GROUP="$(id -gn "$WEB_USER" 2>/dev/null || echo "$WEB_USER")"

cleanup_tmp(){
    [[ -n "${TMP:-}" && -d "${TMP:-}" ]] && rm -rf "$TMP" || true
}

leave_maintenance(){
    if [[ "$MAINTENANCE_ENTERED" -eq 1 ]]; then
        cd "$PANEL_DIR" || true
        php artisan up >/dev/null 2>&1 || true
        MAINTENANCE_ENTERED=0
    fi
}

restore_core_files(){
    [[ -n "${PATCH_BACKUP_DIR:-}" && -d "${PATCH_BACKUP_DIR:-}" ]] || return 0

    yellow "Restoring core files changed during this attempt..."
    [[ -f "$PATCH_BACKUP_DIR/config-app.php" ]] && cp -f "$PATCH_BACKUP_DIR/config-app.php" "$PANEL_DIR/config/app.php"
    [[ -f "$PATCH_BACKUP_DIR/admin-layout.blade.php" ]] && cp -f "$PATCH_BACKUP_DIR/admin-layout.blade.php" "$PANEL_DIR/resources/views/layouts/admin.blade.php"
    [[ -f "$PATCH_BACKUP_DIR/routes.ts" ]] && cp -f "$PATCH_BACKUP_DIR/routes.ts" "$PANEL_DIR/resources/scripts/routers/routes.ts"
}

on_error(){
    local line="${1:-unknown}"
    red "[ERROR] Installation failed near line ${line}."
    restore_core_files || true
    leave_maintenance || true
    cleanup_tmp || true
    yellow "Panel has been taken out of maintenance mode."
    yellow "Your full pre-install backup is still available in: $BACKUP_DIR"
}
trap 'on_error "$LINENO"' ERR
trap 'leave_maintenance; cleanup_tmp' EXIT

capture_wings_state(){
    WINGS_WAS_ACTIVE="not-installed"

    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^wings\.service'; then
        if systemctl is-active --quiet wings; then
            WINGS_WAS_ACTIVE="active"
            green "Wings service: active"
        else
            WINGS_WAS_ACTIVE="inactive"
            yellow "Wings service is currently inactive before installation."
        fi
    fi
}

check_wings_health(){
    echo
    info "Checking Pterodactyl Node/Wings health..."

    if ! command -v systemctl >/dev/null 2>&1; then
        yellow "systemctl unavailable; local Wings check skipped."
        return 0
    fi

    if ! systemctl list-unit-files --type=service 2>/dev/null | grep -q '^wings\.service'; then
        yellow "Wings is not installed on this Panel machine; remote Nodes are not modified."
        return 0
    fi

    if systemctl is-active --quiet wings; then
        green "Wings service: ACTIVE"
        return 0
    fi

    if [[ "$WINGS_WAS_ACTIVE" == "active" ]]; then
        yellow "Wings was active before installation but is now inactive."
        yellow "Attempting safe Wings restart..."
        systemctl restart wings
        sleep 2

        if systemctl is-active --quiet wings; then
            green "Wings recovered successfully: ACTIVE"
            return 0
        fi

        red "Wings could not be recovered automatically."
        systemctl --no-pager --full status wings 2>/dev/null | tail -n 25 || true
        return 1
    fi

    yellow "Wings was already inactive before installation; it will not be force-started."
    return 0
}

node_major(){
    if ! command -v node >/dev/null 2>&1; then
        echo "0"
        return
    fi
    node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo "0"
}

node_health_check(){
    local major
    major="$(node_major)"

    echo
    info "Checking frontend build tools..."

    if ! command -v node >/dev/null 2>&1; then
        yellow "Node.js: not installed"
        return 1
    fi

    if (( major < NODE_REQUIRED_MAJOR )); then
        yellow "Node.js: $(node -v) (requires v${NODE_REQUIRED_MAJOR}+)"
        return 1
    fi
    green "Node.js: $(node -v)"

    if ! command -v npm >/dev/null 2>&1; then
        yellow "npm: missing"
        return 1
    fi
    green "npm: $(npm -v)"

    if ! command -v yarn >/dev/null 2>&1; then
        yellow "Yarn: missing"
        return 1
    fi
    green "Yarn: $(yarn -v)"
    return 0
}

local_version(){
    if [[ -f "$PANEL_DIR/.ptero-backup-manager-version" ]]; then
        tr -d '\r\n ' < "$PANEL_DIR/.ptero-backup-manager-version"
    elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/version.txt" ]]; then
        tr -d '\r\n ' < "$(dirname "${BASH_SOURCE[0]}")/version.txt"
    else
        # Installer package version.
        echo "1.0.5"
    fi
}

remote_version(){
    [[ "$REPO_OWNER" != "YOUR_GITHUB_USERNAME" ]] || {
        echo ""
        return 0
    }

    curl -fsSL --connect-timeout 10 "$REMOTE_VERSION_URL" 2>/dev/null \
        | tr -d '\r\n ' || true
}

version_gt(){
    # Returns success when $1 > $2 using version-sort.
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

check_script_update(){
    [[ "$REPO_OWNER" != "YOUR_GITHUB_USERNAME" ]] || die "Edit REPO_OWNER in install.sh first."

    local current latest
    current="$(local_version)"
    latest="$(remote_version)"

    echo "Current installer/package : ${current}"
    echo "Latest GitHub version     : ${latest:-unknown}"

    if [[ -z "$latest" ]]; then
        red "Could not read version.txt from GitHub."
        return 1
    fi

    if [[ "$current" == "$latest" ]]; then
        green "Installer is already up to date."
        return 0
    fi

    if version_gt "$latest" "$current"; then
        yellow "New installer version is available: $current -> $latest"
    else
        yellow "GitHub version differs from local version: $current -> $latest"
    fi
}

update_installer_script(){
    [[ "$REPO_OWNER" != "YOUR_GITHUB_USERNAME" ]] || die "Edit REPO_OWNER in install.sh first."

    local current latest temp_script target running_script
    current="$(local_version)"
    latest="$(remote_version)"

    [[ -n "$latest" ]] || die "Could not retrieve remote version.txt."

    echo "Current : $current"
    echo "Latest  : $latest"

    if [[ "$current" == "$latest" ]]; then
        green "Installer script is already the latest version."
        return 0
    fi

    temp_script="$(mktemp /tmp/ptero-backup-manager-install.XXXXXX.sh)"

    info "Downloading latest install.sh..."
    curl -fL --retry 3 --connect-timeout 15 "$REMOTE_INSTALL_URL" -o "$temp_script"

    # Reject HTML/error pages that curl may receive from a misconfigured repository.
    if ! head -n1 "$temp_script" | grep -q '^#!/'; then
        rm -f "$temp_script"
        die "Downloaded file does not look like a shell script."
    fi

    info "Validating Bash syntax..."
    if ! bash -n "$temp_script"; then
        rm -f "$temp_script"
        die "Latest install.sh failed Bash syntax validation. Existing installer was not changed."
    fi

    running_script="${BASH_SOURCE[0]}"

    # A script executed using bash <(curl ...) usually lives under /dev/fd/*.
    # Such a file cannot be updated permanently, so use a stable root path.
    if [[ "$running_script" == /dev/fd/* || "$running_script" == /proc/* || ! -f "$running_script" ]]; then
        target="$SELF_INSTALL_PATH"
        yellow "Installer is running from process substitution."
        yellow "Saving the persistent updated installer to: $target"
    else
        target="$(readlink -f "$running_script")"
    fi

    mkdir -p "$(dirname "$target")"

    if [[ -f "$target" ]]; then
        cp -f "$target" "${target}.bak" || true
    fi

    install -m 0755 "$temp_script" "$target"
    rm -f "$temp_script"

    green "Installer script updated successfully."
    echo "Saved to : $target"
    echo "Version  : $latest"

    echo
    read -rp "Start the updated installer now? [Y/n]: " answer
    case "${answer:-Y}" in
        n|N)
            yellow "Run it later with:"
            echo "  bash $target"
            ;;
        *)
            green "Starting updated installer..."
            exec bash "$target"
            ;;
    esac
}

backup_panel(){
    mkdir -p "$BACKUP_DIR"
    local f="$BACKUP_DIR/panel-$(date +%Y%m%d-%H%M%S).tar.gz"
    yellow "Backing up panel -> $f"
    tar \
        --exclude="$PANEL_DIR/vendor" \
        --exclude="$PANEL_DIR/node_modules" \
        --exclude="$PANEL_DIR/storage/logs/*" \
        -czf "$f" \
        -C "$(dirname "$PANEL_DIR")" \
        "$(basename "$PANEL_DIR")"
    green "Panel backup completed."
}

download(){
    [[ "$REPO_OWNER" != "YOUR_GITHUB_USERNAME" ]] || die "Edit REPO_OWNER in install.sh first."

    TMP="$(mktemp -d /tmp/ptero-backup-manager.XXXXXX)"
    info "Downloading module..."
    curl -fL --retry 3 --connect-timeout 15 "$ZIP_URL" -o "$TMP/module.zip"
    unzip -q "$TMP/module.zip" -d "$TMP"

    SRC="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [[ -n "$SRC" && -d "$SRC/pterodactyl" ]] || die "Invalid repository layout: pterodactyl/ directory not found."
}

snapshot_core_files(){
    PATCH_BACKUP_DIR="$TMP/core-originals"
    mkdir -p "$PATCH_BACKUP_DIR"

    cp "$PANEL_DIR/config/app.php" "$PATCH_BACKUP_DIR/config-app.php"
    cp "$PANEL_DIR/resources/views/layouts/admin.blade.php" "$PATCH_BACKUP_DIR/admin-layout.blade.php"
    cp "$PANEL_DIR/resources/scripts/routers/routes.ts" "$PATCH_BACKUP_DIR/routes.ts"
}

enter_maintenance(){
    cd "$PANEL_DIR"
    php artisan down || true
    MAINTENANCE_ENTERED=1
}

patch_provider(){
    local f="$PANEL_DIR/config/app.php"
    grep -q 'BackupManagerServiceProvider::class' "$f" && {
        green "Service provider already registered."
        return
    }

    info "Registering BackupManagerServiceProvider..."

    python3 - "$f" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fp:
    source = fp.read()

provider = r"Pterodactyl\Providers\BackupManagerServiceProvider::class,"

if provider in source:
    raise SystemExit(0)

# Preferred: insert after the last Pterodactyl application provider.
matches = list(re.finditer(
    r"(?m)^(?P<indent>[ \t]*)Pterodactyl\\Providers\\[A-Za-z0-9_]+ServiceProvider::class,\s*$",
    source,
))

if matches:
    m = matches[-1]
    indent = m.group("indent")
    source = source[:m.end()] + "\n" + indent + provider + source[m.end():]
else:
    # Generic fallback: append inside the top-level 'providers' array.
    block = re.search(
        r"(?P<head>['\"]providers['\"]\s*=>\s*\[)(?P<body>.*?)(?P<tail>\n[ \t]*\],)",
        source,
        re.S,
    )
    if not block:
        raise SystemExit(
            "Could not locate the providers array in config/app.php. "
            "No files were intentionally overwritten."
        )

    body = block.group("body")
    indent_match = re.search(r"\n(?P<indent>[ \t]+)[A-Za-z_\\]+ServiceProvider::class,", body)
    indent = indent_match.group("indent") if indent_match else "        "
    new_body = body.rstrip() + "\n" + indent + provider + "\n"
    source = source[:block.start("body")] + new_body + source[block.end("body"):]

with open(path, "w", encoding="utf-8") as fp:
    fp.write(source)
PY

    grep -q 'Pterodactyl\\Providers\\BackupManagerServiceProvider::class' "$f" \
        || die "Provider patch verification failed."

    green "Service provider registered."
}

patch_admin_menu(){
    local f="$PANEL_DIR/resources/views/layouts/admin.blade.php"

    grep -q 'BACKUP-MANAGER-MENU' "$f" && {
        green "Admin menu already patched."
        return
    }

    info "Adding Backup Manager to admin menu..."

    python3 - "$f" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fp:
    source = fp.read()

marker = """{{-- BACKUP-MANAGER-MENU --}}
<li class="{{ str_starts_with(Route::currentRouteName() ?? '', 'admin.backup-manager') ? 'active' : '' }}">
    <a href="{{ route('admin.backup-manager') }}">
        <i class="fa fa-archive"></i> <span>Backup Manager</span>
    </a>
</li>
{{-- /BACKUP-MANAGER-MENU --}}
"""

if "BACKUP-MANAGER-MENU" in source:
    raise SystemExit(0)

# Preferred anchor: the Application API menu list item.
app_api = re.search(
    r"(?P<li><li\b[^>]*>.*?Application API.*?</li>)",
    source,
    re.S | re.I,
)
if app_api:
    source = source[:app_api.start()] + marker + source[app_api.start():]
else:
    # Fallback: insert before the MANAGEMENT header.
    management = re.search(
        r"(?P<header><li\b[^>]*class=[\"'][^\"']*header[^\"']*[\"'][^>]*>\s*MANAGEMENT\s*</li>)",
        source,
        re.S | re.I,
    )
    if not management:
        raise SystemExit(
            "Could not find a safe admin-menu insertion point."
        )
    source = source[:management.start()] + marker + source[management.start():]

with open(path, "w", encoding="utf-8") as fp:
    fp.write(source)
PY

    grep -q 'BACKUP-MANAGER-MENU' "$f" || die "Admin menu patch verification failed."
    green "Admin menu patched."
}

patch_frontend_route(){
    local f="$PANEL_DIR/resources/scripts/routers/routes.ts"

    grep -q "path: '/auto-backup'" "$f" && {
        green "Frontend Auto Backup route already exists."
        return
    }

    info "Adding user Auto Backup route..."

    python3 - "$f" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fp:
    source = fp.read()

import_line = "import AutoBackupContainer from '@/components/server/backup-manager/AutoBackupContainer';\n"

if "AutoBackupContainer from '@/components/server/backup-manager/AutoBackupContainer'" not in source:
    # Put import after the built-in BackupContainer import when possible.
    imp = re.search(
        r"(?m)^import\s+BackupContainer\s+from\s+['\"]@/components/server/backups/BackupContainer['\"];\s*$",
        source,
    )
    if imp:
        source = source[:imp.end()] + "\n" + import_line.rstrip("\n") + source[imp.end():]
    else:
        source = import_line + source

route = """        {
            path: '/auto-backup',
            permission: 'backup.*',
            name: 'Auto Backup',
            component: AutoBackupContainer,
        },
"""

# Match the complete object containing path '/backups', regardless of formatting.
backup_route = re.search(
    r"(?P<indent>[ \t]*)\{\s*"
    r"path:\s*['\"]/backups['\"]\s*,"
    r".*?"
    r"component:\s*BackupContainer\s*,?\s*"
    r"\},",
    source,
    re.S,
)

if not backup_route:
    raise SystemExit(
        "Could not locate the built-in /backups route in resources/scripts/routers/routes.ts."
    )

source = source[:backup_route.end()] + "\n" + route.rstrip("\n") + source[backup_route.end():]

with open(path, "w", encoding="utf-8") as fp:
    fp.write(source)
PY

    grep -q "path: '/auto-backup'" "$f" || die "Frontend route patch verification failed."
    green "Frontend route patched."
}

install_files(){
    info "Copying module files..."
    cp -a "$SRC/pterodactyl/." "$PANEL_DIR/"
    cp "$SRC/manifest.txt" "$PANEL_DIR/.ptero-backup-manager-manifest"
    echo "$(cat "$SRC/version.txt")" > "$PANEL_DIR/.ptero-backup-manager-version"

    patch_provider
    patch_admin_menu
    patch_frontend_route
}

install_services(){
    info "Installing Telegram bot systemd service..."

    sed \
        -e "s|__PANEL_DIR__|$PANEL_DIR|g" \
        -e "s|__WEB_USER__|$WEB_USER|g" \
        -e "s|__WEB_GROUP__|$WEB_GROUP|g" \
        "$SRC/systemd/pterodactyl-backup-manager-bot.service" \
        > /etc/systemd/system/pterodactyl-backup-manager-bot.service

    systemctl daemon-reload

    cat >/etc/cron.d/pterodactyl-backup-manager <<EOF
* * * * * $WEB_USER cd $PANEL_DIR && /usr/bin/php artisan backup-manager:run >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/pterodactyl-backup-manager

    green "Cron and Telegram service installed."
}

install_nodejs_22(){
    yellow "Installing/upgrading Node.js build tools..."

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl gnupg >/dev/null
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
        apt-get install -y -qq nodejs >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
        dnf install -y -q nodejs >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
        yum install -y -q nodejs >/dev/null
    else
        die "Unsupported package manager. Install Node.js 22 manually."
    fi

    command -v node >/dev/null 2>&1 || die "Node.js installation failed."
    command -v npm >/dev/null 2>&1 || die "npm is missing after Node.js installation."

    local major
    major="$(node_major)"
    (( major >= NODE_REQUIRED_MAJOR )) || die "Installed Node.js $(node -v) is too old."

    green "Node.js ready: $(node -v)"
}

ensure_yarn(){
    if command -v yarn >/dev/null 2>&1; then
        green "Yarn ready: $(yarn -v)"
        return 0
    fi

    yellow "Installing Yarn ${YARN_REQUIRED_VERSION}..."
    : > "$BUILD_LOG"

    if ! npm install -g "yarn@${YARN_REQUIRED_VERSION}" --force >"$BUILD_LOG" 2>&1; then
        red "Yarn installation failed."
        tail -n 30 "$BUILD_LOG" || true
        return 1
    fi

    command -v yarn >/dev/null 2>&1 || die "Yarn is not available after installation."
    green "Yarn ready: $(yarn -v)"
}

ensure_frontend_tools(){
    local major
    major="$(node_major)"

    if (( major < NODE_REQUIRED_MAJOR )); then
        install_nodejs_22
    else
        green "Node.js ready: $(node -v)"
    fi

    command -v npm >/dev/null 2>&1 || die "npm is missing."
    ensure_yarn
    node_health_check || die "Frontend build tool health check failed."
}

build_frontend(){
    cd "$PANEL_DIR"

    ensure_frontend_tools
    export NODE_OPTIONS="${NODE_OPTIONS:---openssl-legacy-provider}"

    : > "$BUILD_LOG"

    info "Installing frontend dependencies..."
    if ! yarn install --frozen-lockfile >"$BUILD_LOG" 2>&1; then
        yellow "Frozen lockfile install failed; retrying standard yarn install..."
        if ! yarn install >>"$BUILD_LOG" 2>&1; then
            red "Frontend dependency installation failed."
            tail -n 40 "$BUILD_LOG" || true
            return 1
        fi
    fi

    info "Building frontend assets..."
    if yarn run 2>/dev/null | grep -q 'build:production'; then
        if ! yarn build:production >>"$BUILD_LOG" 2>&1; then
            red "Frontend production build failed."
            tail -n 50 "$BUILD_LOG" || true
            return 1
        fi
    else
        if ! yarn build >>"$BUILD_LOG" 2>&1; then
            red "Frontend build failed."
            tail -n 50 "$BUILD_LOG" || true
            return 1
        fi
    fi

    unset NODE_OPTIONS || true
    green "Frontend build: SUCCESS"
    green "Node.js: $(node -v) | Yarn: $(yarn -v)"
}

finish(){
    cd "$PANEL_DIR"

    info "Running database migrations..."
    php artisan migrate --force

    info "Clearing Laravel caches..."
    php artisan optimize:clear || true
    php artisan view:clear || true
    php artisan queue:restart || true

    build_frontend

    chown -R "$WEB_USER:$WEB_GROUP" "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" || true
}

install(){
    capture_wings_state
    backup_panel
    download
    snapshot_core_files
    enter_maintenance

    install_files
    finish
    install_services

    leave_maintenance
    check_wings_health
    PATCH_BACKUP_DIR=""
    cleanup_tmp
    TMP=""

    green "Backup Manager installed successfully."
    yellow "Open Admin -> Backup Manager."
    yellow "After saving the Telegram token run:"
    echo "  systemctl enable --now pterodactyl-backup-manager-bot"
}

update(){
    install
}

status(){
    echo "Module version: $(cat "$PANEL_DIR/.ptero-backup-manager-version" 2>/dev/null || echo not-installed)"
    echo
    echo "Provider:"
    grep -n 'BackupManagerServiceProvider' "$PANEL_DIR/config/app.php" || true
    echo
    echo "Frontend route:"
    grep -n "auto-backup" "$PANEL_DIR/resources/scripts/routers/routes.ts" || true
    echo
    systemctl --no-pager status pterodactyl-backup-manager-bot 2>/dev/null | head -12 || true
}

repair(){
    capture_wings_state
    yellow "Repairing integration patches..."
    download
    snapshot_core_files
    enter_maintenance

    install_files
    finish
    install_services

    leave_maintenance
    check_wings_health
    PATCH_BACKUP_DIR=""
    cleanup_tmp
    TMP=""

    green "Repair completed."
}

full_health_check(){
    capture_wings_state

    echo "============================================"
    echo " NODE.JS / YARN / WINGS HEALTH CHECK"
    echo "============================================"

    if node_health_check; then
        green "Frontend build tools are healthy."
    else
        yellow "Frontend tools need repair."
        read -rp "Repair Node.js/Yarn now? [Y/n]: " answer
        case "${answer:-Y}" in
            n|N) ;;
            *) ensure_frontend_tools ;;
        esac
    fi

    check_wings_health
    echo
    green "Health check finished."
}

uninstall(){
    backup_panel
    yellow "Database tables are intentionally kept."

    rm -f /etc/cron.d/pterodactyl-backup-manager
    systemctl disable --now pterodactyl-backup-manager-bot >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/pterodactyl-backup-manager-bot.service
    systemctl daemon-reload

    if [[ -f "$PANEL_DIR/.ptero-backup-manager-manifest" ]]; then
        while IFS= read -r x; do
            [[ -z "$x" || "$x" == \#* || "$x" == *..* || "$x" == /* ]] && continue
            rm -f "$PANEL_DIR/$x"
        done < "$PANEL_DIR/.ptero-backup-manager-manifest"
    fi

    python3 - \
        "$PANEL_DIR/config/app.php" \
        "$PANEL_DIR/resources/views/layouts/admin.blade.php" \
        "$PANEL_DIR/resources/scripts/routers/routes.ts" <<'PY'
import re
import sys

app, admin, routes = sys.argv[1:]

s = open(app, encoding="utf-8").read()
s = re.sub(
    r"(?m)^[ \t]*Pterodactyl\\Providers\\BackupManagerServiceProvider::class,\s*\n?",
    "",
    s,
)
open(app, "w", encoding="utf-8").write(s)

s = open(admin, encoding="utf-8").read()
s = re.sub(
    r"\s*\{\{-- BACKUP-MANAGER-MENU --\}\}.*?\{\{-- /BACKUP-MANAGER-MENU --\}\}\s*",
    "\n",
    s,
    flags=re.S,
)
open(admin, "w", encoding="utf-8").write(s)

s = open(routes, encoding="utf-8").read()
s = re.sub(
    r"(?m)^import AutoBackupContainer from ['\"]@/components/server/backup-manager/AutoBackupContainer['\"];\s*\n?",
    "",
    s,
)
s = re.sub(
    r"\s*\{\s*path:\s*['\"]/auto-backup['\"].*?component:\s*AutoBackupContainer\s*,?\s*\},",
    "",
    s,
    flags=re.S,
)
open(routes, "w", encoding="utf-8").write(s)
PY

    cd "$PANEL_DIR"
    php artisan optimize:clear || true

    rm -f \
        "$PANEL_DIR/.ptero-backup-manager-manifest" \
        "$PANEL_DIR/.ptero-backup-manager-version"

    green "Uninstalled. Database data was preserved."
}

while true; do
    clear
    echo "============================================"
    echo " PTERODACTYL BACKUP MANAGER v1.0.5"
    echo "============================================"
    echo "[1] Install"
    echo "[2] Update/Reinstall Module"
    echo "[3] Update Installer Script"
    echo "[4] Check Installer Update"
    echo "[5] Repair Installation"
    echo "[6] Status"
    echo "[7] Node.js / Yarn / Wings Health Check"
    echo "[8] Uninstall"
    echo "[x] Exit"
    read -rp "Choose: " c

    case "$c" in
        1) install ;;
        2) update ;;
        3) update_installer_script ;;
        4) check_script_update ;;
        5) repair ;;
        6) status ;;
        7) full_health_check ;;
        8) uninstall ;;
        x|X) exit 0 ;;
        *) yellow "Invalid choice." ;;
    esac

    echo
    read -rp "Press Enter..." _
done