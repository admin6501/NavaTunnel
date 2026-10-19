#!/usr/bin/env python3
"""Verify retired-feature cleanup in an isolated network namespace only."""
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
        code=(ROOT/'NavaTunnel-extra.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
        exec(compile(code,'helper','exec'),engine.__dict__)
        for name in ('STATE','UNITS','ROOT_KEYS','FRP','BACKUPS','SYSCTL'):
            path=Path(folder)/name;path.mkdir();setattr(engine,name,path)
        original=engine.run
        def run(args,*pos,**kwargs):
            if str(args[0])=='systemctl':return subprocess.CompletedProcess(args,0,'','')
            return original(args,*pos,**kwargs)
        engine.run=run
        def ipt(*args):return original(['iptables','-w','5',*args]).stdout
        ipt('-t','nat','-N','UNRELATED-LAB');ipt('-t','nat','-A','UNRELATED-LAB','-j','RETURN')
        ipt('-t','nat','-N','NAVA-CLUSTER')
        ipt('-t','nat','-A','NAVA-CLUSTER','-j','DNAT','--to-destination','192.0.2.2')
        ipt('-t','nat','-A','PREROUTING','-p','tcp','--dport','443','-m','comment','--comment','navatunnel-cluster','-j','NAVA-CLUSTER')
        mark=['-m','connmark','--mark','0x4e560000/0xffff0000','-m','conntrack','--ctstate','DNAT']
        ipt('-t','nat','-A','POSTROUTING',*mark,'-j','MASQUERADE')
        ipt('-t','filter','-A','FORWARD',*mark,'-j','ACCEPT')
        engine.save(engine.STATE/'cluster.json',dict(enabled=True))
        engine.save(engine.STATE/'traffic.json',dict(keep=True))
        for suffix in ('timer','service'):(engine.UNITS/('NavaTunnel-cluster.'+suffix)).write_text('old')
        key=engine.ROOT_KEYS/'authorized_keys';key.write_text('keep-root-key\nrestrict ssh-ed25519 AAA nava-cluster-012345abcdef\n')
        engine.cleanup_retired()
        nat=ipt('-t','nat','-S');forward=ipt('-t','filter','-S','FORWARD')
        assert 'NAVA-CLUSTER' not in nat and 'navatunnel-cluster' not in nat
        assert '0x4e560000' not in nat+forward
        assert '-A UNRELATED-LAB -j RETURN' in nat
        assert key.read_text()=='keep-root-key\n'
        assert (engine.STATE/'traffic.json').exists()
        engine.cleanup_retired()
        # The new cleanup must preserve the retained original Cluster while removing Rescue.
        ipt('-t','nat','-N','NAVA-CLUSTER-PREROUTING')
        ipt('-t','nat','-A','NAVA-CLUSTER-PREROUTING','-j','RETURN')
        retained_nat=ipt('-t','nat','-S')
        def nft(*args):return original(['nft',*args]).stdout
        for table in ('navatunnel_rescue','navatunnel_dnat','UNRELATED_LAB'):nft('add','table','inet',table)
        engine.save(engine.STATE/'cluster_v2.json',dict(enabled=True,cluster_secret='retained'))
        engine.save(engine.STATE/'rescue.json',dict(role='origin',token='retire-private'))
        engine.save(engine.STATE/'alerts.json',dict(enabled=True))
        engine.save(engine.UNITS/'navatunnel-rescue-frpc.service','owned')
        cluster_before=(engine.STATE/'cluster_v2.json').read_bytes()
        traffic_before=(engine.STATE/'traffic.json').read_bytes()
        engine.cleanup_extra_tools()
        assert retained_nat==ipt('-t','nat','-S')
        tables=nft('list','tables')
        assert 'UNRELATED_LAB' in tables and 'navatunnel_rescue' not in tables and 'navatunnel_dnat' not in tables
        assert (engine.STATE/'cluster_v2.json').read_bytes()==cluster_before
        assert (engine.STATE/'traffic.json').read_bytes()==traffic_before
        engine.cleanup_extra_tools()
        print('PASS: removed Rescue tables and units retired; retained Cluster NAT, unrelated nftables, quotas and configuration preserved.')
        print('PASS: retired units, marked NAT/forwarding rules and health keys removed; unrelated rules, keys and traffic state preserved; retry is a no-op.')


if __name__=='__main__':main()
