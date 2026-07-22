#!/usr/bin/env bash
set -Eeuo pipefail

PANEL_DIR="${PANEL_DIR:-/var/www/pterodactyl}"
REPO_OWNER="${REPO_OWNER:-ACTVTEAM}"
REPO_NAME="${REPO_NAME:-apasih-qoupaylu}"
REPO_BRANCH="${REPO_BRANCH:-main}"
BACKUP_DIR="${BACKUP_DIR:-/root/ptero-backup-manager-backups}"
ZIP_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.zip"

green(){ echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
red(){ echo -e "\033[31m$*\033[0m"; }
die(){ red "[ERROR] $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -f "$PANEL_DIR/artisan" ]] || die "Pterodactyl not found at $PANEL_DIR."

WEB_USER="www-data"; id www-data >/dev/null 2>&1 || WEB_USER="$(stat -c %U "$PANEL_DIR")"
WEB_GROUP="$WEB_USER"

backup_panel(){
 mkdir -p "$BACKUP_DIR"
 local f="$BACKUP_DIR/panel-$(date +%Y%m%d-%H%M%S).tar.gz"
 yellow "Backing up panel -> $f"
 tar --exclude="$PANEL_DIR/vendor" --exclude="$PANEL_DIR/node_modules" -czf "$f" -C "$(dirname "$PANEL_DIR")" "$(basename "$PANEL_DIR")"
}

download(){
 [[ "$REPO_OWNER" != "YOUR_GITHUB_USERNAME" ]] || die "Edit REPO_OWNER in install.sh first."
 TMP="$(mktemp -d)"
 curl -fL --retry 3 "$ZIP_URL" -o "$TMP/module.zip"
 unzip -q "$TMP/module.zip" -d "$TMP"
 SRC="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)"
}

patch_provider(){
 local f="$PANEL_DIR/config/app.php"
 grep -q 'BackupManagerServiceProvider::class' "$f" && return
 python3 - "$f" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read()
needle='Pterodactyl\\\\Providers\\\\ViewComposerServiceProvider::class,'
rep=needle+"\n        Pterodactyl\\\\Providers\\\\BackupManagerServiceProvider::class,"
if needle not in s: raise SystemExit("provider insertion point not found")
open(p,'w').write(s.replace(needle,rep,1))
PY
}

patch_admin_menu(){
 local f="$PANEL_DIR/resources/views/layouts/admin.blade.php"
 grep -q 'BACKUP-MANAGER-MENU' "$f" && return
 python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
needle='<li class="{{ Route::currentRouteName() !== \'admin.settings\' ?: \'active\' }}">'
# More stable fallback: insert before Application API menu by route text.
marker='{{-- BACKUP-MANAGER-MENU --}}\n<li class="{{ str_starts_with(Route::currentRouteName() ?? \'\', \'admin.backup-manager\') ? \'active\' : \'\' }}"><a href="{{ route(\'admin.backup-manager\') }}"><i class="fa fa-archive"></i> <span>Backup Manager</span></a></li>\n{{-- /BACKUP-MANAGER-MENU --}}\n'
target='<li class="{{ Route::currentRouteName() !== \'admin.api.index\' ?: \'active\' }}">'
if target in s: s=s.replace(target,marker+target,1)
else:
    pos=s.find('Application API')
    if pos<0: raise SystemExit("admin menu insertion point not found")
    line=s.rfind('<li',0,pos)
    s=s[:line]+marker+s[line:]
open(p,'w').write(s)
PY
}

patch_frontend_route(){
 local f="$PANEL_DIR/resources/scripts/routers/routes.ts"
 grep -q 'AutoBackupContainer' "$f" && return
 python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
imp="import AutoBackupContainer from '@/components/server/backup-manager/AutoBackupContainer';\n"
s=imp+s
needle="{ path: '/backups', permission: 'backup.*', name: 'Backups', component: BackupContainer, },"
entry=needle+"\n        { path: '/auto-backup', permission: 'backup.*', name: 'Auto Backup', component: AutoBackupContainer, },"
if needle not in s: raise SystemExit("route insertion point not found")
open(p,'w').write(s.replace(needle,entry,1))
PY
}

install_files(){
 cp -a "$SRC/pterodactyl/." "$PANEL_DIR/"
 cp "$SRC/manifest.txt" "$PANEL_DIR/.ptero-backup-manager-manifest"
 echo "$(cat "$SRC/version.txt")" > "$PANEL_DIR/.ptero-backup-manager-version"
 patch_provider
 patch_admin_menu
 patch_frontend_route
}

install_services(){
 sed -e "s|__PANEL_DIR__|$PANEL_DIR|g" -e "s|__WEB_USER__|$WEB_USER|g" -e "s|__WEB_GROUP__|$WEB_GROUP|g" \
 "$SRC/systemd/pterodactyl-backup-manager-bot.service" > /etc/systemd/system/pterodactyl-backup-manager-bot.service
 systemctl daemon-reload

 cat >/etc/cron.d/pterodactyl-backup-manager <<EOF
* * * * * $WEB_USER cd $PANEL_DIR && /usr/bin/php artisan backup-manager:run >/dev/null 2>&1
EOF
 chmod 644 /etc/cron.d/pterodactyl-backup-manager
}

finish(){
 cd "$PANEL_DIR"
 php artisan migrate --force
 php artisan optimize:clear || true
 php artisan queue:restart || true
 if command -v yarn >/dev/null; then yarn install --frozen-lockfile || yarn install; yarn build:production || yarn build; fi
 chown -R "$WEB_USER:$WEB_GROUP" storage bootstrap/cache
}

install(){
 backup_panel; download
 php "$PANEL_DIR/artisan" down || true
 trap 'php "$PANEL_DIR/artisan" up >/dev/null 2>&1 || true' EXIT
 install_files; finish; install_services
 php "$PANEL_DIR/artisan" up || true
 trap - EXIT
 green "Installed. Open Admin -> Backup Manager."
 yellow "After saving Telegram token run: systemctl enable --now pterodactyl-backup-manager-bot"
}

update(){ install; }

status(){
 echo "Module version: $(cat "$PANEL_DIR/.ptero-backup-manager-version" 2>/dev/null || echo not-installed)"
 systemctl --no-pager status pterodactyl-backup-manager-bot 2>/dev/null | head -12 || true
}

uninstall(){
 backup_panel
 yellow "Database tables are intentionally kept."
 rm -f /etc/cron.d/pterodactyl-backup-manager
 systemctl disable --now pterodactyl-backup-manager-bot >/dev/null 2>&1 || true
 rm -f /etc/systemd/system/pterodactyl-backup-manager-bot.service
 systemctl daemon-reload

 if [[ -f "$PANEL_DIR/.ptero-backup-manager-manifest" ]]; then
   while IFS= read -r x; do [[ -z "$x" || "$x" == \#* || "$x" == *..* ]] && continue; rm -f "$PANEL_DIR/$x"; done < "$PANEL_DIR/.ptero-backup-manager-manifest"
 fi

 python3 - "$PANEL_DIR/config/app.php" "$PANEL_DIR/resources/views/layouts/admin.blade.php" "$PANEL_DIR/resources/scripts/routers/routes.ts" <<'PY'
import sys,re
app,admin,routes=sys.argv[1:]
s=open(app).read(); s=re.sub(r'\s*Pterodactyl\\Providers\\BackupManagerServiceProvider::class,\n','\n',s); open(app,'w').write(s)
s=open(admin).read(); s=re.sub(r'\s*\{\{-- BACKUP-MANAGER-MENU --\}\}.*?\{\{-- /BACKUP-MANAGER-MENU --\}\}\s*','\n',s,flags=re.S); open(admin,'w').write(s)
s=open(routes).read()
s=s.replace("import AutoBackupContainer from '@/components/server/backup-manager/AutoBackupContainer';\n",'')
s=re.sub(r"\s*\{ path: '/auto-backup'.*?AutoBackupContainer, \},\n",'',s)
open(routes,'w').write(s)
PY
 cd "$PANEL_DIR"; php artisan optimize:clear || true
 rm -f "$PANEL_DIR/.ptero-backup-manager-manifest" "$PANEL_DIR/.ptero-backup-manager-version"
 green "Uninstalled. Database data was preserved."
}

while true; do
 clear
 echo "============================================"
 echo " PTERODACTYL BACKUP MANAGER"
 echo "============================================"
 echo "[1] Install"
 echo "[2] Update/Reinstall"
 echo "[3] Status"
 echo "[4] Uninstall"
 echo "[x] Exit"
 read -rp "Choose: " c
 case "$c" in
   1) install;;
   2) update;;
   3) status;;
   4) uninstall;;
   x|X) exit 0;;
 esac
 read -rp "Press Enter..." _
done
