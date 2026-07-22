<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('backup_manager_settings', function (Blueprint $t) {
            $t->string('key')->primary();
            $t->text('value')->nullable();
        });

        Schema::create('backup_manager_server_settings', function (Blueprint $t) {
            $t->id();
            $t->unsignedInteger('server_id')->unique();
            $t->boolean('enabled')->default(false);
            $t->unsignedInteger('interval_minutes')->default(1440);
            $t->unsignedInteger('retention')->default(3);
            $t->boolean('telegram_notifications')->default(true);
            $t->timestamp('last_backup_at')->nullable();
            $t->timestamp('next_backup_at')->nullable();
            $t->timestamps();
            $t->foreign('server_id')->references('id')->on('servers')->cascadeOnDelete();
        });

        Schema::create('backup_manager_telegram_accounts', function (Blueprint $t) {
            $t->id();
            $t->unsignedInteger('user_id')->unique();
            $t->string('telegram_user_id',64)->unique();
            $t->string('telegram_username')->nullable();
            $t->timestamp('verified_at')->nullable();
            $t->timestamps();
            $t->foreign('user_id')->references('id')->on('users')->cascadeOnDelete();
        });

        Schema::create('backup_manager_telegram_verifications', function (Blueprint $t) {
            $t->id();
            $t->unsignedInteger('user_id')->unique();
            $t->string('code',16)->unique();
            $t->timestamp('expires_at');
            $t->timestamps();
            $t->foreign('user_id')->references('id')->on('users')->cascadeOnDelete();
        });

        Schema::create('backup_manager_runs', function (Blueprint $t) {
            $t->id();
            $t->unsignedInteger('server_id');
            $t->unsignedInteger('user_id');
            $t->uuid('backup_uuid')->nullable()->index();
            $t->string('status',20)->default('running');
            $t->text('error')->nullable();
            $t->timestamp('started_at')->nullable();
            $t->timestamp('completed_at')->nullable();
            $t->timestamp('notified_at')->nullable();
            $t->timestamps();
            $t->foreign('server_id')->references('id')->on('servers')->cascadeOnDelete();
            $t->foreign('user_id')->references('id')->on('users')->cascadeOnDelete();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('backup_manager_runs');
        Schema::dropIfExists('backup_manager_telegram_verifications');
        Schema::dropIfExists('backup_manager_telegram_accounts');
        Schema::dropIfExists('backup_manager_server_settings');
        Schema::dropIfExists('backup_manager_settings');
    }
};
