@extends('layouts.admin')
@section('title') Backup Manager @endsection

@section('content-header')
<h1>Backup Manager <small>Automatic backup, Telegram, and update configuration.</small></h1>
<ol class="breadcrumb"><li><a href="{{ route('admin.index') }}">Admin</a></li><li class="active">Backup Manager</li></ol>
@endsection

@section('content')
@if(session('success')) <div class="alert alert-success">{{ session('success') }}</div> @endif

<form method="POST" action="{{ route('admin.backup-manager.update') }}">
@csrf
<div class="row">
<div class="col-md-6">
<div class="box box-primary">
<div class="box-header"><h3 class="box-title">Backup Configuration</h3></div>
<div class="box-body">
<label><input type="checkbox" name="backup_enabled" value="1" {{ $settings['backup_enabled']=='1'?'checked':'' }}> Enable automatic backups</label>
<div class="form-group"><label>Default interval (minutes)</label><input class="form-control" type="number" name="default_interval_minutes" value="{{ $settings['default_interval_minutes'] }}"></div>
<div class="form-group"><label>Minimum user interval (minutes)</label><input class="form-control" type="number" name="min_interval_minutes" value="{{ $settings['min_interval_minutes'] }}"></div>
<div class="form-group"><label>Default retention</label><input class="form-control" type="number" name="default_retention" value="{{ $settings['default_retention'] }}"></div>
<div class="form-group"><label>Maximum retention</label><input class="form-control" type="number" name="max_retention" value="{{ $settings['max_retention'] }}"></div>
</div></div></div>

<div class="col-md-6">
<div class="box box-success">
<div class="box-header"><h3 class="box-title">Telegram Bot</h3></div>
<div class="box-body">
<label><input type="checkbox" name="telegram_enabled" value="1" {{ $settings['telegram_enabled']=='1'?'checked':'' }}> Enable Telegram</label>
<div class="form-group"><label>Bot username</label><input class="form-control" name="telegram_bot_username" placeholder="@mybot" value="{{ $settings['telegram_bot_username'] }}"></div>
<div class="form-group"><label>Bot token</label><input class="form-control" type="password" name="telegram_bot_token" placeholder="{{ $hasToken ? 'Token already saved — leave blank to keep' : '123456:ABC...' }}"></div>
<p class="text-muted">Token is encrypted using Laravel APP_KEY before storage.</p>
</div></div></div>
</div>

<div class="box box-default"><div class="box-body">
<label><input type="checkbox" name="auto_update_check" value="1" {{ $settings['auto_update_check']=='1'?'checked':'' }}> Enable update checks</label>
<button class="btn btn-primary pull-right" type="submit">Save Configuration</button>
</div></div>
</form>

<div class="row">
<div class="col-md-6"><form method="POST" action="{{ route('admin.backup-manager.telegram.test') }}">@csrf<button class="btn btn-success">Test Telegram Bot</button></form></div>
<div class="col-md-6 text-right"><form method="POST" action="{{ route('admin.backup-manager.update.check') }}">@csrf<button class="btn btn-info">Check Pterodactyl Update</button></form></div>
</div>
@endsection
