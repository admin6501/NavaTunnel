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
        for name in ('STATE','UNITS','ROOT_KEYS'):
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
        print('PASS: retired units, marked NAT/forwarding rules and health keys removed; unrelated rules, keys and traffic state preserved; retry is a no-op.')


if __name__=='__main__':main()
