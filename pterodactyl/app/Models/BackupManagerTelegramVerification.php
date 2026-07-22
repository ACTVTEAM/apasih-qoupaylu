<?php

namespace Pterodactyl\Models;

use Illuminate\Database\Eloquent\Model;

class BackupManagerTelegramVerification extends Model
{
    protected $table = 'backup_manager_telegram_verifications';
    protected $fillable = ['user_id','code','expires_at'];
    protected $casts = ['expires_at'=>'datetime'];
}
