<?php

namespace Pterodactyl\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Crypt;

class BackupManagerSetting extends Model
{
    protected $table = 'backup_manager_settings';
    public $timestamps = false;
    protected $fillable = ['key', 'value'];

    public static function value(string $key, mixed $default = null): mixed
    {
        $row = static::query()->where('key', $key)->first();
        return $row ? $row->value : $default;
    }

    public static function put(string $key, mixed $value): void
    {
        static::query()->updateOrCreate(['key' => $key], ['value' => (string) $value]);
    }

    public static function encrypted(string $key): ?string
    {
        $value = static::value($key);
        if (!$value) return null;
        try { return Crypt::decryptString($value); } catch (\Throwable) { return null; }
    }

    public static function putEncrypted(string $key, ?string $value): void
    {
        if ($value === null || $value === '') return;
        static::put($key, Crypt::encryptString($value));
    }
}
