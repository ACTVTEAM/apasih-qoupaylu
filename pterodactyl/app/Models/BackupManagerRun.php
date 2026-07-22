<?php

namespace Pterodactyl\Models;

use Illuminate\Database\Eloquent\Model;

class BackupManagerRun extends Model
{
    protected $table = 'backup_manager_runs';
    protected $fillable = [
        'server_id','user_id','backup_uuid','status','error',
        'started_at','completed_at','notified_at',
    ];
    protected $casts = ['started_at'=>'datetime','completed_at'=>'datetime','notified_at'=>'datetime'];
}
