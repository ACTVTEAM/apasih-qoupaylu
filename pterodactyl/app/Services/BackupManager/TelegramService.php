<?php

namespace Pterodactyl\Services\BackupManager;

use Illuminate\Support\Facades\Http;
use Pterodactyl\Models\BackupManagerSetting;

class TelegramService
{
    public function enabled(): bool
    {
        return BackupManagerSetting::value('telegram_enabled', '0') === '1'
            && (bool) BackupManagerSetting::encrypted('telegram_bot_token');
    }

    private function token(): string
    {
        return (string) BackupManagerSetting::encrypted('telegram_bot_token');
    }

    public function request(string $method, array $data = []): array
    {
        if (!$this->enabled()) return [];
        return Http::timeout(20)
            ->post("https://api.telegram.org/bot{$this->token()}/{$method}", $data)
            ->throw()->json();
    }

    public function send(string|int $chatId, string $text): void
    {
        $this->request('sendMessage', [
            'chat_id' => (string) $chatId,
            'text' => $text,
            'parse_mode' => 'HTML',
        ]);
    }
}
