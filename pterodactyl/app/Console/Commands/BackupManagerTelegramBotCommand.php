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
        if (!$telegram->enabled()) {
            $this->error('Telegram is disabled or bot token is missing.');
            return self::FAILURE;
        }

        $offset = (int) BackupManagerSetting::value('telegram_offset', '0');

        while (true) {
            try {
                $result = $telegram->request('getUpdates', [
                    'offset'=>$offset,
                    'timeout'=>25,
                    'allowed_updates'=>['message'],
                ]);

                foreach (($result['result'] ?? []) as $update) {
                    $offset = ((int) $update['update_id']) + 1;
                    BackupManagerSetting::put('telegram_offset', (string)$offset);

                    $m = $update['message'] ?? [];
                    $chat = $m['chat']['id'] ?? null;
                    $from = $m['from'] ?? [];
                    $text = trim((string)($m['text'] ?? ''));

                    if (!$chat) continue;

                    if ($text === '/start' || Str::startsWith($text, '/start ')) {
                        $telegram->send($chat,
                            "👋 <b>Pterodactyl Backup Bot</b>\n\n".
                            "Generate a verification code in your Panel, then send:\n".
                            "<code>/verify YOURCODE</code>"
                        );
                        continue;
                    }

                    if (preg_match('/^\/verify\s+([A-Z0-9]{6,16})$/i', $text, $match)) {
                        $code = strtoupper($match[1]);
                        $v = BackupManagerTelegramVerification::query()
                            ->where('code',$code)
                            ->where('expires_at','>',now())
                            ->first();

                        if (!$v) {
                            $telegram->send($chat, "❌ Verification code is invalid or expired.");
                            continue;
                        }

                        BackupManagerTelegramAccount::query()->updateOrCreate(
                            ['user_id'=>$v->user_id],
                            [
                                'telegram_user_id'=>(string)($from['id'] ?? $chat),
                                'telegram_username'=>$from['username'] ?? null,
                                'verified_at'=>now(),
                            ]
                        );
                        $v->delete();
                        $telegram->send($chat, "✅ Telegram account successfully connected.");
                    }
                }
            } catch (\Throwable $e) {
                report($e);
                sleep(5);
            }
        }
    }
}
