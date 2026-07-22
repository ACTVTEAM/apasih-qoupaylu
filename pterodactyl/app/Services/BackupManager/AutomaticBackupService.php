<?php

namespace Pterodactyl\Services\BackupManager;

use Carbon\CarbonImmutable;
use Pterodactyl\Models\Backup;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\BackupManagerRun;
use Pterodactyl\Models\BackupManagerServerSetting;
use Pterodactyl\Models\BackupManagerTelegramAccount;
use Pterodactyl\Models\BackupManagerSetting;
use Pterodactyl\Services\Backups\InitiateBackupService;
use Pterodactyl\Services\Backups\DeleteBackupService;

class AutomaticBackupService
{
    public function __construct(
        private InitiateBackupService $initiate,
        private DeleteBackupService $delete,
        private TelegramService $telegram,
    ) {}

    public function start(Server $server, int $userId): BackupManagerRun
    {
        $backup = $this->initiate->handle(
            $server,
            'Auto Backup ' . CarbonImmutable::now()->format('Y-m-d H:i:s'),
            true
        );

        $run = BackupManagerRun::query()->create([
            'server_id'=>$server->id,
            'user_id'=>$userId,
            'backup_uuid'=>$backup->uuid,
            'status'=>'running',
            'started_at'=>now(),
        ]);

        $this->notify($userId, "🔄 <b>Backup started</b>\nServer: ".e($server->name));
        return $run;
    }

    public function processDue(): void
    {
        if (BackupManagerSetting::value('backup_enabled', '1') !== '1') return;

        BackupManagerServerSetting::query()
            ->where('enabled', true)
            ->where(fn($q) => $q->whereNull('next_backup_at')->orWhere('next_backup_at','<=',now()))
            ->with('server')
            ->chunkById(25, function ($rows) {
                foreach ($rows as $setting) {
                    $server = $setting->server;
                    if (!$server) continue;

                    try {
                        $this->start($server, $server->owner_id);
                        $setting->last_backup_at = now();
                        $setting->next_backup_at = now()->addMinutes($setting->interval_minutes);
                        $setting->save();
                    } catch (\Throwable $e) {
                        report($e);
                        $setting->next_backup_at = now()->addMinutes(max(15, $setting->interval_minutes));
                        $setting->save();
                        $this->notify($server->owner_id,
                            "❌ <b>Backup failed to start</b>\nServer: ".e($server->name)."\n".e($e->getMessage())
                        );
                    }
                }
            });
    }

    public function processRunning(): void
    {
        BackupManagerRun::query()->where('status','running')->chunkById(50, function ($runs) {
            foreach ($runs as $run) {
                $backup = Backup::query()->where('uuid',$run->backup_uuid)->first();
                if (!$backup || !$backup->completed_at) continue;

                $run->status = $backup->is_successful ? 'success' : 'failed';
                $run->completed_at = $backup->completed_at;
                $run->save();

                $server = Server::query()->find($run->server_id);
                if (!$server) continue;

                if ($backup->is_successful) {
                    $size = $backup->bytes ? round($backup->bytes / 1024 / 1024, 2).' MiB' : 'unknown';
                    $this->notify($run->user_id,
                        "✅ <b>Backup completed</b>\nServer: ".e($server->name)."\nSize: {$size}"
                    );
                    $this->prune($server);
                } else {
                    $this->notify($run->user_id,
                        "❌ <b>Backup failed</b>\nServer: ".e($server->name)
                    );
                }

                $run->notified_at = now();
                $run->save();
            }
        });
    }

    private function prune(Server $server): void
    {
        $setting = BackupManagerServerSetting::query()->where('server_id',$server->id)->first();
        if (!$setting) return;

        $keep = max(1, (int) $setting->retention);
        $old = $server->backups()
            ->where('is_successful', true)
            ->where('is_locked', false)
            ->orderByDesc('created_at')
            ->get()
            ->slice($keep);

        foreach ($old as $backup) {
            try { $this->delete->handle($backup); } catch (\Throwable $e) { report($e); }
        }
    }

    private function notify(int $userId, string $message): void
    {
        if (!$this->telegram->enabled()) return;
        $account = BackupManagerTelegramAccount::query()->where('user_id',$userId)->first();
        if ($account) {
            try { $this->telegram->send($account->telegram_user_id, $message); }
            catch (\Throwable $e) { report($e); }
        }
    }
}
