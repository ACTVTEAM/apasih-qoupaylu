<?php

namespace Pterodactyl\Providers;

use Illuminate\Support\ServiceProvider;
use Illuminate\Support\Facades\Route;
use Pterodactyl\Console\Commands\BackupManagerRunCommand;
use Pterodactyl\Console\Commands\BackupManagerTelegramBotCommand;
use Pterodactyl\Http\Controllers\Admin\BackupManagerController as AdminController;
use Pterodactyl\Http\Controllers\Api\Client\Servers\BackupManagerController as ClientController;
use Pterodactyl\Http\Middleware\AdminAuthenticate;
use Pterodactyl\Http\Middleware\Api\Client\Server\AuthenticateServerAccess;
use Pterodactyl\Http\Middleware\Api\Client\Server\ResourceBelongsToServer;
use Pterodactyl\Http\Middleware\Activity\ServerSubject;
use Pterodactyl\Http\Middleware\RequireTwoFactorAuthentication;

class BackupManagerServiceProvider extends ServiceProvider
{
    public function boot(): void
    {
        $this->loadMigrationsFrom(database_path('migrations/backup-manager'));
        $this->loadViewsFrom(resource_path('views/backup-manager'), 'backup-manager');

        Route::middleware(['web','auth.session',RequireTwoFactorAuthentication::class,AdminAuthenticate::class])
            ->prefix('/admin/backup-manager')
            ->group(function () {
                Route::get('/', [AdminController::class,'index'])->name('admin.backup-manager');
                Route::post('/', [AdminController::class,'update'])->name('admin.backup-manager.update');
                Route::post('/telegram/test', [AdminController::class,'testTelegram'])->name('admin.backup-manager.telegram.test');
                Route::post('/update/check', [AdminController::class,'checkUpdate'])->name('admin.backup-manager.update.check');
            });

        Route::middleware([
            'api',RequireTwoFactorAuthentication::class,'client-api','throttle:api.client',
            ServerSubject::class,AuthenticateServerAccess::class,ResourceBelongsToServer::class,
        ])->prefix('/api/client/servers/{server}/backup-manager')->scopeBindings()->group(function () {
            Route::get('/', [ClientController::class,'index']);
            Route::put('/', [ClientController::class,'update']);
            Route::post('/run', [ClientController::class,'run']);
            Route::post('/telegram/verification', [ClientController::class,'verification']);
            Route::delete('/telegram', [ClientController::class,'disconnect']);
        });
    }

    public function register(): void
    {
        $this->commands([BackupManagerRunCommand::class, BackupManagerTelegramBotCommand::class]);
    }
}
