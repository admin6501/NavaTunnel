#!/usr/bin/env python3
"""Verify feature retirement against real firewall rules in a private namespace."""
import os
from pathlib import Path
import subprocess
import tempfile
import types

ROOT=Path(__file__).resolve().parents[2]


def main():
    with tempfile.TemporaryDirectory(prefix='nava-retired-lab-') as folder:
        os.environ['XTABLES_LOCKFILE']=folder+'/xtables.lock'
        engine=types.ModuleType('cleanup_lab')
        code=(ROOT/'NavaTunnel-maintenance.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
        exec(compile(code,'helper','exec'),engine.__dict__)
        for name in ('STATE','UNITS','ROOT_KEYS','FRP','BACKUPS','SYSCTL'):
            path=Path(folder)/name;path.mkdir();setattr(engine,name,path)
        original=engine.run
        def run(args,*pos,**kwargs):
            if str(args[0])=='systemctl':return subprocess.CompletedProcess(args,0,'','')
            return original(args,*pos,**kwargs)
        engine.run=run
        def ipt(*args):return original(['iptables','-w','5',*args]).stdout
        def nft(*args):return original(['nft',*args]).stdout
        # Unrelated NAT and quota rules must survive byte-for-byte.
        ipt('-t','nat','-N','UNRELATED-LAB');ipt('-t','nat','-A','UNRELATED-LAB','-j','RETURN')
        ipt('-t','mangle','-N','NVtestD');ipt('-t','mangle','-A','NVtestD','-j','RETURN')
        ipt('-t','mangle','-A','INPUT','-i','lo','-j','NVtestD')
        mangle_before=ipt('-t','mangle','-S')
        # Both historical Cluster layouts must be removed, with exact scoped jumps.
        for chain in ('NAVA-CLUSTER','NAVA-CLUSTER-PREROUTING','NAVA-CLUSTER-POSTROUTING'):ipt('-t','nat','-N',chain)
        ipt('-t','nat','-A','NAVA-CLUSTER','-j','DNAT','--to-destination','192.0.2.2')
        ipt('-t','nat','-A','PREROUTING','-p','tcp','--dport','443','-m','comment','--comment','navatunnel-cluster','-j','NAVA-CLUSTER')
        for base,chain in [('PREROUTING','NAVA-CLUSTER-PREROUTING'),('POSTROUTING','NAVA-CLUSTER-POSTROUTING')]:
            ipt('-t','nat','-A',base,'-m','comment','--comment','navatunnel-core-cluster','-j',chain)
        mark=['-m','connmark','--mark','0x4e560000/0xffff0000','-m','conntrack','--ctstate','DNAT']
        ipt('-t','nat','-A','POSTROUTING',*mark,'-j','MASQUERADE')
        ipt('-t','filter','-A','FORWARD',*mark,'-j','ACCEPT')
        ipt('-t','filter','-N','NAVA-CLUSTER-FORWARD')
        ipt('-t','filter','-A','FORWARD','-m','comment','--comment','navatunnel-core-cluster','-j','NAVA-CLUSTER-FORWARD')
        for table in ('navatunnel_rescue','navatunnel_dnat','UNRELATED_LAB'):nft('add','table','inet',table)
        for name in ('cluster.json','cluster_v2.json','core.json','rescue.json'):engine.save(engine.STATE/name,dict(enabled=True))
        engine.save(engine.UNITS/'NavaTunnel-core.service','old')
        engine.save(engine.UNITS/'navatunnel-rescue-frpc.service','old')
        engine.save(engine.STATE/'traffic.json',dict(keep=True))
        traffic_before=(engine.STATE/'traffic.json').read_bytes()
        key=engine.ROOT_KEYS/'authorized_keys';key.write_text('keep-root-key\nrestrict ssh-ed25519 AAA nava-cluster-012345abcdef\n')
        engine.retire()
        nat=ipt('-t','nat','-S');forward=ipt('-t','filter','-S','FORWARD')
        assert 'NAVA-CLUSTER' not in nat+forward and '0x4e560000' not in nat+forward
        assert '-A UNRELATED-LAB -j RETURN' in nat
        assert mangle_before==ipt('-t','mangle','-S')
        tables=nft('list','tables')
        assert 'UNRELATED_LAB' in tables and 'navatunnel_rescue' not in tables and 'navatunnel_dnat' not in tables
        assert key.read_text()=='keep-root-key\n'
        assert (engine.STATE/'traffic.json').read_bytes()==traffic_before
        assert not (engine.STATE/'cluster_v2.json').exists()
        engine.retire()
        assert ipt('-t','nat','-S')==nat
        print('PASS: both Cluster layouts and Rescue retired; unrelated NAT/nftables, quota rules, saved traffic and root keys preserved; retry is a no-op.')


if __name__=='__main__':main()
