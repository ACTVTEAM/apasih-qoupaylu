#!/usr/bin/env bash
set -Eeuo pipefail

PANEL_DIR="${PANEL_DIR:-/var/www/pterodactyl}"
REPO_OWNER="${REPO_OWNER:-ACTVTEAM}"
REPO_NAME="${REPO_NAME:-apasih-qoupaylu}"
REPO_BRANCH="${REPO_BRANCH:-main}"
BACKUP_DIR="${BACKUP_DIR:-/root/ptero-backup-manager-backups}"
ZIP_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.zip"

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

ensure_frontend_tools(){
    if command -v node >/dev/null 2>&1 && command -v yarn >/dev/null 2>&1; then
        green "Node.js $(node -v) and Yarn $(yarn -v) detected."
        return
    fi

    yellow "Node.js/Yarn not found. Installing frontend build tools..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y ca-certificates curl gnupg

        # Official Pterodactyl build documentation currently uses Node.js 22.
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
        apt-get install -y nodejs
    elif command -v dnf >/dev/null 2>&1; then
        curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
        dnf install -y nodejs
    elif command -v yum >/dev/null 2>&1; then
        curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
        yum install -y nodejs
    else
        die "Unsupported package manager. Install Node.js 22 and Yarn manually."
    fi

    command -v npm >/dev/null 2>&1 || die "npm was not installed with Node.js."

    npm install -g yarn

    command -v node >/dev/null 2>&1 || die "Node.js installation failed."
    command -v yarn >/dev/null 2>&1 || die "Yarn installation failed."

    green "Installed Node.js $(node -v) and Yarn $(yarn -v)."
}

build_frontend(){
    cd "$PANEL_DIR"

    ensure_frontend_tools

    # Pterodactyl's documented requirement for Node.js 17+.
    export NODE_OPTIONS="${NODE_OPTIONS:---openssl-legacy-provider}"

    info "Installing frontend dependencies..."
    yarn install --frozen-lockfile || yarn install

    info "Building frontend..."
    if yarn run 2>/dev/null | grep -q 'build:production'; then
        yarn build:production
    else
        yarn build
    fi
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
    backup_panel
    download
    snapshot_core_files
    enter_maintenance

    install_files
    finish
    install_services

    leave_maintenance
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
    yellow "Repairing integration patches..."
    download
    snapshot_core_files
    enter_maintenance

    install_files
    finish
    install_services

    leave_maintenance
    PATCH_BACKUP_DIR=""
    cleanup_tmp
    TMP=""

    green "Repair completed."
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
    echo " PTERODACTYL BACKUP MANAGER v1.0.2"
    echo "============================================"
    echo "[1] Install"
    echo "[2] Update/Reinstall"
    echo "[3] Repair Installation"
    echo "[4] Status"
    echo "[5] Uninstall"
    echo "[x] Exit"
    read -rp "Choose: " c

    case "$c" in
        1) install ;;
        2) update ;;
        3) repair ;;
        4) status ;;
        5) uninstall ;;
        x|X) exit 0 ;;
        *) yellow "Invalid choice." ;;
    esac

    echo
    read -rp "Press Enter..." _
done