#!/usr/bin/env bash
# Independent optional NavaTunnel engines and SSH-managed clustering.
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
MARK='0x4e560000/0xffff0000'
BOOT=Path('/proc/sys/kernel/random/boot_id').read_text().strip()
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


def names(t):return ['navalink-'+ident(t['id'])+'-'+part+'.service' for part in (('server','ssh') if t['role']=='iran' else ('client',))]


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
            if session_up('127.0.0.1',t['control_port']):break
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
        return 'bindAddr = "127.0.0.1"\nbindPort = '+str(cp)+'\nproxyBindAddr = "0.0.0.0"\nauth.token = '+token+'\ntransport.tcpMux = false\nallowPorts = ['+','.join('{start='+str(p)+',end='+str(p)+'}' for p in t['ports'])+']\n'
    lines=['serverAddr = "127.0.0.1"','serverPort = '+str(cp),'auth.token = '+token,'loginFailExit = false','transport.tls.enable = true','transport.tcpMux = false','transport.poolCount = 20']
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


def install_nava(t):
    path=STATE/'navalink'/t['id'];path.mkdir(parents=True,exist_ok=True);path.chmod(0o700)
    config=path/('frps.toml' if t['role']=='iran' else 'frpc.toml');save(config,nava_config(t));save(path/'config.json',t)
    run([BIN/('frps' if t['role']=='iran' else 'frpc'),'verify','-c',config])
    if t['role']=='iran':
        unit(names(t)[0],[BIN/'frps','-c',config])
        unit(names(t)[1],['/usr/bin/ssh','-N','-T','-i',path/'key','-p',str(t['ssh_port']),'-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(STATE/'ssh-known-hosts'),'-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=10','-o','ServerAliveCountMax=3','-R','127.0.0.1:'+str(t['control_port'])+':127.0.0.1:'+str(t['control_port']),'nava'+t['id']+'@'+t['remote_host']],names(t)[0]+' network-online.target')
    else:unit(names(t)[0],[BIN/'frpc','-c',config])
    run(['systemctl','daemon-reload'])


def authorize(public_key,tag,options):
    if not re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\n\r]*)?',public_key):raise ValueError('Invalid Ed25519 public key.')
    folder=ROOT_KEYS;folder.mkdir(mode=0o700,exist_ok=True);folder.chmod(0o700)
    path=folder/'authorized_keys';text=path.read_text() if path.exists() else ''
    lines=[line for line in text.splitlines() if not line.endswith(' '+tag)]
    lines.append(options+' '+public_key.split()[0]+' '+public_key.split()[1]+' '+tag)
    save(path,'\n'.join(lines)+'\n')


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
        save(key,'restrict,port-forwarding,permitlisten="127.0.0.1:'+str(t['control_port'])+'",command="/bin/false" '+' '.join(public.split()[:2])+' navalink-'+t['id']+'\n');os.chown(key,account.pw_uid,account.pw_gid)
        updated=clean.rstrip()+'\n'+start+'\nMatch User '+user+'\n    AuthenticationMethods publickey\n    PasswordAuthentication no\n    AllowTcpForwarding remote\n    PermitListen 127.0.0.1:'+str(t['control_port'])+'\n    PermitOpen none\n    AllowAgentForwarding no\n    X11Forwarding no\n    PermitTTY no\n    ForceCommand /bin/false\n'+end+'\n'
    save(config,updated)
    try:
        run(['/usr/sbin/sshd','-t','-f',config])
        if not remove:
            effective=run(['/usr/sbin/sshd','-T','-f',config,'-C','user='+user+',host=localhost,addr=127.0.0.1']).stdout
            if not re.search(r'^allowtcpforwarding remote$',effective,re.M):raise ValueError('SSH configuration does not allow the restricted carrier account.')
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
        if args.replace_peer is not None and args.replace_peer<1:raise ValueError('The existing tunnel ID must be positive.')
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
        t=dict(id=number,name=args.name or 'NavaLink-'+remote,role='iran',local_pub=public,remote_host=remote,ssh_port=ssh_port,control_port=cp,ports=service_ports,token=secrets.token_hex(24),stopped=False)
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
        ident(t.get('id'));t['remote_host']=ipv4(t['remote_host']);t['local_pub']=ipv4(t['local_pub']);t['control_port']=port(t['control_port']);t['ports']=ports(','.join(map(str,t['ports'])))
        if t['control_port']<1024 or t['control_port'] in t['ports']:raise ValueError('Invalid NavaLink control port.')
        if not re.fullmatch(r'[a-f0-9]{48}',t['token']) or t.get('role')!='foreign':raise ValueError('Invalid NavaLink token or role.')
        if (STATE/'navalink'/t['id']/'config.json').exists():raise ValueError('This connection already exists; remove it explicitly before joining again.')
        check_ports([], [t['control_port']]);ensure_cores()
        try:
            if t.get('replace_legacy'):suspend_legacy(t)
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
            results.append(dict(id=t['id'],healthy=active and session_up('127.0.0.1',t['control_port'])))
        print(json.dumps(results))
    elif args.action=='status':
        for t in records():
            print(t['id']+' | '+t['name']+' | '+t['role']+' | '+t['remote_host'])
            for name in names(t):print('  '+name+': '+(run(['systemctl','is-active',name],False).stdout.strip() or 'unknown'))
            print('  FRP control session: '+('connected' if session_up('127.0.0.1',t['control_port']) else 'not detected'))
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


def local_health():
    observations=[];healthy_ports=set()
    for t in records():
        if t.get('role')=='iran' and not t.get('stopped'):
            good=all(run(['systemctl','is-active','--quiet',name],False).returncode==0 for name in names(t)) and session_up('127.0.0.1',t['control_port'])
            observations.append(good)
            if good:healthy_ports.update(t['ports'])
    for p in load(STATE/'peers.json',{}).get('peers',[]):
        if (STATE/'stopped'/p.get('gre_if','')).is_file():continue
        if p.get('peer_gre') and p.get('frp_port'):
            good=run(['systemctl','is-active','--quiet',p.get('frps_svc','frps')],False).returncode==0 and session_up(p['peer_gre'],p['frp_port'])
            observations.append(good)
            if good:healthy_ports.update(p.get('ports',[]))
    return dict(healthy=bool(observations) and any(observations),links=len(observations),healthy_links=sum(observations),ports=sorted(healthy_ports),timestamp=int(time.time()))


def cluster_rules(targets):
    lines=['*nat',':NAVA-CLUSTER - [0:0]']
    if targets:
        lines+=['-A NAVA-CLUSTER -j CONNMARK --set-xmark '+MARK]
        remaining=sum(t['weight'] for t in targets)
        for i,t in enumerate(targets):
            match='' if i==len(targets)-1 else ' -m statistic --mode random --probability '+format(t['weight']/remaining,'.10f')
            action='RETURN' if t['host']=='local' else 'DNAT --to-destination '+ipv4(t['host'])
            lines+=['-A NAVA-CLUSTER'+match+' -j '+action];remaining-=t['weight']
    return '\n'.join(lines+['COMMIT',''])


def cluster_firewall(config,targets):
    # Only the declared chain is replaced. Other NAT rules and conntrack entries survive.
    run(['iptables-restore','--noflush','-w','5'],input=cluster_rules(targets))
    for proto in ('tcp','udp'):
        for p in config['ports']:
            rule=['-p',proto,'--dport',str(p),'-m','addrtype','--dst-type','LOCAL','-m','comment','--comment','navatunnel-cluster','-j','NAVA-CLUSTER']
            if run(['iptables','-w','5','-t','nat','-C','PREROUTING',*rule],False).returncode:run(['iptables','-w','5','-t','nat','-I','PREROUTING','1',*rule])
    for table,chain,rule in [('nat','POSTROUTING',['-m','connmark','--mark',MARK,'-m','conntrack','--ctstate','DNAT','-j','MASQUERADE']),('filter','FORWARD',['-m','connmark','--mark',MARK,'-m','conntrack','--ctstate','DNAT','-j','ACCEPT'])]:
        if run(['iptables','-w','5','-t',table,'-C',chain,*rule],False).returncode:run(['iptables','-w','5','-t',table,'-I',chain,'1',*rule])
    run(['sysctl','-w','net.ipv4.ip_forward=1'])


def cluster_clear(config):
    # Restore local forwarding first; leave no active DNAT in our chain.
    if run(['iptables','-w','5','-t','nat','-S','NAVA-CLUSTER'],False).returncode==0:run(['iptables-restore','--noflush','-w','5'],input=cluster_rules([]))
    for proto in ('tcp','udp'):
        for p in config['ports']:
            rule=['-p',proto,'--dport',str(p),'-m','addrtype','--dst-type','LOCAL','-m','comment','--comment','navatunnel-cluster','-j','NAVA-CLUSTER']
            if run(['iptables','-w','5','-t','nat','-C','PREROUTING',*rule],False).returncode==0:run(['iptables','-w','5','-t','nat','-D','PREROUTING',*rule])
    for table,chain,rule in [('nat','POSTROUTING',['-m','connmark','--mark',MARK,'-m','conntrack','--ctstate','DNAT','-j','MASQUERADE']),('filter','FORWARD',['-m','connmark','--mark',MARK,'-m','conntrack','--ctstate','DNAT','-j','ACCEPT'])]:
        if run(['iptables','-w','5','-t',table,'-C',chain,*rule],False).returncode==0:run(['iptables','-w','5','-t',table,'-D',chain,*rule])


def debounced(previous,success,failures,recoveries,initial=False):
    value=dict(previous or dict(healthy=initial,up=0,down=0))
    value['up']=value.get('up',0)+1 if success else 0;value['down']=value.get('down',0)+1 if not success else 0
    if value['down']>=failures:value['healthy']=False
    if value['up']>=recoveries:value['healthy']=True
    return value


def choose_targets(config,health):
    local=health.get('local',{}).get('healthy',True)
    available=[dict(host=n['host'],weight=n['weight']) for n in config['nodes'] if health.get(n['host'],{}).get('healthy')]
    if config['mode']=='failover':return [] if local else available[:1]
    if config['mode']=='lowest-latency':
        if local:return []
        return sorted(available,key=lambda t:health[t['host']].get('latency_ms',1e9))[:1]
    return ([dict(host='local',weight=config['local_weight'])] if local else [])+available


def cluster(args):
    path=STATE/'cluster.json';cfg=load(path,dict(enabled=False,ports=[],mode='failover',nodes=[],failures=3,recoveries=3,local_weight=1))
    if args.action=='health':print(json.dumps(local_health()));return
    if args.action=='init':
        if cfg['enabled']:raise ValueError('Disable the cluster before changing its service ports or mode.')
        cfg.update(ports=ports(args.ports),mode=args.mode,failures=args.failures,recoveries=args.recoveries,local_weight=args.weight)
        if not 1<=cfg['failures']<=30 or not 1<=cfg['recoveries']<=30 or not 1<=args.weight<=100:raise ValueError('Invalid debounce thresholds or weight.')
        save(path,cfg);print('Cluster configured, disabled by default. Add healthy Iran peers before enabling.')
    elif args.action=='trust':
        # Provision only a forced read-only health key; no remote forwarding or shell access.
        public=keypair(STATE/'cluster-key')
        host=ipv4(args.host);ssh_port=port(args.ssh_port)
        encoded=base64.urlsafe_b64encode(public.encode()).decode()
        bootstrap(host,ssh_port,['cluster','accept-key','--bundle',encoded]);print('Cluster read-only SSH health key installed.')
    elif args.action=='accept-key':
        public=base64.b64decode(args.bundle,altchars=b'-_',validate=True).decode()
        fingerprint=__import__('hashlib').sha256(public.encode()).hexdigest()[:12]
        authorize(public,'nava-cluster-'+fingerprint,'restrict,command="/bin/bash /usr/local/bin/NavaTunnel-extra.sh cluster health"')
    elif args.action=='add':
        host=ipv4(args.host);ssh_port=port(args.ssh_port)
        if not 1<=args.weight<=100:raise ValueError('Weight must be between 1 and 100.')
        local_ips={p.get('local_pub') for p in load(STATE/'peers.json',{}).get('peers',[])}
        for entry in json.loads(run(['ip','-j','-4','addr','show']).stdout):
            local_ips.update(a.get('local') for a in entry.get('addr_info',[]))
        if host in local_ips:raise ValueError('A cluster peer must not point to this server itself.')
        if any(n['host']==host for n in cfg['nodes']):raise ValueError('Cluster node already exists.')
        cfg['nodes'].append(dict(host=host,ssh_port=ssh_port,weight=args.weight));save(path,cfg)
    elif args.action=='remove':
        cfg['nodes']=[n for n in cfg['nodes'] if n['host']!=ipv4(args.host)];save(path,cfg)
    elif args.action=='restore':
        if cfg.get('enabled'):
            save(STATE/'cluster-runtime.json',{})
            args.action='enable';cluster(args)
    elif args.action=='enable':
        if not cfg['ports'] or not cfg['nodes'] or not (STATE/'cluster-key').exists():raise ValueError('Initialize cluster service ports and trust/add peers first.')
        cfg['enabled']=True;save(path,cfg)
        save(UNITS/'NavaTunnel-cluster.service','[Unit]\nDescription=NavaTunnel cluster monitor\nAfter=network-online.target\n\n[Service]\nType=oneshot\nExecStart=/bin/bash '+str(EXTRA)+' cluster tick\n')
        save(UNITS/'NavaTunnel-cluster.timer','[Unit]\nDescription=NavaTunnel cluster interval\n\n[Timer]\nOnBootSec=10\nOnUnitActiveSec=10\nUnit=NavaTunnel-cluster.service\n\n[Install]\nWantedBy=timers.target\n')
        run(['systemctl','daemon-reload']);run(['systemctl','enable','--now','NavaTunnel-cluster.timer']);print('Cluster monitor enabled; new connections are rerouted only after health thresholds are met.')
    elif args.action=='purge':
        key=ROOT_KEYS/'authorized_keys'
        if key.exists():save(key,'\n'.join(line for line in key.read_text().splitlines() if not re.search(r' nava-cluster-[a-f0-9]{12}$',line))+'\n')
    elif args.action=='disable':
        run(['systemctl','disable','--now','NavaTunnel-cluster.timer'],False);cluster_clear(cfg);cfg['enabled']=False;save(path,cfg);save(STATE/'cluster-runtime.json',{})
    elif args.action=='status':
        safe=dict(cfg,runtime=load(STATE/'cluster-runtime.json',{}));print(json.dumps(safe,indent=2))
    elif args.action=='tick':
        if not cfg['enabled']:return
        with open(STATE/'cluster-tick.lock','a') as lock:
            try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:return
            runtime=load(STATE/'cluster-runtime.json',{});health=runtime.get('health',{})
            local=local_health()
            local_good=local['healthy'] and set(cfg['ports']).issubset(set(local.get('ports',[])))
            health['local']=debounced(health.get('local'),local_good,cfg['failures'],cfg['recoveries'],True)
            for node in cfg['nodes']:
                begin=time.monotonic();good=False
                try:
                    result=run(['ssh','-T','-i',STATE/'cluster-key','-p',str(node['ssh_port']),'-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(STATE/'ssh-known-hosts'),'-o','ConnectTimeout=3','root@'+node['host'],'health'],timeout=6)
                    reply=json.loads(result.stdout);good=reply.get('healthy') is True and set(cfg['ports']).issubset(set(reply.get('ports',[]))) and abs(time.time()-int(reply.get('timestamp',0)))<120
                except (ValueError,TypeError,subprocess.TimeoutExpired,OSError):pass
                value=debounced(health.get(node['host']),good,cfg['failures'],cfg['recoveries']);value['latency_ms']=round((time.monotonic()-begin)*1000,2);health[node['host']]=value
            targets=choose_targets(cfg,health)
            if targets!=runtime.get('targets',[]) or runtime.get('boot')!=BOOT:
                try:cluster_firewall(cfg,targets)
                except Exception:
                    cluster_firewall(cfg,runtime.get('targets',[]));raise
            save(STATE/'cluster-runtime.json',dict(health=health,targets=targets,boot=BOOT,updated=int(time.time())))


def nettools(args):
    if args.family=='tcp-mux':
        if args.action=='status':
            for path in sorted(FRP.glob('frp*.toml')):
                match=re.search(r'^transport\.tcpMux\s*=\s*(true|false)',path.read_text(),re.M);print(path.name+': '+(match[1] if match else 'default'))
            return
        enabled=args.action=='on'
        for path in sorted(FRP.glob('frp*.toml')):
            old=path.read_text();head,sep,tail=old.partition('[[proxies]]');line='transport.tcpMux = '+str(enabled).lower()
            head=re.sub(r'^transport\.tcpMux\s*=.*$',line,head,flags=re.M) if re.search(r'^transport\.tcpMux\s*=',head,re.M) else line+'\n'+head
            save(path,head+sep+tail)
        perf=load(STATE/'perf.json',{});perf['tcp_mux']=enabled;save(STATE/'perf.json',perf)
        print('tcpMux saved. Set the SAME value on both ends, then restart only the corresponding tunnel when ready. NavaLink retains its own tcpMux=false configuration.')
    elif args.family=='path-mtu':
        iface=args.interface;peer=ipv4(args.peer)
        if not re.fullmatch(r'gre-(tunnel|t[0-9]+)',iface):raise ValueError('Invalid GRE interface.')
        link=json.loads(run(['ip','-j','link','show',iface]).stdout);upper=min(int(link[0]['mtu']),1476)
        def probe(mtu):return run(['ping','-n','-I',iface,'-M','do','-c','3','-W','1','-s',str(mtu-28),peer],False,timeout=6).returncode==0
        if not probe(576):raise ValueError('No reliable ICMP response even at MTU 576; no MTU change was made.')
        low,high=576,upper
        while low<high:
            middle=(low+high+1)//2
            if probe(middle):low=middle
            else:high=middle-1
        if not probe(low):raise ValueError('Probe was unstable; no MTU change was made.')
        print('Largest confirmed inner MTU in this test: '+str(low)+'. Loss or ICMP filtering can affect this result.')
        if args.apply:run([BIN/'NavaTunnel','mtu','--interface',iface,'--value',str(low)],capture=False);print('Apply the same MTU on the matching opposite tunnel.')
    elif args.family=='pool':
        # Advisor only: pool-full messages alone do not prove user connections failed.
        text=run(['journalctl','-u','frpc','--since','15 minutes ago','--no-pager','-n','500'],False).stdout
        errors=text.count('work connection pool is full')
        print('Pool-full log messages (last 15 minutes, at most 500 lines): '+str(errors))
        print('No automatic restart or pool change is performed. These messages alone do not prove capacity exhaustion.')
        for path in sorted(FRP.glob('frp*.toml')):
            for key in ('poolCount','maxPoolCount'):
                match=re.search(r'^transport\.'+key+r'\s*=\s*(\d+)',path.read_text(),re.M)
                if match:print(path.name+': '+key+'='+match[1])


def menu(family):
    while True:
        print('\033[2J\033[H',end='')
        if family=='navalink':
            print('NavaLink — FRP over reverse SSH (no GRE / no Backhaul)\n1) Set up both ends over SSH\n2) Status\n3) Start\n4) Stop\n5) Restart\n6) Remove local connection\n7) Change peer public IP\n8) Logs\n0) Back')
            choice=input('Select: ').strip()
            if choice=='0':return
            if choice=='1':
                peers=load(STATE/'peers.json',{}).get('peers',[])
                for p in peers:print('GRE tunnel '+str(p['id'])+': '+p.get('name','')+' | '+p.get('remote_pub',''))
                replace=input('Existing Iran tunnel ID to convert [Enter: create separately]: ').strip()
                if replace:
                    args=['navalink','setup','--replace-peer',replace,'--ssh-port',input('Foreign root SSH port [22]: ').strip() or '22']
                else:
                    args=['navalink','setup','--host',input('Foreign root SSH IPv4: ').strip(),'--public-ip',input('Iran public IPv4: ').strip(),'--ssh-port',input('Foreign root SSH port [22]: ').strip() or '22','--ports',input('New service ports: ').strip(),'--name',input('Connection name: ').strip()]
            elif choice=='2':args=['navalink','status']
            elif choice=='7':args=['navalink','endpoint','--id',input('Connection ID: ').strip(),'--host',input('New peer public IPv4: ').strip()]
            elif choice=='8':args=['navalink','logs','--id',input('Connection ID: ').strip()]
            elif choice in ('3','4','5','6'):args=['navalink',dict({'3':'start','4':'stop','5':'restart','6':'remove'})[choice],'--id',input('Connection ID: ').strip()]
            else:continue
        elif family=='cluster':
            print('SSH cluster — other Iran servers; no web API\n1) Configure (disabled by default)\n2) Trust and add Iran peer\n3) Status\n4) Enable monitor\n5) Disable / restore local route\n6) Remove peer\n0) Back')
            choice=input('Select: ').strip()
            if choice=='0':return
            if choice=='1':args=['cluster','init','--ports',input('Public service ports: ').strip(),'--mode',input('Mode [failover / lowest-latency / weighted]: ').strip() or 'failover']
            elif choice=='2':
                host=input('Other Iran SSH IPv4: ').strip();ssh_port=input('SSH port [22]: ').strip() or '22'
                invoke(['cluster','trust','--host',host,'--ssh-port',ssh_port]);args=['cluster','add','--host',host,'--ssh-port',ssh_port,'--weight',input('Weight [1]: ').strip() or '1']
            elif choice in ('3','4','5'):args=['cluster',{'3':'status','4':'enable','5':'disable'}[choice]]
            elif choice=='6':args=['cluster','remove','--host',input('Peer IPv4: ').strip()]
            else:continue
        else:
            print('Network tools\n1) Measure path MTU (no changes)\n2) Measure and apply MTU\n3) tcpMux status\n4) Save tcpMux on\n5) Save tcpMux off\n6) Pool diagnostics\n0) Back')
            choice=input('Select: ').strip()
            if choice=='0':return
            if choice in ('1','2'):
                args=['path-mtu','--interface',input('GRE interface [gre-tunnel]: ').strip() or 'gre-tunnel','--peer',input('Opposite INNER GRE IPv4: ').strip()]+(['--apply'] if choice=='2' else [])
            elif choice in ('3','4','5'):args=['tcp-mux',{'3':'status','4':'on','5':'off'}[choice]]
            elif choice=='6':args=['pool']
            else:continue
        try:invoke(args)
        except (ValueError,OSError,subprocess.TimeoutExpired) as e:print('Operation failed: '+str(e))
        input('Press Enter to return...')


def invoke(argv):
    parser=argparse.ArgumentParser(description='Optional NavaTunnel engines and network tools')
    subs=parser.add_subparsers(dest='family',required=True)
    n=subs.add_parser('navalink');n.add_argument('action',choices=('setup','join','status','health','restore','start','stop','restart','remove','endpoint','logs'));n.add_argument('--replace-peer',type=int);n.add_argument('--host');n.add_argument('--public-ip');n.add_argument('--ssh-port',default=22,type=int);n.add_argument('--ports');n.add_argument('--control-port',type=int);n.add_argument('--name',default='');n.add_argument('--bundle');n.add_argument('--id')
    c=subs.add_parser('cluster');c.add_argument('action',choices=('init','trust','accept-key','add','remove','enable','disable','status','tick','health','restore','purge'));c.add_argument('--host');c.add_argument('--ssh-port',type=int,default=22);c.add_argument('--bundle');c.add_argument('--ports');c.add_argument('--mode',choices=('failover','lowest-latency','weighted'),default='failover');c.add_argument('--weight',type=int,default=1);c.add_argument('--failures',type=int,default=3);c.add_argument('--recoveries',type=int,default=3)
    m=subs.add_parser('path-mtu');m.add_argument('--interface',default='gre-tunnel');m.add_argument('--peer',required=True);m.add_argument('--apply',action='store_true')
    mux=subs.add_parser('tcp-mux');mux.add_argument('action',choices=('on','off','status'),default='status',nargs='?')
    subs.add_parser('pool');ui=subs.add_parser('menu');ui.add_argument('page',choices=('navalink','cluster','network'))
    args=parser.parse_args(argv)
    if os.geteuid()!=0:raise ValueError('Run as root.')
    STATE.mkdir(parents=True,exist_ok=True)
    if args.family=='menu':menu(args.page)
    elif args.family=='navalink':navalink(args)
    elif args.family=='cluster':cluster(args)
    else:nettools(args)


if __name__=='__main__':
    # The heredoc supplies code; fd 3 retains the caller's interactive input.
    os.dup2(3,0);os.close(3)
    sys.stdin=open(0)
    try:invoke(sys.argv[1:])
    except (ValueError,TypeError,KeyError,OSError,EOFError,subprocess.TimeoutExpired) as error:
        print('NavaTunnel operation failed: '+str(error),file=sys.stderr);sys.exit(1)
PY
