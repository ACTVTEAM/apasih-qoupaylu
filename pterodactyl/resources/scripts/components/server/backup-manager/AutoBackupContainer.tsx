import React, { useEffect, useState } from 'react';
import axios from 'axios';
import { ServerContext } from '@/state/server';
import ContentBox from '@/components/elements/ContentBox';
import Button from '@/components/elements/Button';

export default () => {
    const uuid = ServerContext.useStoreState((state) => state.server.data!.uuid);
    const [data, setData] = useState<any>(null);
    const [message, setMessage] = useState('');

    const load = () => axios.get(`/api/client/servers/${uuid}/backup-manager`).then(r => setData(r.data));
    useEffect(() => { load(); }, [uuid]);

    if (!data) return <div>Loading...</div>;

    const save = async () => {
        await axios.put(`/api/client/servers/${uuid}/backup-manager`, {
            enabled: !!data.enabled,
            interval_minutes: Number(data.interval_minutes),
            retention: Number(data.retention),
            telegram_notifications: !!data.telegram_notifications,
        });
        setMessage('Settings saved.');
        load();
    };

    const verify = async () => {
        const r = await axios.post(`/api/client/servers/${uuid}/backup-manager/telegram/verification`);
        const username = String(r.data.bot_username || '').replace(/^@/,'');
        setMessage(`Open @${username} and send: /verify ${r.data.code}`);
    };

    const run = async () => {
        await axios.post(`/api/client/servers/${uuid}/backup-manager/run`);
        setMessage('Backup started.');
    };

    return (
        <div className={'space-y-4'}>
            {message && <div className={'rounded bg-gray-700 p-4 text-sm'}>{message}</div>}
            <ContentBox title={'Automatic Backup'}>
                <label className={'block mb-4'}>
                    <input type={'checkbox'} checked={!!data.enabled}
                        onChange={e => setData({...data, enabled:e.target.checked})}/> Enable automatic backup
                </label>
                <label className={'block mb-4'}>Interval (minutes)
                    <input className={'input-dark w-full mt-1'} type={'number'} min={data.limits.min_interval}
                        value={data.interval_minutes} onChange={e=>setData({...data,interval_minutes:e.target.value})}/>
                </label>
                <label className={'block mb-4'}>Keep latest backups
                    <input className={'input-dark w-full mt-1'} type={'number'} min={1} max={data.limits.max_retention}
                        value={data.retention} onChange={e=>setData({...data,retention:e.target.value})}/>
                </label>
                <label className={'block mb-4'}>
                    <input type={'checkbox'} checked={!!data.telegram_notifications}
                        onChange={e=>setData({...data,telegram_notifications:e.target.checked})}/> Telegram notifications
                </label>
                <div className={'flex gap-2'}><Button onClick={save}>Save</Button><Button isSecondary onClick={run}>Backup Now</Button></div>
            </ContentBox>

            <ContentBox title={'Telegram'}>
                <p className={'mb-4'}>{data.telegram.connected ? `Connected: @${data.telegram.username || 'Telegram user'}` : 'Not connected'}</p>
                {!data.telegram.connected
                    ? <Button onClick={verify}>Generate Verification Code</Button>
                    : <Button color={'red'} onClick={async()=>{ await axios.delete(`/api/client/servers/${uuid}/backup-manager/telegram`); load(); }}>Disconnect</Button>}
            </ContentBox>
        </div>
    );
};
