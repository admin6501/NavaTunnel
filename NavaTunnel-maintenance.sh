#!/usr/bin/env bash
# NavaTunnel maintenance v1.2.0
# One-time retirement of optional features; no tunnel creation or routing service.
set -euo pipefail
exec python3 - "$@" <<'PY'
import fcntl, hashlib, json, os, pwd, re, shlex, shutil, subprocess, sys, tempfile
from pathlib import Path

STATE=Path('/etc/gre-panel')
UNITS=Path('/etc/systemd/system')
BIN=Path('/usr/local/bin')
FRP=Path('/etc/frp')
BACKUPS=Path('/var/backups/navatunnel')
ROOT_KEYS=Path('/root/.ssh')
SYSCTL=Path('/etc/sysctl.d')
SSH_CONFIG=Path('/etc/ssh/sshd_config')
CARRIER_HOME=Path('/var/lib/navatunnel-carriers')
ARCHIVE=None


def run(args,check=True,**kwargs):
    return subprocess.run(list(map(str,args)),check=check,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90,**kwargs)


def load(path,default=None):
    return json.loads(path.read_text()) if path.exists() else ({} if default is None else default)


def save(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(dir=path.parent,prefix='.retire-')
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,'w') as f:
            f.write(value if isinstance(value,str) else json.dumps(value,indent=2)+'\n');f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)


def archive(path,label=None):
    global ARCHIVE
    if not path.exists():return
    if ARCHIVE is None:
        BACKUPS.mkdir(parents=True,exist_ok=True)
        ARCHIVE=Path(tempfile.mkdtemp(prefix='removed-features-',dir=BACKUPS));ARCHIVE.chmod(0o700)
        print('Private retirement backup: '+str(ARCHIVE),flush=True)
    dest=ARCHIVE/(label or path.name)
    if dest.exists():return
    if path.is_dir():shutil.copytree(path,dest,symlinks=True,dirs_exist_ok=True)
    else:shutil.copy2(path,dest)
    for p in [dest,*dest.rglob('*')] if dest.is_dir() else [dest]:
        if not p.is_symlink():p.chmod(0o700 if p.is_dir() else 0o600)


def stop_owned(path):
    if path.exists():
        archive(path)
        run(['systemctl','disable','--now',path.name])
        path.unlink()


def clear_cluster_rules():
    if not shutil.which('iptables'):return
    targets={'nat':{'NAVA-CLUSTER','NAVA-CLUSTER-PREROUTING','NAVA-CLUSTER-POSTROUTING'},'filter':{'NAVA-CLUSTER-FORWARD'}}
    for table,owned in targets.items():
        listing=run(['iptables','-w','5','-t',table,'-S']).stdout
        rows=[shlex.split(row) for row in listing.splitlines()]
        present={r[1] for r in rows if len(r)>1 and r[0]=='-N' and r[1] in owned}
        for r in rows:
            if len(r)<3 or r[0]!='-A' or r[1] in owned:continue
            jump=r[r.index('-j')+1] if '-j' in r else ''
            tagged='--comment' in r and r[r.index('--comment')+1] in ('navatunnel-cluster','navatunnel-core-cluster')
            old_mark='0x4e560000/0xffff0000' in r and '--ctstate' in r and r[r.index('--ctstate')+1]=='DNAT'
            if (jump in owned and tagged) or (old_mark and ((table=='nat' and r[1]=='POSTROUTING' and jump=='MASQUERADE') or (table=='filter' and r[1]=='FORWARD' and jump=='ACCEPT'))):
                run(['iptables','-w','5','-t',table,'-D',*r[1:]])
        # Flush only owned chains; foreign references cause deletion to fail visibly.
        for chain in sorted(present):run(['iptables','-w','5','-t',table,'-F',chain])
        for chain in sorted(present):run(['iptables','-w','5','-t',table,'-X',chain])


def retire_cluster():
    files=[STATE/name for name in ('cluster_v2.json','core.json','core.sock','peer-api.crt','peer-api.key','cluster.json','cluster-runtime.json','cluster-key','cluster-key.pub','cluster-tick.lock','core-restart-required')]
    units=[UNITS/name for name in ('NavaTunnel-core.service','NavaTunnel-cluster.timer','NavaTunnel-cluster.service')]
    keys=ROOT_KEYS/'authorized_keys'
    before=keys.read_text() if keys.exists() else ''
    after=''.join(line for line in before.splitlines(keepends=True) if not re.search(r' nava-cluster-[a-f0-9]{12}\s*$',line))
    if not any(p.exists() for p in files+units) and before==after:return
    for p in files:
        if p.exists() and not p.is_socket():archive(p)
    for path in units:stop_owned(path)
    # The daemon is stopped before its routes and private socket are removed.
    clear_cluster_rules()
    if before!=after:archive(keys,'root-authorized-keys');save(keys,after)
    for path in files:path.unlink(missing_ok=True)
    run(['systemctl','daemon-reload'])
    print('Retired Cluster routing and its owned services.')


def restore_plan(folder,t):
    meta=t.get('legacy')
    if not meta:return None
    if meta.get('role')!=t.get('role'):raise ValueError('Invalid saved rollback role.')
    files=[]
    for kind,name in meta.get('files',[]):
        pattern=r'(?:gre-(?:tunnel|t[0-9]+)|frps(?:-[0-9]+)?|frpc|gre-chaff(?:-[0-9]+)?)\.service' if kind=='units' else r'(?:frps(?:-[0-9]+)?|frpc)\.toml'
        if kind not in ('units','frp') or not re.fullmatch(pattern,name):raise ValueError('Invalid saved rollback filename.')
        source=folder/'previous'/kind/name;dest=(UNITS if kind=='units' else FRP)/name
        if not source.is_file() or source.is_symlink():raise ValueError('Saved GRE configuration is missing: '+str(source))
        if dest.exists() and dest.read_bytes()!=source.read_bytes():raise ValueError('A saved GRE rollback conflicts with '+str(dest)+'; settings were preserved.')
        files.append((source,dest))
    if not files:raise ValueError('The saved GRE rollback contains no files.')
    peer=meta.get('peer')
    if meta['role']=='iran':
        if not isinstance(peer,dict) or not isinstance(peer.get('id'),int) or not re.fullmatch(r'gre-(tunnel|t[0-9]+)',peer.get('gre_if','')):raise ValueError('Invalid saved Iran peer.')
        for p in load(STATE/'peers.json',{'peers':[]}).get('peers',[]):
            if p==peer:continue
            if set(p.get('ports',[])) & set(peer.get('ports',[])) or (p.get('frp_port') and p.get('frp_port')==peer.get('frp_port')) or p.get('id')==peer['id'] or p.get('gre_if')==peer['gre_if'] or set(p.get(k) for k in ('local_gre','peer_gre') if p.get(k)) & set(peer.get(k) for k in ('local_gre','peer_gre') if peer.get(k)):
                raise ValueError('Saved GRE peer conflicts with a current tunnel; settings were preserved.')
    target=t.get('previous_target',{}).get('interface') or (peer.get('gre_if') if isinstance(peer,dict) else None)
    if not target:
        target=next((dest.stem for source,dest in files if re.fullmatch(r'gre-(tunnel|t[0-9]+)\.service',dest.name)),None)
    if target and not re.fullmatch(r'gre-(tunnel|t[0-9]+)',target):raise ValueError('Invalid rollback counter interface.')
    return meta,files,peer,target


def remove_account(number):
    user='nava'+number;home=CARRIER_HOME/number
    try:account=pwd.getpwnam(user)
    except KeyError:account=None
    if account and account.pw_dir!=str(home):raise ValueError('Carrier account ownership does not match; SSH settings were preserved.')
    before=SSH_CONFIG.read_text() if SSH_CONFIG.exists() else ''
    start='# NavaTunnel '+number+' begin';end='# NavaTunnel '+number+' end'
    after=re.sub(r'\n?'+re.escape(start)+r'\n.*?'+re.escape(end)+r'\n?','\n',before,flags=re.S)
    if after!=before:
        archive(SSH_CONFIG,'sshd_config')
        save(SSH_CONFIG,after)
        try:
            run(['/usr/sbin/sshd','-t','-f',SSH_CONFIG])
            service='ssh' if run(['systemctl','is-active','--quiet','ssh'],False).returncode==0 else 'sshd'
            run(['systemctl','reload',service])
        except Exception:
            save(SSH_CONFIG,before);raise
    if account:
        key=home/'.ssh/authorized_keys'
        if key.exists():archive(key,'carrier-'+number+'-authorized_keys');key.unlink()
        run(['pkill','-u',str(account.pw_uid)],False)
        run(['userdel',user])
    if home.exists():archive(home,'carrier-'+number);shutil.rmtree(home)


def retire_link(folder,t,plan):
    number=folder.name
    archive(folder,'navalink-'+number)
    if (STATE/'traffic.json').exists():archive(STATE/'traffic.json','traffic-before.json')
    for part in ('ssh','server','client'):stop_owned(UNITS/('navalink-'+number+'-'+part+'.service'))
    if plan:
        meta,files,peer,target=plan
        if meta['role']=='iran':
            data=load(STATE/'peers.json',{'peers':[]});archive(STATE/'peers.json','peers-before.json')
            if peer not in data['peers']:data['peers'].append(peer)
            save(STATE/'peers.json',data)
        for source,dest in files:
            dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,dest);dest.chmod(0o600)
        run(['systemctl','daemon-reload'])
        active=meta.get('active',{})
        # GRE first, restore the counter target, then start only previously active FRP units.
        for group in ('gre-','frp'):
            for source,dest in files:
                if dest.suffix!='.service' or not dest.name.startswith(group) or not active.get(dest.name):continue
                if os.environ.get('NAVATUNNEL_RESTORE')!='1':
                    run(['systemctl','enable',dest.name]);run(['systemctl','restart',dest.name]);run(['systemctl','is-active','--quiet',dest.name])
            if group=='gre-' and target and t.get('counter') in load(STATE/'traffic.json',{}):
                run(['bash',BIN/'NavaTunnel-traffic.sh','retarget',t['counter'],'--interface',target])
        print('Restored the saved GRE/FRP configuration for '+t.get('name',number)+'. Update the other endpoint too.')
    else:
        counter=t.get('counter') or 'navalink-'+number
        if counter in load(STATE/'traffic.json',{}):run(['bash',BIN/'NavaTunnel-traffic.sh','remove',counter])
        print('Stopped '+t.get('name',number)+': no previous GRE configuration exists; its settings and usage were archived.')
    if t.get('role')=='foreign':remove_account(number)
    shutil.rmtree(folder)
    run(['systemctl','daemon-reload'])


def retire_links():
    plans=[]
    for folder in sorted((STATE/'navalink').glob('*')):
        if not re.fullmatch(r'[a-f0-9]{12}',folder.name) or not folder.is_dir():raise ValueError('Invalid retired connection directory; settings were preserved.')
        config=folder/'config.json'
        if not config.exists():
            # Failed provisioning may leave only a generated key.
            archive(folder,'navalink-'+folder.name);shutil.rmtree(folder);continue
        t=load(config)
        if t.get('id')!=folder.name or t.get('role') not in ('iran','foreign'):raise ValueError('Invalid retired connection identity.')
        plans.append((folder,t,restore_plan(folder,t)))
    for folder,t,plan in plans:retire_link(folder,t,plan)
    path=STATE/'navalink'
    if path.exists():path.rmdir()
    # Never touch unrelated root SSH host records or authorized keys.
    path=STATE/'ssh-known-hosts'
    if path.exists():archive(path);path.unlink()


def retire():
    STATE.mkdir(parents=True,exist_ok=True)
    with open(STATE/'.retire.lock','a') as lock:
        os.chmod(lock.name,0o600);fcntl.flock(lock,fcntl.LOCK_EX)
        retire_cluster();retire_links();cleanup_extra_tools()


def cleanup_extra_tools():
    # This migration only retires the optional tools removed after 1.1.0.
    # Normal GRE/FRP, quota counters and watchdog settings are retained.
    import shutil
    paths=[STATE/name for name in ('wss_carrier.json','rescue.json','rescue','peer_link.json','alerts.json','history.json','fleet_history.json','traffic_peers.json','auto_pool.json','gre_mtu','core-errors.log','security-audit.log')]
    paths += [STATE/(name+'.'+str(n)) for name in ('core-errors.log','security-audit.log') for n in range(1,4)]
    paths += [FRP/'dial.env',SYSCTL/'99-navatunnel-reserved-ports.conf']
    rescue_units=[UNITS/('navatunnel-rescue-'+name+'.service') for name in ('frpc','frps','fw','dnat')]
    paths += rescue_units
    existing=[p for p in paths if p.exists()]
    perf=load(STATE/'perf.json',{})
    core=load(STATE/'core.json',{})
    old_auto='auto_pool' in perf
    old_core=any(k!='port' for k in core)
    if not existing and not old_auto and not old_core:return
    BACKUPS.mkdir(parents=True,exist_ok=True)
    archive=Path(tempfile.mkdtemp(prefix='removed-tools-',dir=BACKUPS));archive.chmod(0o700)
    if old_auto:save(archive/'perf-before.json',perf)
    if old_core:save(archive/'core-before.json',core)
    # If the removed GRE relay is in use, move that interface to the existing FOU carrier.
    # Both endpoints must receive the update when retiring a live relay.
    wss=load(STATE/'wss_carrier.json',{})
    carrier=load(STATE/'carrier.json',{})
    if wss.get('enabled') or str(carrier.get('active_carrier','')).startswith('wss'):
        iface=wss.get('gre_interface','gre-tunnel')
        if not re.fullmatch(r'gre-(tunnel|t[0-9]+)',iface):raise ValueError('Invalid former WSS GRE interface; settings were preserved.')
        fou=int(carrier.get('fou_port1',443))
        if not 1<=fou<=65535:raise ValueError('Invalid saved FOU port.')
        peers=load(STATE/'peers.json',{})
        save(archive/'carrier-before.json',carrier)
        if (STATE/'peers.json').exists():save(archive/'peers-before.json',peers)
        updated=json.loads(json.dumps(peers))
        for peer in updated.get('peers',[]):
            if peer.get('gre_if')==iface and str(peer.get('carrier','')).startswith('wss'):peer['carrier']='fou:'+str(fou)
        if updated!=peers:save(STATE/'peers.json',updated)
        result=subprocess.run([str(BIN/'NavaTunnel'),'retire-wss-carrier',iface,str(fou)],env=dict(os.environ,NAVATUNNEL_RETIRING_TOOLS='1'),capture_output=True,text=True,timeout=60)
        if result.returncode:
            if updated!=peers:save(STATE/'peers.json',peers)
            raise ValueError('Could not retire the active GRE WSS relay; private snapshot: '+str(archive))
        refreshed=load(STATE/'carrier.json',carrier)
        if str(refreshed.get('active_carrier','')).startswith('wss'):refreshed['active_carrier']='fou:'+str(fou)
        if str(refreshed.get('mode','')).startswith('wss'):refreshed['mode']='fou:'+str(fou)
        if 'candidates' in refreshed:refreshed['candidates']=[v for v in refreshed['candidates'] if not str(v).startswith('wss')]
        save(STATE/'carrier.json',refreshed)
        print('The removed GRE WSS carrier was changed to FOU on '+iface+'. Update the opposite endpoint too.')
    for unit_path in rescue_units:
        if unit_path.exists():run(['systemctl','disable','--now',unit_path.name])
    if any(p.exists() for p in rescue_units) or (STATE/'rescue.json').exists():
        if shutil.which('nft'):
            for table in ('navatunnel_rescue','navatunnel_dnat'):
                if run(['nft','list','table','inet',table],False).returncode==0:run(['nft','delete','table','inet',table])
    for p in existing:
        if p.exists():shutil.move(str(p),str(archive/p.name))
    for p in archive.rglob('*'):
        if not p.is_symlink():p.chmod(0o700 if p.is_dir() else 0o600)
    if old_auto:
        perf.pop('auto_pool',None);save(STATE/'perf.json',perf)
    if old_core:
        save(STATE/'core.json',{'port':core.get('port',47777)})
    if any(p.name.endswith('.service') for p in existing):run(['systemctl','daemon-reload'])
    print('Removed optional tools. Private settings archive: '+str(archive))


def main():
    if os.geteuid()!=0:raise ValueError('Run maintenance as root.')
    if sys.argv[1:]!=['retire']:raise ValueError('Usage: NavaTunnel-maintenance.sh retire')
    retire()
if __name__=='__main__':
    try:main()
    except (ValueError,OSError,subprocess.CalledProcessError,subprocess.TimeoutExpired) as error:
        print('Retirement failed: '+str(error),file=sys.stderr);sys.exit(1)
PY
