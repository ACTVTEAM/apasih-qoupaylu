# Ptero Backup Manager

Target: Pterodactyl Panel 1.12.x.

Installer v1.0.1 uses format-tolerant patching for config/app.php and routes.ts.

Features:
- Admin backup configuration.
- Per-server automatic backup setting.
- Telegram bot configuration.
- Telegram `/start` and `/verify CODE`.
- Telegram account binding from the user server page.
- Automatic backup using Pterodactyl's native `InitiateBackupService`.
- Completion/failure polling without modifying Wings.
- Retention cleanup.
- Manual "Backup Now".
- Module install/update/uninstall.
- Panel update checker; actual Panel upgrades use Pterodactyl's official `php artisan p:upgrade`.

## Repository layout

Upload this entire directory to a GitHub repository.

Then edit these variables in install.sh:

    REPO_OWNER="YOUR_GITHUB_USERNAME"
    REPO_NAME="ptero-backup-manager"

Run:

    bash <(curl -fsSL https://raw.githubusercontent.com/USER/ptero-backup-manager/main/install.sh)

## Telegram setup

1. Create a bot using @BotFather.
2. Admin -> Backup Manager.
3. Save bot token and bot username.
4. Start service:
   systemctl enable --now pterodactyl-backup-manager-bot
5. User opens Server -> Auto Backup.
6. Click "Generate verification code".
7. Open the Telegram bot, press Start, send:
   /verify CODE

## Cron

Installer adds:

    * * * * * www-data cd /var/www/pterodactyl && php artisan backup-manager:run >/dev/null 2>&1

This checks due backups and detects completion/failure.

## Important

The installer patches only:
- config/app.php (register provider)
- resources/views/layouts/admin.blade.php (admin menu)
- resources/scripts/routers/routes.ts (user Auto Backup route)

Backups are made before patching.

## v1.0.3 fix

Fixes the user Auto Backup page getting stuck on `Loading...`.

Cause:
- The first frontend used `state.server.data.uuid` (full server UUID).
- Pterodactyl's client UI/API uses the server identifier from `state.server.data.id`.
- The old component also had no request error handler, so a 4xx/5xx response looked like an infinite loading screen.

v1.0.3 now:
- Uses Pterodactyl's own `@/api/http` Axios instance.
- Uses `server.data.id`.
- Displays the real API error instead of loading forever.


## v1.0.4 - Installer self-update

New installer menu:

    [1] Install
    [2] Update/Reinstall Module
    [3] Update Installer Script
    [4] Check Installer Update
    [5] Repair Installation
    [6] Status
    [7] Uninstall

`Update Installer Script`:
- Reads the latest `version.txt` from GitHub.
- Downloads the latest `install.sh`.
- Verifies that it starts with a shebang.
- Runs `bash -n` before replacing anything.
- Keeps a `.bak` copy when replacing a persistent local installer.
- When started using `bash <(curl ...)`, saves the persistent copy to:
  `/root/ptero-backup-manager-install.sh`.
- Can immediately restart into the new installer.

## v1.0.5 - Node.js/Yarn + Wings safety

- Auto-repairs Node.js 22+ and Yarn before compiling the Panel frontend.
- Suppresses noisy package-manager output and shows only useful error details on a real failure.
- Runs a final Node.js/npm/Yarn health check.
- Records local Wings state before installation and verifies it after installation.
- Never edits Wings `config.yml`, Docker settings, or remote Node configuration.
- If local Wings was healthy before install but stops unexpectedly, the installer attempts a safe restart.
- Adds `Node.js / Yarn / Wings Health Check` to the installer menu.


## v1.0.6 - Fix Auto Backup API 500

Fixed the `ServerSubject` middleware namespace.

Incorrect:
`Pterodactyl\Http\Middleware\Api\Client\Server\ServerSubject`

Correct for Pterodactyl 1.12.x:
`Pterodactyl\Http\Middleware\Activity\ServerSubject`

The installer also validates that both the Admin and Client Backup Manager routes can be enumerated by Laravel after installation/repair.


## v1.0.7 - Fix false "Client API route is missing"

`php artisan route:list` prints route URIs without a leading `/`.

v1.0.6 incorrectly searched for:

    /api/client/servers/{server}/backup-manager

v1.0.7 correctly searches for:

    api/client/servers/{server}/backup-manager

The checker also verifies that all 5 client Backup Manager routes are present.


## v1.0.8 - Telegram control, status, owner ID

Admin Telegram configuration now includes:
- Bot ON / OFF.
- Status: Online / Offline / Disabled.
- Last heartbeat.
- Telegram Owner ID.

Owner-only Telegram commands:
- `/status`
- `/bot on`
- `/bot off`
- `/config`

Normal users can still use:
- `/start`
- `/verify CODE`

The bot process writes a heartbeat to the database. When the bot is OFF, the process remains alive but Telegram polling is paused, so Admin can distinguish Disabled from Offline.
