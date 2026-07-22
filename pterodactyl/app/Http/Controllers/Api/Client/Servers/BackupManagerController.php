<?php

namespace Pterodactyl\Http\Controllers\Api\Client\Servers;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Str;
use Pterodactyl\Http\Controllers\Api\Client\ClientApiController;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\BackupManagerSetting;
use Pterodactyl\Models\BackupManagerServerSetting;
use Pterodactyl\Models\BackupManagerTelegramAccount;
use Pterodactyl\Models\BackupManagerTelegramVerification;
use Pterodactyl\Services\BackupManager\AutomaticBackupService;
use Symfony\Component\HttpKernel\Exception\HttpException;

class BackupManagerController extends ClientApiController
{
    private function authorizeOwner(Request $request, Server $server): void
    {
        if (!$request->user()->root_admin && (int)$server->owner_id !== (int)$request->user()->id) {
            throw new HttpException(403, 'Only the server owner can configure automatic backups.');
        }
    }

    public function index(Request $request, Server $server): JsonResponse
    {
        $this->authorizeOwner($request,$server);

        $s = BackupManagerServerSetting::query()->firstOrCreate(
            ['server_id'=>$server->id],
            [
                'enabled'=>false,
                'interval_minutes'=>(int)BackupManagerSetting::value('default_interval_minutes','1440'),
                'retention'=>(int)BackupManagerSetting::value('default_retention','3'),
                'telegram_notifications'=>true,
            ]
        );

        $tg = BackupManagerTelegramAccount::query()->where('user_id',$request->user()->id)->first();

        return response()->json([
            'enabled'=>$s->enabled,
            'interval_minutes'=>$s->interval_minutes,
            'retention'=>$s->retention,
            'telegram_notifications'=>$s->telegram_notifications,
            'next_backup_at'=>$s->next_backup_at?->toIso8601String(),
            'telegram'=>[
                'connected'=>(bool)$tg,
                'username'=>$tg?->telegram_username,
            ],
            'limits'=>[
                'min_interval'=>(int)BackupManagerSetting::value('min_interval_minutes','60'),
                'max_retention'=>(int)BackupManagerSetting::value('max_retention','10'),
            ],
        ]);
    }

    public function update(Request $request, Server $server): JsonResponse
    {
        $this->authorizeOwner($request,$server);

        $min = (int)BackupManagerSetting::value('min_interval_minutes','60');
        $maxRetention = (int)BackupManagerSetting::value('max_retention','10');

        $data = $request->validate([
            'enabled'=>'required|boolean',
            'interval_minutes'=>"required|integer|min:{$min}|max:43200",
            'retention'=>"required|integer|min:1|max:{$maxRetention}",
            'telegram_notifications'=>'required|boolean',
        ]);

        $s = BackupManagerServerSetting::query()->updateOrCreate(
            ['server_id'=>$server->id],
            $data + ['next_backup_at'=>now()->addMinutes((int)$data['interval_minutes'])]
        );

        return response()->json(['success'=>true,'next_backup_at'=>$s->next_backup_at?->toIso8601String()]);
    }

    public function run(Request $request, Server $server, AutomaticBackupService $service): JsonResponse
    {
        $this->authorizeOwner($request,$server);
        $run = $service->start($server, $request->user()->id);
        return response()->json(['success'=>true,'run_id'=>$run->id]);
    }

    public function verification(Request $request, Server $server): JsonResponse
    {
        $this->authorizeOwner($request,$server);
        $code = strtoupper(Str::random(8));

        BackupManagerTelegramVerification::query()->updateOrCreate(
            ['user_id'=>$request->user()->id],
            ['code'=>$code,'expires_at'=>now()->addMinutes(10)]
        );

        return response()->json([
            'code'=>$code,
            'bot_username'=>BackupManagerSetting::value('telegram_bot_username',''),
            'expires_in'=>600,
        ]);
    }

    public function disconnect(Request $request, Server $server): JsonResponse
    {
        $this->authorizeOwner($request,$server);
        BackupManagerTelegramAccount::query()->where('user_id',$request->user()->id)->delete();
        return response()->json(['success'=>true]);
    }
}
