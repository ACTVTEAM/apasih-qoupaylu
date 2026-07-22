# Ptero Backup Manager

Target: Pterodactyl Panel 1.12.x.

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
