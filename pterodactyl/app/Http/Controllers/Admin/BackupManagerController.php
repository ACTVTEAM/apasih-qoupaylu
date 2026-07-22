<?php

namespace Pterodactyl\Http\Controllers\Admin;

use Carbon\CarbonImmutable;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Http;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Models\BackupManagerSetting;

class BackupManagerController extends Controller
{
    public function index()
    {
        $enabled = BackupManagerSetting::value('telegram_enabled', '0') === '1';
        $heartbeat = BackupManagerSetting::value('telegram_bot_heartbeat');

        $botStatus = 'offline';
        $botStatusText = 'Offline';

        if (!$enabled) {
            $botStatus = 'disabled';
            $botStatusText = 'Disabled';
        } elseif ($heartbeat) {
            try {
                $lastHeartbeat = CarbonImmutable::parse($heartbeat);

                if ($lastHeartbeat->greaterThan(now()->subSeconds(75))) {
                    $botStatus = 'online';
                    $botStatusText = 'Online';
                }
            } catch (\Throwable) {
                // Keep offline status.
            }
        }

        return view('backup-manager::admin.index', [
            'settings' => [
                'backup_enabled' => BackupManagerSetting::value('backup_enabled', '1'),
                'default_interval_minutes' => BackupManagerSetting::value('default_interval_minutes', '1440'),
                'default_retention' => BackupManagerSetting::value('default_retention', '3'),
                'min_interval_minutes' => BackupManagerSetting::value('min_interval_minutes', '60'),
                'max_retention' => BackupManagerSetting::value('max_retention', '10'),
                'telegram_enabled' => BackupManagerSetting::value('telegram_enabled', '0'),
                'telegram_bot_username' => BackupManagerSetting::value('telegram_bot_username', ''),
                'telegram_owner_id' => BackupManagerSetting::value('telegram_owner_id', ''),
                'auto_update_check' => BackupManagerSetting::value('auto_update_check', '1'),
            ],
            'hasToken' => (bool) BackupManagerSetting::encrypted('telegram_bot_token'),
            'botStatus' => $botStatus,
            'botStatusText' => $botStatusText,
            'botHeartbeat' => $heartbeat,
        ]);
    }

    public function update(Request $request)
    {
        $data = $request->validate([
            'backup_enabled' => 'nullable|boolean',
            'default_interval_minutes' => 'required|integer|min:15|max:43200',
            'default_retention' => 'required|integer|min:1|max:100',
            'min_interval_minutes' => 'required|integer|min:15|max:43200',
            'max_retention' => 'required|integer|min:1|max:100',
            'telegram_enabled' => 'required|boolean',
            'telegram_bot_username' => 'nullable|string|max:64',
            'telegram_bot_token' => 'nullable|string|max:255',
            'telegram_owner_id' => ['nullable', 'regex:/^[0-9]{5,20}$/'],
            'auto_update_check' => 'nullable|boolean',
        ]);

        foreach ([
            'backup_enabled',
            'default_interval_minutes',
            'default_retention',
            'min_interval_minutes',
            'max_retention',
            'telegram_enabled',
            'telegram_bot_username',
            'telegram_owner_id',
            'auto_update_check',
        ] as $key) {
            BackupManagerSetting::put($key, (string) ($data[$key] ?? '0'));
        }

        if (!empty($data['telegram_bot_token'])) {
            BackupManagerSetting::putEncrypted('telegram_bot_token', $data['telegram_bot_token']);
        }

        return back()->with('success', 'Backup Manager settings saved.');
    }

    public function testTelegram()
    {
        $token = BackupManagerSetting::encrypted('telegram_bot_token');

        if (!$token) {
            return back()->withErrors(['telegram' => 'Bot token is not configured.']);
        }

        try {
            $me = Http::timeout(15)
                ->get("https://api.telegram.org/bot{$token}/getMe")
                ->throw()
                ->json();

            return back()->with(
                'success',
                'Telegram connected as @'.($me['result']['username'] ?? 'unknown')
            );
        } catch (\Throwable $e) {
            return back()->withErrors(['telegram' => $e->getMessage()]);
        }
    }

    public function checkUpdate()
    {
        try {
            $release = Http::timeout(15)
                ->withHeaders(['Accept' => 'application/vnd.github+json'])
                ->get('https://api.github.com/repos/pterodactyl/panel/releases/latest')
                ->throw()
                ->json();

            return back()->with(
                'success',
                'Latest official Pterodactyl release: '.($release['tag_name'] ?? 'unknown').
                '. Run "php artisan p:upgrade" as root/shell user to perform the official upgrade.'
            );
        } catch (\Throwable $e) {
            return back()->withErrors(['update' => $e->getMessage()]);
        }
    }
}
