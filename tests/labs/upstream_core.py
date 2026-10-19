#!/usr/bin/env python3
"""Real Cluster TCP/UDP failover and WSS bridge in disposable network namespaces.
Run only as: unshare -Urn python3 tests/labs/upstream_core.py /absolute/core-binary
or sudo unshare -n ... on a disposable CI runner. No host firewall is changed.
"""
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import tempfile
import time


def main():
    binary=str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='nava-upstream-lab-') as folder:
        base=Path(folder);os.environ['NO_PROXY']=os.environ.get('NO_PROXY','')+',198.18.1.1,198.18.1.2';os.environ['no_proxy']=os.environ['NO_PROXY'];os.environ['XTABLES_LOCKFILE']=str(base/'xtables.lock')
        children=[];logs=[]
        def run(args,**kw):return subprocess.run(list(map(str,args)),text=True,capture_output=True,check=True,**kw)
        def spawn(args,label,env=None):
            log=open(base/(label+'.log'),'w');logs.append(log);p=subprocess.Popen(list(map(str,args)),stdout=log,stderr=log,start_new_session=True,env=env);children.append(p);return p
        def inside(pid,args,**kw):return run(['nsenter','-t',pid,'-n',*args],**kw)
        def core(state,family,action='status',body=None,query='',pid=None):
            env=dict(os.environ,NAVATUNNEL_CORE_STATE=str(state),NAVATUNNEL_FRP_DIR=str(base/'frp'))
            args=[binary,family,action,'--json',json.dumps(body or {})]
            if query:args+=['--query',query]
            return (inside(pid,args,env=env) if pid else run(args,env=env)).stdout
        def wait(fn,seconds=25):
            until=time.monotonic()+seconds;last=None
            while time.monotonic()<until:
                try:
                    value=fn()
                    if value:return value
                except (subprocess.SubprocessError,OSError,ValueError) as error:last=error
                time.sleep(.25)
            raise AssertionError('Condition did not become true: '+str(last))
        try:
            peers=[spawn(['unshare','-n','sleep','240'],name) for name in ('client','exit-a','exit-b')];time.sleep(.15)
            client,a,b=[p.pid for p in peers]
            run(['ip','link','set','lo','up'])
            for suffix,pid,rootip,childip in [('c',client,'192.0.2.1','192.0.2.2'),('a',a,'198.51.100.1','198.51.100.2'),('b',b,'203.0.113.1','203.0.113.2')]:
                run(['ip','link','add','nv'+suffix,'type','veth','peer','name','nv'+suffix+'x']);run(['ip','link','set','nv'+suffix+'x','netns',pid]);run(['ip','addr','add',rootip+'/24','dev','nv'+suffix]);run(['ip','link','set','nv'+suffix,'up']);inside(pid,['ip','link','set','lo','up']);inside(pid,['ip','addr','add',childip+'/24','dev','nv'+suffix+'x']);inside(pid,['ip','link','set','nv'+suffix+'x','up'])
            run(['iptables','-P','FORWARD','DROP']);run(['iptables','-t','nat','-N','UNRELATED-LAB']);run(['iptables','-t','nat','-A','UNRELATED-LAB','-j','RETURN'])
            echo="""import socket,threading,sys
label=sys.argv[1].encode()
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('0.0.0.0',18443));s.listen()
def tcp():
 while True:
  c,_=s.accept();c.sendall(label);c.close()
threading.Thread(target=tcp,daemon=True).start()
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);u.bind(('0.0.0.0',18443))
while True:
 data,addr=u.recvfrom(2048);u.sendto(label,addr)
"""
            echo_a=spawn(['nsenter','-t',a,'-n','python3','-c',echo,'exit-a'],'echo-a');spawn(['nsenter','-t',b,'-n','python3','-c',echo,'exit-b'],'echo-b');time.sleep(.2)
            state=base/'controller';state.mkdir();env=dict(os.environ,NAVATUNNEL_CORE_STATE=str(state),NAVATUNNEL_FRP_DIR=str(base/'frp'))
            spawn([binary,'serve'],'core-controller',env);wait(lambda:(state/'core.sock').exists())
            core(state,'cluster','config',dict(service_ports=[18443],balancing_mode='failover',enabled=False))
            for name,ip,weight in [('a','198.51.100.2',1),('b','203.0.113.2',3)]:core(state,'cluster','add-foreign',dict(id=name,name=name,public_ip=ip,tunnel_port=18443,weight=weight,protocol='gre'))
            core(state,'cluster','config',dict(enabled=True))
            tcp_probe="import socket;s=socket.create_connection(('192.0.2.1',18443),2);print(s.recv(64).decode())"
            udp_probe="import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(2);s.sendto(b'probe',('192.0.2.1',18443));print(s.recvfrom(64)[0].decode())"
            assert inside(client,['python3','-c',tcp_probe]).stdout.strip()=='exit-a'
            assert inside(client,['python3','-c',udp_probe]).stdout.strip()=='exit-a'
            os.killpg(echo_a.pid,signal.SIGTERM);echo_a.wait(timeout=3)
            wait(lambda:inside(client,['python3','-c',tcp_probe]).stdout.strip()=='exit-b')
            assert inside(client,['python3','-c',udp_probe]).stdout.strip()=='exit-b'
            spawn(['nsenter','-t',a,'-n','python3','-c',echo,'exit-a'],'echo-a-return');time.sleep(.2)
            core(state,'cluster','config',dict(balancing_mode='wrr'))
            wait(lambda:json.loads(core(state,'cluster'))['foreign_nodes']['a']['is_healthy'])
            sample="import socket;out=set();\nfor _ in range(60):\n s=socket.create_connection(('192.0.2.1',18443),2);out.add(s.recv(64).decode());s.close()\nprint(','.join(sorted(out)))"
            assert inside(client,['python3','-c',sample]).stdout.strip()=='exit-a,exit-b'
            core(state,'cluster','config',dict(enabled=False))
            assert 'UNRELATED-LAB' in run(['iptables','-t','nat','-S']).stdout
            own=run(['iptables','-t','nat','-S','NAVA-CLUSTER-PREROUTING']).stdout
            assert '--to-destination' not in own
            print('PASS: original Cluster exit pool carried TCP/UDP, failed over, weighted new flows and reverted without changing unrelated NAT rules.')
            # A private point-to-point link for the two WSS/peer API endpoints.
            run(['ip','link','add','nvwa','type','veth','peer','name','nvwb']);run(['ip','link','set','nvwa','netns',a]);run(['ip','link','set','nvwb','netns',b])
            for pid,dev,ip in [(a,'nvwa','198.18.1.1'),(b,'nvwb','198.18.1.2')]:inside(pid,['ip','addr','add',ip+'/24','dev',dev]);inside(pid,['ip','link','set',dev,'up'])
            states=[]
            for name,pid in [('a',a),('b',b)]:
                st=base/('wss-'+name);st.mkdir();states.append(st);env=dict(os.environ,NAVATUNNEL_CORE_STATE=str(st),NAVATUNNEL_FRP_DIR=str(base/'frp'));spawn(['nsenter','-t',pid,'-n',binary,'serve','--listen','0.0.0.0:47777','--tls'],'core-wss-'+name,env);wait(lambda st=st:(st/'core.sock').exists());wait(lambda st=st:(st/'peer-api.crt').exists())
            sa,sb=states;secret=secrets.token_hex(32)
            for st in states:core(st,'cluster','config',dict(cluster_secret=secret))
            api_probe="""import urllib.request,ssl,json
ctx=ssl._create_unverified_context()
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPSHandler(context=ctx))
for path,secret,expected in [('/',None,404),('/api/cluster/config',None,404),('/api/cluster/heartbeat','wrong',401),('/api/cluster/heartbeat',__import__('sys').argv[1],200)]:
 req=urllib.request.Request('https://198.18.1.1:47777'+path,data=b'{}',headers={'X-Cluster-Secret':secret or ''})
 try:
  with opener.open(req,timeout=4) as r:code=r.status
 except urllib.error.HTTPError as e:code=e.code
 assert code==expected,(path,code,expected)
"""
            inside(b,['python3','-c',api_probe,secret])
            token=secrets.token_hex(24)
            core(sa,'wss','config',dict(enabled=True,role='server',listen_port=18444,local_bridge_udp=19998,auth_token=token,use_tls=True))
            core(sb,'wss','config',dict(enabled=True,role='client',listen_port=18444,remote_addr='198.18.1.1:18444',local_bridge_udp=19998,auth_token='wrong-token-that-is-long-enough',use_tls=True,insecure_tls=True))
            wait(lambda:'unauthorized' in json.loads(core(sb,'wss')).get('last_error','').lower())
            assert not json.loads(core(sb,'wss'))['connected']
            core(sb,'wss','config',dict(enabled=True,role='client',listen_port=18444,remote_addr='198.18.1.1:18444',local_bridge_udp=19998,auth_token=token,use_tls=True,insecure_tls=True))
            wait(lambda:json.loads(core(sb,'wss'))['connected'])
            udp_echo="import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('127.0.0.1',19998));\nwhile True:\n d,a=s.recvfrom(65535);s.sendto(b'wss:'+d,a)"
            spawn(['nsenter','-t',a,'-n','python3','-c',udp_echo],'wss-echo');time.sleep(.15)
            bridge_probe="import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('127.0.0.1',19998));s.settimeout(5);data=b'x'*1360;s.sendto(data,('127.0.0.1',19999));assert s.recvfrom(65535)[0]==b'wss:'+data"
            inside(b,['python3','-c',bridge_probe])
            for log in logs:
                log.flush();assert 'WARNING: DATA RACE' not in Path(log.name).read_text(),log.name
            print('PASS: TLS peer API has no browser/admin routes and rejects bad secrets; authenticated WSS carried real 1360-byte datagrams and rejected a wrong token.')
        except Exception as error:
            if isinstance(error,subprocess.CalledProcessError):print(error.stderr,file=sys.stderr)
            if 'sb' in locals():
                try:print('Last WSS status: '+core(sb,'wss'),file=sys.stderr)
                except Exception:pass
            for log in logs:
                log.flush();text=Path(log.name).read_text()
                if text:print(Path(log.name).name+':\n'+text[-2500:],file=sys.stderr)
            raise
        finally:
            for p in reversed(children):
                if p.poll() is None:
                    try:os.killpg(p.pid,signal.SIGTERM)
                    except ProcessLookupError:pass
            for p in children:
                try:p.wait(timeout=3)
                except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
            for log in logs:log.close()


if __name__=='__main__':main()
