#!/usr/bin/env python3
"""Real GRE/FOU + FRP with two Iran namespaces and shared TCP/UDP service ports.
Run in unshare -n. Files are confined to a temporary directory; the test adapter
executes generated GRE units and starts real FRPC binaries without host systemd.
"""
import json, os, shutil, subprocess, sys, tempfile, threading, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]

def run(args,**kw):return subprocess.run(list(map(str,args)),check=True,text=True,capture_output=True,timeout=60,**kw)

def main():
    if os.geteuid()!=0:raise RuntimeError('Root is required inside an isolated network namespace.')
    binaries=Path(sys.argv[1]).resolve();children=[];logs=[]
    with tempfile.TemporaryDirectory(prefix='nava-multi-') as tmp:
        base=Path(tmp)
        for name in ('state','frp','units','bin','backups'):(base/name).mkdir()
        try:
            run(['ip','link','set','lo','up']);run(['ip','addr','add','198.18.0.1/32','dev','lo'])
            for exe in ('frps','frpc'):shutil.copy2(binaries/exe,base/'bin'/exe)
            source=(ROOT/'NavaTunnel.sh').read_text().rsplit('\nif [[ $# -gt 0 ]]; then',1)[0]
            for old,new in [('/etc/gre-panel',base/'state'),('/etc/frp',base/'frp'),('/etc/systemd/system',base/'units'),('/usr/local/bin',base/'bin'),('/var/backups/navatunnel',base/'backups')]:source=source.replace(old,str(new))
            (base/'library.sh').write_text(source)
            traffic=(ROOT/'NavaTunnel-traffic.sh').read_text().replace('/etc/gre-panel',str(base/'state')).replace('/etc/systemd/system',str(base/'units'))
            (base/'bin/NavaTunnel-traffic.sh').write_text(traffic)
            adapter='''
ensure_navatunnel_bin() { :; }
ensure_dependencies_smart() { :; }
install_frp_binaries() { :; }
backup_configs() { :; }
tune_apply() { :; }
watchdog_on() { :; }
perf_get_dpi_enabled() { echo 0; }
systemctl() {
    local action=$1 unit name command
    shift
    case "$action" in
        is-active) unit=${!#};unit=${unit%.service};[[ -f "$LAB/units/.active-$unit" ]] ;;
        restart|start|stop|disable)
            for unit in "$@";do
                [[ "$unit" != --* ]] || continue
                name=${unit%.service}
                if [[ "$action" == stop || "$action" == disable ]];then
                    rm -f "$LAB/units/.active-$name"
                    [[ "$name" != gre-t* ]] || ip link del "$name" 2>/dev/null || true
                else
                    if [[ "$name" == gre-t* ]];then
                        command=$(sed -n 's/^ExecStart=//p' "$LAB/units/$name.service")
                        eval "$command" || return 1
                    fi
                    touch "$LAB/units/.active-$name"
                fi
            done ;;
        *) return 0 ;;
    esac
}
'''
            def shell(cmd):
                try:return run(['bash','-c','source "$1"\n'+adapter+'\n'+cmd,'lab',base/'library.sh'],env=dict(os.environ,LAB=str(base)))
                except subprocess.CalledProcessError as error:
                    print(error.stdout,error.stderr,file=sys.stderr);raise
            def start(args):
                log=open(base/('process-'+str(len(children))+'.log'),'w+');logs.append(log)
                child=subprocess.Popen(list(map(str,args)),stdout=log,stderr=subprocess.STDOUT);children.append(child);return child
            nodes=[]
            for n in (1,2):
                node=start(['unshare','-n','sleep','300']);nodes.append(node);time.sleep(.1)
                def ns(*args):return run(['nsenter','-t',node.pid,'-n',*args])
                run(['ip','link','add','wire'+str(n),'type','veth','peer','name','peer'+str(n),'netns',node.pid])
                run(['ip','addr','add','198.18.'+str(n)+'.1/30','dev','wire'+str(n)]);run(['ip','link','set','wire'+str(n),'up'])
                ns('ip','link','set','lo','up');ns('ip','addr','add','198.18.'+str(n)+'.2/30','dev','peer'+str(n));ns('ip','link','set','peer'+str(n),'up')
                ns('ip','route','add','198.18.0.1/32','via','198.18.'+str(n)+'.1')
                ns('ip','link','add','iran-gre','type','gre','local','198.18.'+str(n)+'.2','remote','198.18.0.1','ttl','255')
                ns('ip','addr','add',('10.201.0.2/30' if n==1 else '10.201.0.6/30'),'dev','iran-gre');ns('ip','link','set','iran-gre','up','mtu','1380')
                conf=base/('iran'+str(n)+'.toml');conf.write_text('bindAddr="0.0.0.0"\nbindPort=17000\nauth.token="'+('a' if n==1 else 'b')*32+'"\n')
                start(['nsenter','-t',node.pid,'-n',binaries/'frps','-c',conf])
            echo='''import socket,threading
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',18080));s.listen()
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);u.bind(('127.0.0.1',18080))
def udp():
 while True:
  data,addr=u.recvfrom(65535);u.sendto(data,addr)
threading.Thread(target=udp,daemon=True).start()
while True:
 c,a=s.accept();data=c.recv(65535);c.sendall(data);c.close()
'''
            start([sys.executable,'-u','-c',echo]);clients=[]
            def setup(n,force=False):return shell(('FORCE=1 ' if force else '')+'_setup_foreign_full 198.18.0.1 198.18.'+str(n)+'.2 17000 '+('a' if n==1 else 'b')*32+' '+('10.201.0.1 10.201.0.2' if n==1 else '10.201.0.5 10.201.0.6')+' "18080"')
            for n in (1,2):
                setup(n);clients.append(start([binaries/'frpc','-c',base/'frp'/('frpc.toml' if n==1 else 'frpc-2.toml')]))
            tcp="import socket;s=socket.create_connection(('127.0.0.1',18080),3);s.sendall(b'test-tcp');assert s.recv(100)==b'test-tcp';s.close()"
            udp="import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(3);s.sendto(b'test-udp',('127.0.0.1',18080));assert s.recvfrom(100)[0]==b'test-udp'"
            def probe(n,code):return run(['nsenter','-t',nodes[n-1].pid,'-n',sys.executable,'-c',code])
            def wait_probe(n,code):
                for attempt in range(25):
                    try:probe(n,code);return
                    except subprocess.CalledProcessError:
                        if attempt==24:raise
                        time.sleep(.2)
            for n in (1,2):wait_probe(n,tcp);wait_probe(n,udp)
            errors=[];stop=threading.Event()
            def continuous():
                while not stop.is_set():
                    try:probe(2,tcp)
                    except Exception as error:errors.append(str(error))
                    stop.wait(.05)
            thread=threading.Thread(target=continuous);thread.start()
            try:setup(1,force=True)
            finally:stop.set();thread.join()
            assert not errors,errors
            assert clients[1].poll() is None
            shell('cli_traffic tick');usage=json.loads((base/'state/traffic.json').read_text())
            assert all(usage[name]['download']+usage[name]['upload']>0 for name in ('gre-tunnel','gre-t2'))
            for n in (1,2):
                run(['nsenter','-t',nodes[n-1].pid,'-n','ip','fou','add','port','55555','ipproto','47'])
                run(['nsenter','-t',nodes[n-1].pid,'-n','ip','link','set','iran-gre','type','gre','encap','fou','encap-sport','auto','encap-dport','55555'])
                shell('cli_foreign_manage '+str(n)+' carrier fou:55555')
            for n in (1,2):wait_probe(n,tcp);wait_probe(n,udp)
            shell('systemctl restart gre-tunnel.service gre-t2.service; carrier_apply_active gre-tunnel; carrier_apply_active gre-t2')
            for n in (1,2):wait_probe(n,tcp);wait_probe(n,udp)
            shell('cli_foreign_manage 1 stop');probe(2,tcp);probe(2,udp)
            shell('cli_foreign_manage 1 start; carrier_apply_active gre-tunnel');wait_probe(1,tcp)
            old_b=json.loads((base/'state/traffic.json').read_text())['gre-t2']['download']
            shell('cli_foreign_manage 1 remove --force');probe(2,tcp);probe(2,udp);shell('cli_traffic tick')
            after=json.loads((base/'state/traffic.json').read_text())
            assert 'gre-tunnel' not in after and after['gre-t2']['download']>=old_b
            assert len(json.loads((base/'state/foreign.json').read_text())['connections'])==1
            print('PASS: two Iran nodes shared TCP/UDP service and control ports through independent GRE/FOU clients on one foreign host.')
            print('PASS: edit/stop/restart/remove of A preserved B and its usage; saved GRE/FOU settings survived recreation.')
        except Exception:
            for log in logs:log.flush();log.seek(0);print(log.read()[-1500:],file=sys.stderr)
            raise
        finally:
            for child in reversed(children):
                if child.poll() is None:child.terminate()
            for child in children:
                try:child.wait(timeout=3)
                except subprocess.TimeoutExpired:child.kill();child.wait()
            for log in logs:log.close()

if __name__=='__main__':main()
