<?php

namespace Pterodactyl\Models;

use Illuminate\Database\Eloquent\Model;

class BackupManagerTelegramAccount extends Model
{
    protected $table = 'backup_manager_telegram_accounts';
    protected $fillable = ['user_id','telegram_user_id','telegram_username','verified_at'];
    protected $casts = ['verified_at'=>'datetime'];
}
