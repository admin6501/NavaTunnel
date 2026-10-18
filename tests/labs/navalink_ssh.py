#!/usr/bin/env python3
"""Privileged, isolated NavaLink data-path and SSH-restriction lab.
Run only on a disposable Linux test runner:
  sudo python3 tests/labs/navalink_ssh.py /path/to/verified/frp-binaries
Two network namespaces, a uniquely named temporary SSH user, and a private
sshd config are created. The host's SSH configuration/firewall are not edited.
"""
import io
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import time
import types

ROOT=Path(__file__).resolve().parents[2]


def run(args,check=True,**kwargs):return subprocess.run(list(map(str,args)),check=check,text=True,capture_output=True,**kwargs)


def main():
    if os.geteuid()!=0:raise SystemExit('This lab requires a disposable root-capable test runner.')
    binaries=Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='nava-ssh-lab-') as folder:
        base=Path(folder);base.chmod(0o755)
        engine=types.ModuleType('extra_ssh_lab')
        source=(ROOT/'NavaTunnel-extra.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
        exec(compile(source,'NavaTunnel-extra.sh','exec'),engine.__dict__)
        engine.STATE=base/'state';engine.STATE.mkdir(mode=0o700)
        engine.CARRIER_HOME=base/'homes';engine.CARRIER_HOME.mkdir(mode=0o755)
        engine.SSH_CONFIG=base/'sshd_config'
        number=secrets.token_hex(6);tag='nv'+number[:6]
        children=[];logs=[];account_created=False
        def spawn(args,name):
            log=open(base/(name+'.log'),'w+');logs.append(log)
            process=subprocess.Popen(list(map(str,args)),stdout=log,stderr=log,start_new_session=True);children.append(process);return process
        original=engine.run
        def runner(args,*pos,**kwargs):
            if str(args[0])=='systemctl':return subprocess.CompletedProcess(args,0,'','')
            return original(args,*pos,**kwargs)
        engine.run=runner
        def inside(pid,args,**kwargs):return run(['nsenter','-t',pid,'-n',*args],**kwargs)
        try:
            a=spawn(['unshare','-n','sleep','120'],'ns-iran');b=spawn(['unshare','-n','sleep','120'],'ns-foreign');time.sleep(.15)
            run(['ip','link','add',tag+'a','type','veth','peer','name',tag+'b'])
            run(['ip','link','set',tag+'a','netns',a.pid]);run(['ip','link','set',tag+'b','netns',b.pid])
            for pid,dev,address in ((a.pid,tag+'a','198.19.0.1'),(b.pid,tag+'b','198.19.0.2')):
                inside(pid,['ip','link','set','lo','up']);inside(pid,['ip','addr','add',address+'/24','dev',dev]);inside(pid,['ip','link','set',dev,'up'])
            run(['ssh-keygen','-q','-t','ed25519','-N','','-f',base/'hostkey'])
            key=base/'iran-key';public=engine.keypair(key);base.chmod(0o755)
            host_public=(base/'hostkey.pub').read_text().split()
            known=engine.STATE/'ssh-known-hosts';known.write_text('[198.19.0.2]:22022 '+host_public[0]+' '+host_public[1]+'\n')
            engine.SSH_CONFIG.write_text('Port 22022\nListenAddress 198.19.0.2\nHostKey '+str(base/'hostkey')+'\nPidFile '+str(base/'sshd.pid')+'\nUsePAM no\nStrictModes yes\nPasswordAuthentication no\nPubkeyAuthentication yes\nLogLevel VERBOSE\n')
            Path('/run/sshd').mkdir(mode=0o755,exist_ok=True)
            t=dict(id=number,role='iran',control_port=42000,ssh_port=22022,ports=[18080],token=secrets.token_hex(24),public_key=public,remote_host='198.19.0.2',local_pub='198.19.0.1',name='lab',stopped=False)
            account_created=True;engine.carrier_account(t)
            server=base/'frps.toml';client=base/'frpc.toml'
            server.write_text(engine.nava_config(t));client.write_text(engine.nava_config(dict(t,role='foreign')))
            run([binaries/'frps','verify','-c',server]);run([binaries/'frpc','verify','-c',client])
            spawn(['nsenter','-t',b.pid,'-n','/usr/sbin/sshd','-D','-e','-f',engine.SSH_CONFIG],'sshd')
            spawn(['nsenter','-t',a.pid,'-n',binaries/'frps','-c',server],'frps')
            echo="""import socket,threading
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',18080));s.listen()
def tcp():
 while True:
  c,_=s.accept();data=c.recv(1024);c.sendall(data);c.close()
threading.Thread(target=tcp,daemon=True).start()
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);u.bind(('127.0.0.1',18080))
while True:
 data,addr=u.recvfrom(1024);u.sendto(data,addr)
"""
            spawn(['nsenter','-t',b.pid,'-n','python3','-c',echo],'echo')
            ssh=['nsenter','-t',a.pid,'-n','ssh','-F','/dev/null','-T','-i',key,'-p','22022','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(known),'-o','ExitOnForwardFailure=yes']
            time.sleep(.3)
            spawn([*ssh,'-N','-R','127.0.0.1:42000:127.0.0.1:42000','nava'+number+'@198.19.0.2'],'carrier')
            spawn(['nsenter','-t',b.pid,'-n',binaries/'frpc','-c',client],'frpc')
            probe="import socket;s=socket.create_connection(('127.0.0.1',18080),2);s.sendall(b'navalink-tcp');assert s.recv(64)==b'navalink-tcp'"
            success=False
            for _ in range(30):
                if inside(a.pid,['python3','-c',probe],check=False).returncode==0:success=True;break
                time.sleep(.2)
            assert success,'FRP over the SSH carrier did not forward TCP.'
            udp="import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(4);s.sendto(b'navalink-udp',('127.0.0.1',18080));assert s.recvfrom(64)[0]==b'navalink-udp'"
            inside(a.pid,['python3','-c',udp])
            denied=run([*ssh,'nava'+number+'@198.19.0.2','id'],check=False,timeout=8)
            assert denied.returncode!=0 and 'uid=' not in denied.stdout,'Carrier key must not execute commands.'
            wrong=run([*ssh,'-N','-R','127.0.0.1:42001:127.0.0.1:42000','nava'+number+'@198.19.0.2'],check=False,timeout=8)
            assert wrong.returncode!=0,'Carrier key must not open a different reverse listener.'
            local=spawn([*ssh,'-N','-L','127.0.0.1:18081:127.0.0.1:18080','nava'+number+'@198.19.0.2'],'denied-forward')
            time.sleep(.3)
            direct=inside(a.pid,['python3','-c',"import socket;s=socket.create_connection(('127.0.0.1',18081),2);s.sendall(b'blocked');assert s.recv(64)!=b'blocked'"],check=False)
            # EOF or a reset both show denial; inspect the SSH client's explicit reason too.
            time.sleep(.2);logs[-1].flush()
            assert 'administratively prohibited' in (base/'denied-forward.log').read_text(),'Local forwarding was not explicitly denied.'
            print('PASS: real FRP 0.71 TCP and UDP crossed reverse SSH; shell execution, a different reverse port and local forwarding were denied.')
        except Exception:
            for log in logs:
                log.flush();text=Path(log.name).read_text()
                if text:print(Path(log.name).name+':\n'+text[-3500:],file=sys.stderr)
            raise
        finally:
            for process in reversed(children):
                try:os.killpg(process.pid,signal.SIGTERM)
                except ProcessLookupError:pass
            for process in children:
                try:process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    try:os.killpg(process.pid,signal.SIGKILL)
                    except ProcessLookupError:pass
                    process.wait()
            if account_created:
                try:engine.carrier_account(t,True)
                except Exception:
                    run(['pkill','-u','nava'+number],check=False);run(['userdel','nava'+number],check=False)
            for name in (tag+'a',tag+'b'):run(['ip','link','del',name],check=False)
            for log in logs:log.close()


if __name__=='__main__':main()
