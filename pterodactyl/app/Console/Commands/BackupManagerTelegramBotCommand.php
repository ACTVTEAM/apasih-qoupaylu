<?php

namespace Pterodactyl\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Str;
use Pterodactyl\Models\BackupManagerSetting;
use Pterodactyl\Models\BackupManagerTelegramAccount;
use Pterodactyl\Models\BackupManagerTelegramVerification;
use Pterodactyl\Services\BackupManager\TelegramService;

class BackupManagerTelegramBotCommand extends Command
{
    protected $signature = 'backup-manager:telegram-bot';
    protected $description = 'Run the Telegram verification bot using long polling.';

    public function handle(TelegramService $telegram): int
    {
        $offset = (int) BackupManagerSetting::value('telegram_offset', '0');

        while (true) {
            // Heartbeat proves the process itself is alive.
            BackupManagerSetting::put('telegram_bot_heartbeat', now()->toIso8601String());

            // OFF means keep the process alive, but do not poll Telegram.
            if (BackupManagerSetting::value('telegram_enabled', '0') !== '1') {
                sleep(5);
                continue;
            }

            if (!$telegram->enabled()) {
                sleep(5);
                continue;
            }

            try {
                $result = $telegram->request('getUpdates', [
                    'offset' => $offset,
                    'timeout' => 25,
                    'allowed_updates' => ['message'],
                ]);

                BackupManagerSetting::put('telegram_bot_heartbeat', now()->toIso8601String());

                foreach (($result['result'] ?? []) as $update) {
                    $offset = ((int) $update['update_id']) + 1;
                    BackupManagerSetting::put('telegram_offset', (string) $offset);

                    $message = $update['message'] ?? [];
                    $chatId = $message['chat']['id'] ?? null;
                    $from = $message['from'] ?? [];
                    $text = trim((string) ($message['text'] ?? ''));

                    if (!$chatId) {
                        continue;
                    }

                    $senderId = (string) ($from['id'] ?? $chatId);
                    $ownerId = trim((string) BackupManagerSetting::value('telegram_owner_id', ''));
                    $isOwner = $ownerId !== '' && hash_equals($ownerId, $senderId);

                    if ($text === '/start' || Str::startsWith($text, '/start ')) {
                        $reply =
                            "👋 <b>Pterodactyl Backup Bot</b>\n\n".
                            "Generate a verification code in your Panel, then send:\n".
                            "<code>/verify YOURCODE</code>";

                        if ($isOwner) {
                            $reply .=
                                "\n\n👑 <b>Owner commands</b>\n".
                                "<code>/status</code>\n".
                                "<code>/bot on</code>\n".
                                "<code>/bot off</code>\n".
                                "<code>/config</code>";
                        }

                        $telegram->send($chatId, $reply);
                        continue;
                    }

                    if ($text === '/status') {
                        if (!$isOwner) {
                            $telegram->send($chatId, "⛔ Owner only.");
                            continue;
                        }

                        $enabled = BackupManagerSetting::value('telegram_enabled', '0') === '1' ? 'ON' : 'OFF';
                        $username = BackupManagerSetting::value('telegram_bot_username', '-');
                        $interval = BackupManagerSetting::value('default_interval_minutes', '1440');
                        $retention = BackupManagerSetting::value('default_retention', '3');

                        $telegram->send(
                            $chatId,
                            "🟢 <b>Backup Manager Status</b>\n\n".
                            "Bot: <b>{$enabled}</b>\n".
                            "Username: ".e($username)."\n".
                            "Default interval: ".e($interval)." minutes\n".
                            "Default retention: ".e($retention)
                        );
                        continue;
                    }

                    if ($text === '/config') {
                        if (!$isOwner) {
                            $telegram->send($chatId, "⛔ Owner only.");
                            continue;
                        }

                        $telegram->send(
                            $chatId,
                            "⚙️ <b>Owner Configuration</b>\n\n".
                            "<code>/bot on</code> — enable bot\n".
                            "<code>/bot off</code> — disable bot\n".
                            "<code>/status</code> — show status\n\n".
                            "Backup interval and retention are configured from Admin → Backup Manager."
                        );
                        continue;
                    }

                    if (preg_match('/^\/bot\s+(on|off)$/i', $text, $match)) {
                        if (!$isOwner) {
                            $telegram->send($chatId, "⛔ Owner only.");
                            continue;
                        }

                        $newState = strtolower($match[1]) === 'on';
                        BackupManagerSetting::put('telegram_enabled', $newState ? '1' : '0');

                        // Important: reply first. Once OFF is stored, TelegramService::send()
                        // would be disabled for subsequent iterations.
                        if ($newState) {
                            $telegram->send($chatId, "✅ Telegram Backup Bot enabled.");
                        } else {
                            // Direct API request is needed because the setting is now OFF.
                            $token = BackupManagerSetting::encrypted('telegram_bot_token');
                            if ($token) {
                                \Illuminate\Support\Facades\Http::timeout(10)->post(
                                    "https://api.telegram.org/bot{$token}/sendMessage",
                                    [
                                        'chat_id' => (string) $chatId,
                                        'text' => "⏸ Telegram Backup Bot disabled.",
                                        'parse_mode' => 'HTML',
                                    ]
                                );
                            }
                        }
                        continue;
                    }

                    if (preg_match('/^\/verify\s+([A-Z0-9]{6,16})$/i', $text, $match)) {
                        $code = strtoupper($match[1]);

                        $verification = BackupManagerTelegramVerification::query()
                            ->where('code', $code)
                            ->where('expires_at', '>', now())
                            ->first();

                        if (!$verification) {
                            $telegram->send($chatId, "❌ Verification code is invalid or expired.");
                            continue;
                        }

                        BackupManagerTelegramAccount::query()->updateOrCreate(
                            ['user_id' => $verification->user_id],
                            [
                                'telegram_user_id' => $senderId,
                                'telegram_username' => $from['username'] ?? null,
                                'verified_at' => now(),
                            ]
                        );

                        $verification->delete();
                        $telegram->send($chatId, "✅ Telegram account successfully connected.");
                    }
                }
            } catch (\Throwable $e) {
                report($e);
                BackupManagerSetting::put(
                    'telegram_bot_last_error',
                    mb_substr($e->getMessage(), 0, 1000)
                );
                sleep(5);
            }
        }
    }
}
