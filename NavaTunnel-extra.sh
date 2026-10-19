#!/usr/bin/env bash
# NavaTunnel SSH carrier, Cluster menu and owned-resource migrations.
# No HTTP panel, activation service or Backhaul runtime is used.
set -euo pipefail
export NAVATUNNEL_EXTRA_SOURCE="$0"
exec python3 - "$@" 3<&0 <<'PY'
import argparse, atexit, base64, fcntl, io, ipaddress, json, os, re, secrets, shlex, subprocess, sys, tarfile, tempfile, time
from pathlib import Path

STATE=Path('/etc/gre-panel')
UNITS=Path('/etc/systemd/system')
BIN=Path('/usr/local/bin')
FRP=Path('/etc/frp')
EXTRA=BIN/'NavaTunnel-extra.sh'
SOURCE=Path(os.environ.get('NAVATUNNEL_EXTRA_SOURCE',str(EXTRA)))
SSH_CONFIG=Path('/etc/ssh/sshd_config')
ROOT_KEYS=Path('/root/.ssh')
CARRIER_HOME=Path('/var/lib/navatunnel-ssh')
BACKUPS=Path('/var/backups/navatunnel')
SYSCTL=Path('/etc/sysctl.d')
SSH_SESSIONS={}


def run(args,check=True,input=None,timeout=40,capture=True):
    result=subprocess.run([str(a) for a in args],input=input,text=not isinstance(input,bytes),capture_output=capture,timeout=timeout)
    if check and result.returncode:raise ValueError('Command failed: '+str(args[0])+' (exit '+str(result.returncode)+'); inspect the corresponding service journal.')
    return result


def save(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,'w') as f:f.write(data if isinstance(data,str) else json.dumps(data,indent=2)+'\n');f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)


def load(path,default):return json.loads(path.read_text()) if path.exists() else default

def ipv4(value):return str(ipaddress.IPv4Address(value))

def port(value):
    value=int(value)
    if not 1<=value<=65535:raise ValueError('Ports must be between 1 and 65535.')
    return value


def ports(value):
    values=sorted({port(v.strip()) for v in value.replace(' ',',').split(',') if v.strip()})
    if not values or len(values)>128:raise ValueError('Enter 1-128 distinct service ports.')
    return values


def ident(value):
    if not re.fullmatch(r'[a-f0-9]{12}',value or ''):raise ValueError('Invalid NavaLink connection ID.')
    return value


def names(t):
    if t.get('mode')=='direct':return ['navalink-'+ident(t['id'])+'-ssh.service'] if t['role']=='iran' else []
    return ['navalink-'+ident(t['id'])+'-'+part+'.service' for part in (('server','ssh') if t['role']=='iran' else ('client',))]


def record(value):
    path=STATE/'navalink'/ident(value)/'config.json'
    if not path.exists():raise ValueError('NavaLink connection not found.')
    return path,load(path,{})


def records():return [load(p,{}) for p in sorted((STATE/'navalink').glob('*/config.json'))]


def keypair(path):
    path.parent.mkdir(parents=True,exist_ok=True);path.parent.chmod(0o700)
    if not path.exists():run(['ssh-keygen','-q','-t','ed25519','-N','','-f',path],capture=False)
    path.chmod(0o600)
    return path.with_suffix('.pub').read_text().strip()


def ensure_cores():
    run([BIN/'NavaTunnel','prepare-runtime'],capture=False,timeout=360)


def unit(name,command,after='network-online.target'):
    save(UNITS/name,'[Unit]\nDescription=NavaTunnel '+name+'\nAfter='+after+'\nWants=network-online.target\n\n[Service]\nType=simple\nExecStart='+shlex.join([str(x) for x in command])+'\nRestart=always\nRestartSec=5\nLimitNOFILE=1048576\n\n[Install]\nWantedBy=multi-user.target\n')


def power(t,action):
    for name in (list(reversed(names(t))) if action=='stop' else names(t)):
        if action=='stop':run(['systemctl','disable','--now',name])
        else:
            run(['systemctl','enable',name]);run(['systemctl',action,name]);run(['systemctl','is-active','--quiet',name])

    if action!='stop' and t['role']=='iran':
        for attempt in range(15):
            if (direct_ready(t) if t.get('mode')=='direct' else session_up('127.0.0.1',t['control_port'])):break
            time.sleep(1)
        else:raise ValueError('NavaLink service started, but no FRP control session appeared within 15 seconds. Inspect its SSH/client journals.')


def close_ssh_sessions():
    import shutil
    for (host,port_number),folder in SSH_SESSIONS.items():
        try:run(['ssh','-p',str(port_number),'-o','BatchMode=yes','-o','ControlPath='+folder+'/ssh','-O','exit','root@'+host],False,timeout=5)
        except (OSError,subprocess.TimeoutExpired):pass
        shutil.rmtree(folder,ignore_errors=True)


atexit.register(close_ssh_sessions)


def bootstrap(host,ssh_port,command):
    # Normal SSH host verification/password prompts; secrets are not saved.
    payload=io.BytesIO()
    with tarfile.open(fileobj=payload,mode='w:gz') as tar:
        for path in (SOURCE,BIN/'NavaTunnel.sh',BIN/'NavaTunnel-traffic.sh'):
            if not path.exists():raise ValueError('Update/install NavaTunnel locally before SSH provisioning.')
            tar.add(path,arcname='NavaTunnel-extra.sh' if path==SOURCE else path.name)
    script='set -e; umask 077; t=$(mktemp -d); trap \'rm -rf "$t"\' EXIT; tar -xzf - -C "$t"; test "$(id -u)" = 0; mkdir -p /usr/local/bin; install -m 755 "$t/NavaTunnel.sh" /usr/local/bin/NavaTunnel; install -m 755 "$t/NavaTunnel.sh" /usr/local/bin/NavaTunnel.sh; install -m 755 "$t/NavaTunnel-traffic.sh" /usr/local/bin/; install -m 755 "$t/NavaTunnel-extra.sh" /usr/local/bin/; /usr/local/bin/NavaTunnel prepare-runtime; /bin/bash /usr/local/bin/NavaTunnel-extra.sh '+shlex.join(command)
    host=ipv4(host);session=(host,int(ssh_port))
    if session not in SSH_SESSIONS:SSH_SESSIONS[session]=tempfile.mkdtemp(prefix='navatunnel-ssh-')
    run(['ssh','-T','-p',str(ssh_port),'-o','ControlMaster=auto','-o','ControlPersist=120','-o','ControlPath='+SSH_SESSIONS[session]+'/ssh','-o','StrictHostKeyChecking=ask','-o','UserKnownHostsFile='+str(STATE/'ssh-known-hosts'),'-o','ConnectTimeout=10','root@'+host,script],input=payload.getvalue(),capture=False,timeout=600)


def wire_counter(t,remove=False):
    name=t.get('counter') or 'navalink-'+t['id'];data=load(STATE/'traffic.json',{})
    if remove:
        if name in data:run(['bash',BIN/'NavaTunnel-traffic.sh','remove',name])
    elif name in data and data[name].get('peer')!=t['remote_host']:
        run(['bash',BIN/'NavaTunnel-traffic.sh','retarget',name,'--peer',t['remote_host']])
    elif name not in data:
        run(['bash',BIN/'NavaTunnel-traffic.sh','add',name,'--peer',t['remote_host']])
    run([BIN/'NavaTunnel','traffic','repair'],capture=False)


def check_ports(values,extra=()):
    rows=run(['ss','-H','-lntu']).stdout.splitlines()
    busy=set()
    for row in rows:
        fields=row.split()
        if len(fields)>=5:
            try:busy.add(int(fields[4].rsplit(':',1)[-1]))
            except ValueError:pass
    conflict=busy.intersection(set(values)|set(extra))
    if conflict:raise ValueError('Ports already in use: '+','.join(map(str,sorted(conflict)))+'. Existing tunnels are not replaced automatically.')


def nava_config(t):
    cp=t['control_port'];token=json.dumps(t['token'])
    if t['role']=='iran':
        return 'bindAddr = "127.0.0.1"\nbindPort = '+str(cp)+'\nproxyBindAddr = "0.0.0.0"\nauth.token = '+token+'\ntransport.tcpMux = false\ntransport.maxPoolCount = 2000\nallowPorts = ['+','.join('{start='+str(p)+',end='+str(p)+'}' for p in t['ports'])+']\n'
    lines=['serverAddr = "127.0.0.1"','serverPort = '+str(cp),'auth.token = '+token,'loginFailExit = false','transport.tls.enable = true','transport.tcpMux = false','transport.poolCount = '+str(t.get('pool_count',20))]
    retained=set()
    for block in t.get('proxy_sections','').split('[[proxies]]')[1:]:
        remote=re.search(r'^\s*remotePort\s*=\s*(\d+)',block,re.M)
        kind=re.search(r'^\s*type\s*=\s*"(tcp|udp)"',block,re.M)
        if remote and kind and int(remote[1]) in t['ports']:
            retained.add((int(remote[1]),kind[1]));lines+=['[[proxies]]',block.strip()]
    for p in t['ports']:
        for protocol in ('tcp','udp'):
            if (p,protocol) in retained:continue
            lines+=['[[proxies]]','name = "'+protocol+'_'+str(p)+'"','type = "'+protocol+'"','localIP = "127.0.0.1"','localPort = '+str(p),'remotePort = '+str(p)]
    return '\n'.join(lines)+'\n'


def direct_ready(t):
    listing=run(['ss','-H','-lnt']).stdout
    found=set()
    for row in listing.splitlines():
        fields=row.split()
        if len(fields)>=4:
            try:found.add(int(fields[-2].rsplit(':',1)[-1]))
            except ValueError:pass
    return set(t['ports']).issubset(found)


def ssh_carrier_command(t):
    path=STATE/'navalink'/t['id']
    command=['/usr/bin/ssh','-N','-T','-i',path/'key','-p',str(t['ssh_port']),'-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(STATE/'ssh-known-hosts'),'-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=10','-o','ServerAliveCountMax=3']
    if t.get('mode')=='direct':
        for p in t['ports']:command+=['-L','0.0.0.0:'+str(p)+':127.0.0.1:'+str(p)]
    else:command+=['-R','127.0.0.1:'+str(t['control_port'])+':127.0.0.1:'+str(t['control_port'])]
    return command+['nava'+t['id']+'@'+t['remote_host']]


def install_nava(t):
    path=STATE/'navalink'/t['id'];path.mkdir(parents=True,exist_ok=True);path.chmod(0o700);save(path/'config.json',t)
    if t.get('mode')=='direct':
        if t['role']=='iran':unit(names(t)[0],ssh_carrier_command(t))
    else:
        config=path/('frps.toml' if t['role']=='iran' else 'frpc.toml');save(config,nava_config(t))
        run([BIN/('frps' if t['role']=='iran' else 'frpc'),'verify','-c',config])
        if t['role']=='iran':
            unit(names(t)[0],[BIN/'frps','-c',config]);unit(names(t)[1],ssh_carrier_command(t),names(t)[0]+' network-online.target')
        else:unit(names(t)[0],[BIN/'frpc','-c',config])
    run(['systemctl','daemon-reload'])


def carrier_account(t,remove=False):
    import pwd
    user='nava'+ident(t['id']);home=CARRIER_HOME/t['id']
    config=SSH_CONFIG;before=config.read_text()
    start='# NavaTunnel '+t['id']+' begin';end='# NavaTunnel '+t['id']+' end'
    clean=re.sub(r'\n?'+re.escape(start)+r'\n.*?'+re.escape(end)+r'\n?','\n',before,flags=re.S)
    if remove:
        try:account=pwd.getpwnam(user)
        except KeyError:account=None
        if account and account.pw_dir==str(home):
            key=home/'.ssh/authorized_keys'
            if key.exists():key.unlink()
            run(['pkill','-u',str(account.pw_uid)],False)
            run(['userdel',user],False)
        updated=clean
    else:
        CARRIER_HOME.mkdir(mode=0o755,parents=True,exist_ok=True)
        try:
            account=pwd.getpwnam(user)
            if account.pw_dir!=str(home):raise ValueError('Carrier account name is already in use.')
        except KeyError:
            run(['useradd','--system','--create-home','--home-dir',home,'--shell','/usr/sbin/nologin',user],timeout=120);account=pwd.getpwnam(user)
            run(['usermod','--password','*',user])
        home.mkdir(parents=True,exist_ok=True);home.chmod(0o700);os.chown(home,account.pw_uid,account.pw_gid)
        folder=home/'.ssh';folder.mkdir(parents=True,exist_ok=True);folder.chmod(0o700);os.chown(folder,account.pw_uid,account.pw_gid)
        public=t['public_key']
        if not re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\n\r]*)?',public):raise ValueError('Invalid Ed25519 carrier key.')
        key=folder/'authorized_keys'
        if t.get('mode')=='direct':
            options=','.join('permitopen="127.0.0.1:'+str(p)+'"' for p in t['ports'])
            forwarding='local';listen='none';open_targets=' '.join('127.0.0.1:'+str(p) for p in t['ports'])
        else:
            options='permitlisten="127.0.0.1:'+str(t['control_port'])+'"';forwarding='remote';listen='127.0.0.1:'+str(t['control_port']);open_targets='none'
        save(key,'restrict,port-forwarding,'+options+',command="/bin/false" '+' '.join(public.split()[:2])+' navalink-'+t['id']+'\n');os.chown(key,account.pw_uid,account.pw_gid)
        updated=clean.rstrip()+'\n'+start+'\nMatch User '+user+'\n    AuthenticationMethods publickey\n    PasswordAuthentication no\n    AllowTcpForwarding '+forwarding+'\n    PermitListen '+listen+'\n    PermitOpen '+open_targets+'\n    AllowAgentForwarding no\n    X11Forwarding no\n    PermitTTY no\n    ForceCommand /bin/false\n'+end+'\n'
    save(config,updated)
    try:
        run(['/usr/sbin/sshd','-t','-f',config])
        if not remove:
            effective=run(['/usr/sbin/sshd','-T','-f',config,'-C','user='+user+',host=localhost,addr=127.0.0.1']).stdout
            if not re.search(r'^allowtcpforwarding '+forwarding+r'$',effective,re.M):raise ValueError('SSH configuration does not allow the restricted carrier account.')
        service='ssh' if run(['systemctl','is-active','--quiet','ssh'],False).returncode==0 else 'sshd'
        run(['systemctl','reload',service])
    except Exception:
        save(config,before)
        if not remove:
            key=home/'.ssh/authorized_keys'
            if key.exists():key.unlink()
        raise


def suspend_legacy(t,peer_id=None):
    import shutil
    previous=STATE/'navalink'/t['id']/'previous'
    if t['role']=='iran':
        registry=load(STATE/'peers.json',{'peers':[]})
        old=next((p for p in registry['peers'] if p['id']==int(peer_id)),None)
        if old is None or old.get('remote_pub')!=t['remote_host']:raise ValueError('Selected Iran tunnel does not match this foreign IP.')
        service=old['frps_svc'];iface=old['gre_if']
        if not re.fullmatch(r'frps(?:-[0-9]+)?',service) or not re.fullmatch(r'gre-(tunnel|t[0-9]+)',iface):raise ValueError('Invalid legacy service identity.')
        meta=dict(peer=old,role='iran')
    else:
        service='frpc';iface='gre-tunnel';meta=dict(role='foreign')
        unit_path=UNITS/(iface+'.service')
        match=re.search(r'\bremote\s+(\d+\.\d+\.\d+\.\d+)',unit_path.read_text()) if unit_path.exists() else None
        if not match or match[1]!=t['remote_host']:raise ValueError('The existing foreign GRE tunnel does not match this Iran IP.')
    if t['role']=='foreign':
        text=(FRP/'frpc.toml').read_text()
        if '[[proxies]]' in text:t['proxy_sections']='[[proxies]]'+text.split('[[proxies]]',1)[1]
    files=[('units',service+'.service'),('units',iface+'.service'),('frp',service+'.toml')]
    suffix='' if iface=='gre-tunnel' else '-'+iface[5:]
    if (UNITS/('gre-chaff'+suffix+'.service')).exists():files.append(('units','gre-chaff'+suffix+'.service'))
    meta['files']=files;meta['active']={name:run(['systemctl','is-active','--quiet',name],False).returncode==0 for kind,name in files if kind=='units'}
    traffic=load(STATE/'traffic.json',{})
    for name,counter in traffic.items():
        if counter.get('interface')==iface:
            t['counter']=name;t['previous_target']=dict(interface=iface);break
    t['legacy']=meta
    save(STATE/'navalink'/t['id']/'config.json',t)
    try:
        for name in meta['active']:run(['systemctl','disable','--now',name])
        for kind,name in files:
            source=(UNITS if kind=='units' else FRP)/name
            if source.exists():
                dest=previous/kind/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,dest);dest.chmod(0o600);source.unlink()
        if t['role']=='iran':
            registry['peers']=[p for p in registry['peers'] if p['id']!=int(peer_id)];save(STATE/'peers.json',registry)
        run(['systemctl','daemon-reload'])
    except Exception:
        resume_legacy(t);raise


def resume_legacy(t):
    import shutil
    meta=t.get('legacy')
    if not meta:return
    previous=STATE/'navalink'/t['id']/'previous'
    if meta['role']=='iran':
        registry=load(STATE/'peers.json',{'peers':[]});old=meta['peer']
        if any(p['id']!=old['id'] and (p.get('local_gre')==old.get('local_gre') or p.get('peer_gre')==old.get('peer_gre')) for p in registry['peers'] if old.get('local_gre') and old.get('peer_gre')):raise ValueError('Previous GRE addresses are in use; rollback requires manual conflict resolution.')
        same=next((p for p in registry['peers'] if p['id']==old['id']),None)
        if same and same!=old:raise ValueError('The previous tunnel ID has been reused; manual rollback is required.')
        if not same:registry['peers'].append(old);save(STATE/'peers.json',registry)
    for kind,name in meta['files']:
        source=previous/kind/name;dest=(UNITS if kind=='units' else FRP)/name
        if source.exists():shutil.copy2(source,dest);dest.chmod(0o600)
    run(['systemctl','daemon-reload'])
    # Recreate GRE before reopening the corresponding relay, while retaining manual stops.
    for name in sorted(meta['active'],key=lambda name:not name.startswith('gre-')):
        if meta['active'][name]:run(['systemctl','enable',name]);run(['systemctl','restart',name]);run(['systemctl','is-active','--quiet',name])
    if t.get('previous_target'):
        run(['bash',BIN/'NavaTunnel-traffic.sh','retarget',t['counter'],'--interface',t['previous_target']['interface']])


def navalink(args):
    if args.action=='setup':
        if not 2<=args.pool_count<=1000:raise ValueError('Pool count must be 2-1000.')
        if args.replace_peer is not None and args.replace_peer<1:raise ValueError('The existing tunnel ID must be positive.')
        if args.replace_peer and args.mode=='direct':raise ValueError('Direct SSH is TCP-only; create it separately with unused service ports. Use FRP mode to convert an existing tunnel.')
        if args.replace_peer:
            old=next((p for p in load(STATE/'peers.json',{}).get('peers',[]) if p['id']==args.replace_peer),None)
            if old is None:raise ValueError('Existing Iran tunnel ID not found.')
            args.host=args.host or old['remote_pub'];args.public_ip=args.public_ip or old['local_pub'];args.ports=args.ports or ','.join(map(str,old['ports']));args.name=args.name or old.get('name','')
        remote=ipv4(args.host);public=ipv4(args.public_ip);service_ports=ports(args.ports);ssh_port=port(args.ssh_port)
        if any(t.get('remote_host')==remote for t in records()):raise ValueError('A NavaLink connection to this peer already exists.')
        cp=port(args.control_port) if args.control_port else 40000+secrets.randbelow(15000)
        if cp<1024:raise ValueError('NavaLink control ports must be at least 1024.')
        if remote==public:raise ValueError('The Iran and foreign endpoints must differ.')
        if cp in service_ports:raise ValueError('Control and service ports must differ.')
        if not args.replace_peer:check_ports(service_ports,[cp])
        ensure_cores()
        number=secrets.token_hex(6);path=STATE/'navalink'/number
        public_key=keypair(path/'key')
        t=dict(mode=args.mode,pool_count=args.pool_count,id=number,name=args.name or 'NavaLink-'+remote,role='iran',local_pub=public,remote_host=remote,ssh_port=ssh_port,control_port=cp,ports=service_ports,token=secrets.token_hex(24),stopped=False)
        bundle=dict(t,public_key=public_key,replace_legacy=bool(args.replace_peer));bundle['role']='foreign';bundle['remote_host']=public
        encoded=base64.urlsafe_b64encode(json.dumps(bundle).encode()).decode()
        provisioning_started=False
        try:
            if args.replace_peer:suspend_legacy(t,args.replace_peer);check_ports(service_ports,[cp])
            wire_counter(t)
            # SSH provisioning also establishes the verified host key used by the carrier.
            provisioning_started=True
            bootstrap(remote,ssh_port,['navalink','join','--bundle',encoded])
            install_nava(t);power(t,'start')
        except Exception as error:
            # Keep any provisioned foreign state available for explicit cleanup, never claim success.
            for name in reversed(names(t)):run(['systemctl','stop',name],False)
            cleanup_failed=False
            if provisioning_started:
                try:bootstrap(remote,ssh_port,['navalink','remove','--id',number])
                except Exception:cleanup_failed=True
            if t.get('legacy'):resume_legacy(t)
            save(path/'config.json',dict(t,stopped=True,incomplete=True))
            print('Setup error: '+str(error),file=sys.stderr)
            if cleanup_failed:print('Automatic foreign rollback failed; run navalink remove --id '+number+' on that host.',file=sys.stderr)
            raise ValueError('NavaLink setup failed; connection ID '+number+'. The foreign side may need removal with navalink remove --id '+number+'. Existing GRE tunnels were not changed.')
        print('NavaLink installed on both ends: '+number+'. Check data forwarding before retiring any previous tunnel.')
    elif args.action=='join':
        try:t=json.loads(base64.b64decode(args.bundle,altchars=b'-_',validate=True))
        except (ValueError,TypeError):raise ValueError('Invalid NavaLink connection bundle.')
        if t.get('mode','frp') not in ('frp','direct') or not 2<=int(t.get('pool_count',20))<=1000:raise ValueError('Invalid connection mode or pool count.')
        ident(t.get('id'));t['remote_host']=ipv4(t['remote_host']);t['local_pub']=ipv4(t['local_pub']);t['control_port']=port(t['control_port']);t['ports']=ports(','.join(map(str,t['ports'])))
        if t['control_port']<1024 or t['control_port'] in t['ports']:raise ValueError('Invalid NavaLink control port.')
        if not re.fullmatch(r'[a-f0-9]{48}',t['token']) or t.get('role')!='foreign':raise ValueError('Invalid NavaLink token or role.')
        if (STATE/'navalink'/t['id']/'config.json').exists():raise ValueError('This connection already exists; remove it explicitly before joining again.')
        check_ports([], [t['control_port']]);ensure_cores()
        try:
            if t.get('replace_legacy'):
                if t.get('mode')=='direct':raise ValueError('Use a separate direct SSH connection; automatic conversion retains TCP/UDP and proxy options in FRP mode only.')
                suspend_legacy(t)
            install_nava(t);wire_counter(t);carrier_account(t);power(t,'start')
        except Exception:
            t['stopped']=True;t['incomplete']=True;save(STATE/'navalink'/t['id']/'config.json',t)
            for name in names(t):run(['systemctl','stop',name],False)
            if t.get('legacy'):resume_legacy(t)
            raise
        print('NavaLink foreign client ready. Its Iran server must establish the SSH carrier.')
    elif args.action=='restore':
        if records():ensure_cores()
        for t in records():
            install_nava(t);wire_counter(t)
            if t['role']=='foreign':carrier_account(t)
            if t['role']=='iran' and os.environ.get('NAVATUNNEL_DEFER_CARRIER')=='1' and not t.get('stopped'):
                t['handover_pending']=True;save(STATE/'navalink'/t['id']/'config.json',t)
                for name in reversed(names(t)):run(['systemctl','disable','--now',name],False)
                print('NavaLink '+t['id']+' prepared; waiting for the source carrier handover.')
            elif not t.get('stopped'):power(t,'start')
    elif args.action=='health':
        results=[]
        for t in records():
            active=not t.get('stopped') and all(run(['systemctl','is-active','--quiet',name],False).returncode==0 for name in names(t))
            results.append(dict(id=t['id'],healthy=active and (direct_ready(t) if t.get('mode')=='direct' and t['role']=='iran' else session_up('127.0.0.1',t['control_port']))))
        print(json.dumps(results))
    elif args.action=='status':
        for t in records():
            print(t['id']+' | '+t['name']+' | '+t['role']+' | '+t['remote_host'])
            for name in names(t):print('  '+name+': '+(run(['systemctl','is-active',name],False).stdout.strip() or 'unknown'))
            print('  Mode: '+t.get('mode','frp')+(' (TCP only)' if t.get('mode')=='direct' else ' | pool count: '+str(t.get('pool_count',20))))
            if t.get('mode')!='direct':print('  FRP control session: '+('connected' if session_up('127.0.0.1',t['control_port']) else 'not detected'))
            print('  Counter: '+(t.get('counter') or 'navalink-'+t['id'])+' (all IPv4 wire traffic to/from this peer; includes SSH overhead)')
    else:
        path,t=record(args.id)
        if args.action=='endpoint':
            host=ipv4(args.host)
            if t['role']=='iran':bootstrap(host,t['ssh_port'],['navalink','restore'])
            previous=dict(t)
            try:
                t['remote_host']=host;install_nava(t);wire_counter(t)
                if not t.get('stopped'):power(t,'restart')
            except Exception:
                install_nava(previous);wire_counter(previous)
                if not previous.get('stopped'):power(previous,'restart')
                raise
        elif args.action=='logs':run(['journalctl',*[v for name in names(t) for v in ('-u',name)],'-n','60','--no-pager'],capture=False)
        elif args.action=='remove':
            for name in reversed(names(t)):run(['systemctl','disable','--now',name],False)
            if t.get('legacy'):resume_legacy(t)
            else:wire_counter(t,True)
            for name in names(t):(UNITS/name).unlink(missing_ok=True)
            if t['role']=='foreign':carrier_account(t,True)
            # Keep a private removed snapshot; it is not enumerated as an active connection.
            path.rename(path.with_name('removed.json'));run(['systemctl','daemon-reload']);print('NavaLink removed locally; the previous GRE configuration was restored when available. Remove or revert the opposite end too.')
        else:
            power(t,args.action);t['stopped']=args.action=='stop';t['handover_pending']=False;save(path,t)


def session_up(address,control_port):
    for row in run(['ss','-Htn','state','established']).stdout.splitlines():
        fields=row.split()
        if len(fields)>=4 and any(re.search(r':'+str(control_port)+r'$',field) for field in fields[-2:]) and any(address in field.rsplit(':',1)[0] for field in fields[-2:]):return True
    return False



def cleanup_retired():
    # Migration only: remove the retired feature's own resources, never tunnel rules.
    keys=ROOT_KEYS/'authorized_keys'
    before=keys.read_text() if keys.exists() else ''
    lines=[line for line in before.splitlines() if not re.search(r' nava-cluster-[a-f0-9]{12}$',line)]
    after=before if lines==before.splitlines() else ('\n'.join(lines)+'\n' if lines else '')
    artifacts=[STATE/name for name in ('cluster.json','cluster-runtime.json','cluster-key','cluster-key.pub','cluster-tick.lock')]
    units=[UNITS/('NavaTunnel-cluster.'+suffix) for suffix in ('timer','service')]
    if not any(p.exists() for p in artifacts+units) and after==before:return
    for path in units:
        if path.exists():run(['systemctl','disable','--now',path.name])
    # Wait for any old timer invocation before deleting its state.
    with open(STATE/'cluster-tick.lock','a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        mark='0x4e560000/0xffff0000'
        for table,chain,rule in [('nat','POSTROUTING',['-m','connmark','--mark',mark,'-m','conntrack','--ctstate','DNAT','-j','MASQUERADE']),('filter','FORWARD',['-m','connmark','--mark',mark,'-m','conntrack','--ctstate','DNAT','-j','ACCEPT'])]:
            listing=run(['iptables','-w','5','-t',table,'-S',chain])
            for line in listing.stdout.splitlines():
                words=shlex.split(line)
                if words==['-A',chain,*rule]:run(['iptables','-w','5','-t',table,'-D',chain,*rule])
        listing=run(['iptables','-w','5','-t','nat','-S','PREROUTING'])
        for line in listing.stdout.splitlines():
            words=shlex.split(line)
            if words[:2]==['-A','PREROUTING'] and '--comment' in words and '-j' in words and words[words.index('--comment')+1]=='navatunnel-cluster' and words[words.index('-j')+1]=='NAVA-CLUSTER':
                run(['iptables','-w','5','-t','nat','-D',*words[1:]])
        if run(['iptables','-w','5','-t','nat','-S','NAVA-CLUSTER'],False).returncode==0:
            run(['iptables','-w','5','-t','nat','-F','NAVA-CLUSTER'])
            run(['iptables','-w','5','-t','nat','-X','NAVA-CLUSTER'])
        if after!=before:save(keys,after)
        for path in artifacts+units:path.unlink(missing_ok=True)
    run(['systemctl','daemon-reload'])
    print('Retired Cluster services, owned firewall rules and health keys removed. Tunnels were preserved.')





def cleanup_extra_tools():
    # This migration only retires the optional tools removed after 1.1.0.
    # Cluster, NavaLink, FRP, quota counters and normal watchdog settings are retained.
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
        fou=port(carrier.get('fou_port1',443))
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
    core_unit=UNITS/'NavaTunnel-core.service'
    if core_unit.exists() and run(['systemctl','is-active','--quiet',core_unit.name],False).returncode==0:
        try:
            observed=run([BIN/'NavaTunnel-core','daemon','ping'],False)
            version=json.loads(observed.stdout or '{}').get('version','')
        except (ValueError,OSError,subprocess.TimeoutExpired):version=''
        if version in ('','v1.1.0'):
            save(STATE/'core-restart-required','Restart the retained Cluster core after migration.\n')
            run(['systemctl','stop',core_unit.name])
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


def core_call(family,action='status',body=None,query='',secrets=False):
    args=[BIN/'NavaTunnel','advanced',family,action,'--json',json.dumps(body or {})]
    if query:args+=['--query',query]
    if secrets:args+=['--show-secrets']
    run(args,capture=False,timeout=240)


def core_start(listen=None):
    args=[BIN/'NavaTunnel','core-service','start']
    if listen:args+=['--listen',listen]
    run(args,capture=False,timeout=240)


def ask_bool(prompt,default=False):
    value=input(prompt+(' [Y/n]: ' if default else ' [y/N]: ')).strip().lower()
    if value in ('y','yes'):return True
    if value in ('n','no'):return False
    if not value:return default
    raise ValueError('Enter y or n.')


def cluster_menu_action(choice):
    if choice=='1':core_call('cluster');return
    if choice=='2':
        ps=ports(input('Public entry service ports (443,8443): '));mode=input('Mode [wrr / failover / lowest_latency]: ').strip() or 'failover'
        core_call('cluster','config',dict(service_ports=ps,balancing_mode=mode));return
    if choice=='3':
        peers=load(STATE/'peers.json',{}).get('peers',[])
        for p in peers:print(str(p['id'])+') '+p.get('name','')+' | '+p.get('remote_pub','')+' | GRE '+p.get('peer_gre',''))
        selected=int(input('Existing GRE tunnel ID: '));p=next((p for p in peers if p['id']==selected),None)
        if p is None:raise ValueError('Tunnel not found.')
        print('This routes to the foreign inbound over its GRE address. Exits need compatible users and inbounds.')
        probe=port(input('TCP health-check port on the foreign service: '))
        core_call('cluster','add-foreign',dict(id='peer-'+str(selected),name=p.get('name',''),public_ip=p['peer_gre'],tunnel_port=probe,protocol='gre',weight=int(input('Weight [1]: ') or '1')));return
    if choice=='4':
        number=input('Unique exit ID: ').strip();name=input('Exit name: ').strip();host=ipv4(input('Reachable destination IPv4 (GRE inner or public): ').strip());probe=port(input('TCP health-check port ON the destination: '));weight=int(input('Weight [1]: ') or '1');mapping={}
        text=input('Optional entry:destination port mappings (443:8443,2083:2083): ').strip()
        if text:
            for pair in text.split(','):
                a,b=pair.split(':');mapping[port(a)]=port(b)
        core_call('cluster','add-foreign',dict(id=number,name=name,public_ip=host,tunnel_port=probe,protocol='tcp',weight=weight,target_ports=mapping));return
    if choice in ('5','6','9'):
        core_call('cluster');target=input('Node ID: ').strip();action={'5':'del-foreign','6':'switch-foreign','9':'del-iran'}[choice];key='target_id' if choice=='6' else 'id';core_call('cluster',action,{key:target});return
    if choice=='7':
        print('Each Iran node needs its own working exit path. Set the SAME secret on every trusted Iran node.')
        public=ipv4(input('This Iran public IPv4: ').strip());node=input('This Iran node ID: ').strip();secret=input('Shared cluster secret [Enter: generate]: ').strip() or secrets.token_hex(32)
        core_call('cluster','config',dict(node_id=node,public_ip=public,cluster_secret=secret,auto_failover=True));print('Shared cluster secret (private): '+secret);return
    if choice=='8':
        number=input('Other Iran node ID: ').strip();host=ipv4(input('Other Iran public IPv4: ').strip());url=input('Other Iran peer API URL (https://IP:47777): ').strip();pin=input('Its TLS SHA256 fingerprint (from that server): ').strip().replace(':','')
        core_call('cluster','add-iran',dict(id=number,name=number,public_ip=host,api_url=url,tls_fingerprint=pin));return
    if choice=='10':
        if ask_bool('Enable routing for the configured service ports?'):
            core_start();core_call('cluster','config',dict(enabled=True))
        return
    if choice=='11':core_call('cluster','config',dict(enabled=False));return
    if choice=='12':
        listen=input('Peer API bind IPv4:port [0.0.0.0:47777]: ').strip() or '0.0.0.0:47777';core_start(listen);core_call('certificate');return
    if choice=='13':core_call('cluster','revert');return
    raise ValueError('Invalid option.')




def menu_cluster():
    while True:
        print('\033[2J\033[HCluster\n1) Status\n2) Set entry ports and balancing mode\n3) Add an existing GRE exit\n4) Add an exit address and port mapping\n5) Remove exit\n6) Select preferred exit\n7) Configure this Iran identity and shared secret\n8) Add an Iran mesh peer\n9) Remove Iran mesh peer\n10) Enable Cluster routing\n11) Disable Cluster routing\n12) Enable TLS listener / show certificate fingerprint\n13) Revert current failover\n0) Back')
        choice=input('Select: ').strip()
        if choice=='0':return
        try:cluster_menu_action(choice)
        except (ValueError,TypeError,KeyError,OSError,subprocess.TimeoutExpired) as error:print('Operation failed: '+str(error))
        input('Press Enter to return...')


def menu(family):
    if family=='cluster':return menu_cluster()
    while True:
        print('\033[2J\033[H',end='')
        print('NavaLink — FRP over reverse SSH (no GRE / no Backhaul)\n1) Set up both ends over SSH\n2) Status\n3) Start\n4) Stop\n5) Restart\n6) Remove local connection\n7) Change peer public IP\n8) Logs\n0) Back')
        choice=input('Select: ').strip()
        if choice=='0':return
        if choice=='1':
            mode=input('Mode [frp / direct (TCP only), default frp]: ').strip() or 'frp'
            pool=input('FRP pool count [20]: ').strip() or '20'
            peers=load(STATE/'peers.json',{}).get('peers',[])
            for p in peers:print('GRE tunnel '+str(p['id'])+': '+p.get('name','')+' | '+p.get('remote_pub',''))
            replace=input('Existing Iran tunnel ID to convert [Enter: create separately]: ').strip()
            if replace:
                args=['navalink','setup','--replace-peer',replace,'--ssh-port',input('Foreign root SSH port [22]: ').strip() or '22']
            else:
                args=['navalink','setup','--host',input('Foreign root SSH IPv4: ').strip(),'--public-ip',input('Iran public IPv4: ').strip(),'--ssh-port',input('Foreign root SSH port [22]: ').strip() or '22','--ports',input('New service ports: ').strip(),'--name',input('Connection name: ').strip()]
            args+=['--mode',mode,'--pool-count',pool]
        elif choice=='2':args=['navalink','status']
        elif choice=='7':args=['navalink','endpoint','--id',input('Connection ID: ').strip(),'--host',input('New peer public IPv4: ').strip()]
        elif choice=='8':args=['navalink','logs','--id',input('Connection ID: ').strip()]
        elif choice in ('3','4','5','6'):args=['navalink',dict({'3':'start','4':'stop','5':'restart','6':'remove'})[choice],'--id',input('Connection ID: ').strip()]
        else:continue
        try:invoke(args)
        except (ValueError,OSError,subprocess.TimeoutExpired) as e:print('Operation failed: '+str(e))
        input('Press Enter to return...')


def invoke(argv):
    parser=argparse.ArgumentParser(description='NavaTunnel Cluster and NavaLink')
    subs=parser.add_subparsers(dest='family',required=True)
    n=subs.add_parser('navalink');n.add_argument('action',choices=('setup','join','status','health','restore','start','stop','restart','remove','endpoint','logs'));n.add_argument('--mode',choices=('frp','direct'),default='frp');n.add_argument('--pool-count',type=int,default=20);n.add_argument('--replace-peer',type=int);n.add_argument('--host');n.add_argument('--public-ip');n.add_argument('--ssh-port',default=22,type=int);n.add_argument('--ports');n.add_argument('--control-port',type=int);n.add_argument('--name',default='');n.add_argument('--bundle');n.add_argument('--id')
    subs.add_parser('cleanup-retired')
    subs.add_parser('cleanup-extra-tools')
    ui=subs.add_parser('menu');ui.add_argument('page',choices=('navalink','cluster'))
    args=parser.parse_args(argv)
    if os.geteuid()!=0:raise ValueError('Run as root.')
    STATE.mkdir(parents=True,exist_ok=True)
    if args.family=='menu':menu(args.page)
    elif args.family=='navalink':navalink(args)
    elif args.family=='cleanup-retired':cleanup_retired()
    elif args.family=='cleanup-extra-tools':cleanup_extra_tools()


if __name__=='__main__':
    # The heredoc supplies code; fd 3 retains the caller's interactive input.
    os.dup2(3,0);os.close(3)
    sys.stdin=open(0)
    try:invoke(sys.argv[1:])
    except (ValueError,TypeError,KeyError,OSError,EOFError,subprocess.TimeoutExpired) as error:
        print('NavaTunnel operation failed: '+str(error),file=sys.stderr);sys.exit(1)
PY
