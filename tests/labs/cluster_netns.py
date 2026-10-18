#!/usr/bin/env python3
"""Real owned-chain DNAT/MASQUERADE checks in an isolated user/network namespace.
Run: unshare -Urn python3 tests/labs/cluster_netns.py
No host firewall, network interfaces or application config is changed.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import types

ROOT=Path(__file__).resolve().parents[2]


def run(args,**kwargs):return subprocess.run(args,check=True,text=True,capture_output=True,**kwargs)


def main():
    if os.geteuid()!=0:raise SystemExit('Run inside unshare -Urn.')
    with tempfile.TemporaryDirectory(prefix='nava-cluster-lab-') as folder:
        os.environ['XTABLES_LOCKFILE']=folder+'/xtables.lock'
        engine=types.ModuleType('extra_lab')
        source=(ROOT/'NavaTunnel-extra.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
        exec(compile(source,'NavaTunnel-extra.sh','exec'),engine.__dict__)
        children=[]
        try:
            for name in ('client','peer'):
                process=subprocess.Popen(['unshare','-n','sleep','120']);children.append(process)
            time.sleep(.1)
            client,peer=[p.pid for p in children]
            def inside(pid,args):return run(['nsenter','-t',str(pid),'-n',*args])
            run(['ip','link','set','lo','up'])
            for label,pid,hostip,childip in [('c',client,'192.0.2.1','192.0.2.2'),('p',peer,'198.51.100.1','198.51.100.2')]:
                run(['ip','link','add','nv'+label,'type','veth','peer','name','nv'+label+'x'])
                run(['ip','link','set','nv'+label+'x','netns',str(pid)])
                run(['ip','addr','add',hostip+'/24','dev','nv'+label]);run(['ip','link','set','nv'+label,'up'])
                inside(pid,['ip','link','set','lo','up']);inside(pid,['ip','addr','add',childip+'/24','dev','nv'+label+'x']);inside(pid,['ip','link','set','nv'+label+'x','up'])
            # This unrelated chain/rule must survive both failover and rollback.
            run(['iptables','-t','nat','-N','UNRELATED-LAB'])
            run(['iptables','-t','nat','-A','UNRELATED-LAB','-j','RETURN'])
            cfg=dict(ports=[18443],mode='failover')
            engine.cluster_firewall(cfg,[dict(host='198.51.100.2',weight=1)])
            responder="import socket;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('0.0.0.0',18443));s.listen();c,a=s.accept();c.sendall(b'nava-peer');c.close();s.close()"
            server=subprocess.Popen(['nsenter','-t',str(peer),'-n','python3','-c',responder],stdout=subprocess.PIPE,stderr=subprocess.PIPE);children.append(server)
            time.sleep(.2)
            client_code="import socket;s=socket.create_connection(('192.0.2.1',18443),3);print(s.recv(64).decode())"
            answer=inside(client,['python3','-c',client_code]).stdout.strip()
            assert answer=='nava-peer',answer
            engine.cluster_firewall(cfg,[])
            assert 'RETURN' in run(['iptables','-t','nat','-S','UNRELATED-LAB']).stdout
            assert '--to-destination' not in run(['iptables','-t','nat','-S','NAVA-CLUSTER']).stdout
            engine.cluster_clear(cfg)
            assert 'UNRELATED-LAB' in run(['iptables','-t','nat','-S']).stdout
            print('PASS: real TCP forwarding reached the remote namespace; owned-chain rollback preserved unrelated rules.')
        finally:
            for process in reversed(children):
                process.terminate()
            for process in children:
                try:process.wait(timeout=3)
                except subprocess.TimeoutExpired:process.kill();process.wait()


if __name__=='__main__':main()
