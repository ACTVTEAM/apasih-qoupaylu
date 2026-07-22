<?php

namespace Pterodactyl\Models;

use Illuminate\Database\Eloquent\Model;

class BackupManagerServerSetting extends Model
{
    protected $table = 'backup_manager_server_settings';
    protected $fillable = [
        'server_id','enabled','interval_minutes','retention',
        'telegram_notifications','last_backup_at','next_backup_at',
    ];
    protected $casts = [
        'enabled'=>'boolean',
        'telegram_notifications'=>'boolean',
        'last_backup_at'=>'datetime',
        'next_backup_at'=>'datetime',
    ];

    public function server() { return $this->belongsTo(Server::class); }
}
