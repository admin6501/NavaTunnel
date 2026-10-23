#!/usr/bin/env python3
"""Verify owned account retirement and real sshd validation on a disposable CI host."""
import os
from pathlib import Path
import pwd
import secrets
import subprocess
import tempfile
import types

ROOT=Path(__file__).resolve().parents[2]


def main():
    if os.geteuid()!=0:raise RuntimeError('This isolated account lab needs root.')
    number=secrets.token_hex(6);user='nava'+number
    with tempfile.TemporaryDirectory(prefix='nava-ssh-retirement-') as folder:
        engine=types.ModuleType('cleanup_lab')
        code=(ROOT/'NavaTunnel-maintenance.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
        exec(compile(code,'helper','exec'),engine.__dict__)
        for name in ('STATE','UNITS','ROOT_KEYS','FRP','BACKUPS','SYSCTL','CARRIER_HOME'):
            path=Path(folder)/name;path.mkdir();setattr(engine,name,path)
        original=engine.run
        def run(args,*pos,**kwargs):
            if str(args[0])=='systemctl':return subprocess.CompletedProcess(args,0,'','')
            return original(args,*pos,**kwargs)
        engine.run=run
        host=Path(folder)/'host_key'
        original(['ssh-keygen','-q','-t','ed25519','-N','','-f',host])
        Path('/run/sshd').mkdir(exist_ok=True)
        engine.SSH_CONFIG=Path(folder)/'sshd_config'
        common='HostKey '+str(host)+'\nPort 22222\nUsePAM no\n'
        owned='# NavaTunnel '+number+' begin\nMatch User '+user+'\n    AllowTcpForwarding remote\n    ForceCommand /bin/false\n# NavaTunnel '+number+' end\n'
        other='Match User unrelated\n    PermitTTY no\n'
        engine.SSH_CONFIG.write_text(common+owned+other)
        original(['/usr/sbin/sshd','-t','-f',engine.SSH_CONFIG])
        home=engine.CARRIER_HOME/number
        original(['useradd','--system','--create-home','--home-dir',home,'--shell','/usr/sbin/nologin',user])
        try:
            key=home/'.ssh/authorized_keys';key.parent.mkdir();key.write_text('owned-key\n')
            rootkey=engine.ROOT_KEYS/'authorized_keys';rootkey.write_text('unrelated-root-key\n')
            engine.remove_account(number)
            try:pwd.getpwnam(user)
            except KeyError:pass
            else:raise AssertionError('Owned carrier account still exists.')
            assert engine.SSH_CONFIG.read_text()==common+other
            assert rootkey.read_text()=='unrelated-root-key\n'
            assert not home.exists()
            original(['/usr/sbin/sshd','-t','-f',engine.SSH_CONFIG])
            assert list(engine.BACKUPS.glob('removed-features-*/sshd_config'))
            print('PASS: owned SSH account and Match block removed; real sshd config remains valid and unrelated root key preserved.')
        finally:
            try:pwd.getpwnam(user)
            except KeyError:pass
            else:original(['userdel',user],False)


if __name__=='__main__':main()
