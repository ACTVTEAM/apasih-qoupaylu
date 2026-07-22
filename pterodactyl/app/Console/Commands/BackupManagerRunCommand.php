<?php

namespace Pterodactyl\Console\Commands;

use Illuminate\Console\Command;
use Pterodactyl\Services\BackupManager\AutomaticBackupService;

class BackupManagerRunCommand extends Command
{
    protected $signature = 'backup-manager:run';
    protected $description = 'Process automatic backups and backup completion notifications.';

    public function handle(AutomaticBackupService $service): int
    {
        $service->processRunning();
        $service->processDue();
        return self::SUCCESS;
    }
}
