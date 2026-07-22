import React, { useEffect, useState } from 'react';
import http, { httpErrorToHuman } from '@/api/http';
import { ServerContext } from '@/state/server';
import ContentBox from '@/components/elements/ContentBox';
import Button from '@/components/elements/Button';

interface BackupManagerData {
    enabled: boolean;
    interval_minutes: number;
    retention: number;
    telegram_notifications: boolean;
    next_backup_at: string | null;
    telegram: {
        connected: boolean;
        username: string | null;
    };
    limits: {
        min_interval: number;
        max_retention: number;
    };
}

export default () => {
    // IMPORTANT:
    // Pterodactyl client API routes use the server identifier used by the Panel URL
    // (for example 69d846dc), not state.server.data.uuid (the full UUID).
    const serverId = ServerContext.useStoreState((state) => state.server.data!.id);

    const [data, setData] = useState<BackupManagerData | null>(null);
    const [message, setMessage] = useState('');
    const [error, setError] = useState('');
    const [loading, setLoading] = useState(true);
    const [saving, setSaving] = useState(false);

    const endpoint = `/api/client/servers/${serverId}/backup-manager`;

    const load = async () => {
        setLoading(true);
        setError('');

        try {
            const response = await http.get(endpoint);
            setData(response.data);
        } catch (e) {
            setError(httpErrorToHuman(e));
        } finally {
            setLoading(false);
        }
    };

    useEffect(() => {
        load();
    }, [serverId]);

    const save = async () => {
        if (!data) return;

        setSaving(true);
        setError('');
        setMessage('');

        try {
            await http.put(endpoint, {
                enabled: Boolean(data.enabled),
                interval_minutes: Number(data.interval_minutes),
                retention: Number(data.retention),
                telegram_notifications: Boolean(data.telegram_notifications),
            });

            setMessage('Auto Backup settings saved.');
            await load();
        } catch (e) {
            setError(httpErrorToHuman(e));
        } finally {
            setSaving(false);
        }
    };

    const verify = async () => {
        setError('');
        setMessage('');

        try {
            const response = await http.post(`${endpoint}/telegram/verification`);
            const username = String(response.data.bot_username || '').replace(/^@/, '');

            if (!username) {
                setError('Telegram Bot Username has not been configured by the administrator.');
                return;
            }

            setMessage(`Open @${username} in Telegram, press Start, then send: /verify ${response.data.code}`);
        } catch (e) {
            setError(httpErrorToHuman(e));
        }
    };

    const run = async () => {
        setError('');
        setMessage('');

        try {
            await http.post(`${endpoint}/run`);
            setMessage('Backup has been started.');
        } catch (e) {
            setError(httpErrorToHuman(e));
        }
    };

    const disconnect = async () => {
        setError('');
        setMessage('');

        try {
            await http.delete(`${endpoint}/telegram`);
            setMessage('Telegram account disconnected.');
            await load();
        } catch (e) {
            setError(httpErrorToHuman(e));
        }
    };

    if (loading) {
        return <div className={'p-4'}>Loading Auto Backup settings...</div>;
    }

    if (error && !data) {
        return (
            <div className={'p-4'}>
                <div className={'rounded bg-red-600 p-4 text-white'}>
                    <strong>Failed to load Auto Backup.</strong>
                    <div className={'mt-2'}>{error}</div>
                    <div className={'mt-4'}>
                        <Button onClick={load}>Retry</Button>
                    </div>
                </div>
            </div>
        );
    }

    if (!data) {
        return <div className={'p-4'}>Auto Backup data is unavailable.</div>;
    }

    return (
        <div className={'space-y-4'}>
            {error && (
                <div className={'rounded bg-red-600 p-4 text-white'}>
                    {error}
                </div>
            )}

            {message && (
                <div className={'rounded bg-gray-700 p-4 text-sm'}>
                    {message}
                </div>
            )}

            <ContentBox title={'Automatic Backup'}>
                <label className={'block mb-4'}>
                    <input
                        type={'checkbox'}
                        checked={Boolean(data.enabled)}
                        onChange={(e) => setData({ ...data, enabled: e.target.checked })}
                    />{' '}
                    Enable automatic backup
                </label>

                <label className={'block mb-4'}>
                    Interval (minutes)
                    <input
                        className={'input-dark w-full mt-1'}
                        type={'number'}
                        min={data.limits.min_interval}
                        value={data.interval_minutes}
                        onChange={(e) =>
                            setData({ ...data, interval_minutes: Number(e.target.value) })
                        }
                    />
                    <small className={'block mt-1 text-gray-400'}>
                        Minimum allowed: {data.limits.min_interval} minutes.
                    </small>
                </label>

                <label className={'block mb-4'}>
                    Keep latest backups
                    <input
                        className={'input-dark w-full mt-1'}
                        type={'number'}
                        min={1}
                        max={data.limits.max_retention}
                        value={data.retention}
                        onChange={(e) =>
                            setData({ ...data, retention: Number(e.target.value) })
                        }
                    />
                    <small className={'block mt-1 text-gray-400'}>
                        Maximum allowed: {data.limits.max_retention}.
                    </small>
                </label>

                <label className={'block mb-4'}>
                    <input
                        type={'checkbox'}
                        checked={Boolean(data.telegram_notifications)}
                        onChange={(e) =>
                            setData({ ...data, telegram_notifications: e.target.checked })
                        }
                    />{' '}
                    Telegram notifications
                </label>

                {data.next_backup_at && (
                    <p className={'mb-4 text-sm text-gray-400'}>
                        Next backup: {new Date(data.next_backup_at).toLocaleString()}
                    </p>
                )}

                <div className={'flex gap-2'}>
                    <Button disabled={saving} onClick={save}>
                        {saving ? 'Saving...' : 'Save'}
                    </Button>
                    <Button isSecondary onClick={run}>
                        Backup Now
                    </Button>
                </div>
            </ContentBox>

            <ContentBox title={'Telegram'}>
                <p className={'mb-4'}>
                    {data.telegram.connected
                        ? `Connected: @${data.telegram.username || 'Telegram user'}`
                        : 'Not connected'}
                </p>

                {!data.telegram.connected ? (
                    <Button onClick={verify}>Generate Verification Code</Button>
                ) : (
                    <Button color={'red'} onClick={disconnect}>
                        Disconnect
                    </Button>
                )}
            </ContentBox>
        </div>
    );
};