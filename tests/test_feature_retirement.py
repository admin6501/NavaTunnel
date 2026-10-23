import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]

class RetirementTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.engine=types.ModuleType('retirement')
        source=(ROOT/'NavaTunnel-maintenance.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
        exec(compile(source,'maintenance','exec'),self.engine.__dict__)
        for name in ('STATE','UNITS','BIN','FRP','BACKUPS','ROOT_KEYS','SYSCTL','CARRIER_HOME'):
            path=self.root/name;path.mkdir();setattr(self.engine,name,path)
        self.engine.SSH_CONFIG=self.root/'sshd_config';self.engine.SSH_CONFIG.write_text('Port 22\n')
        self.calls=[];self.engine.run=self.fake_run
        self.peer=dict(id=1,name='converted',local_pub='192.0.2.1',remote_pub='198.51.100.1',gre_if='gre-tunnel',frps_svc='frps',local_gre='10.200.0.2',peer_gre='10.200.0.1',ports=[443],frp_port=42000)
        self.number='012345abcdef'
        self.folder=self.engine.STATE/'navalink'/self.number
        self.traffic={'gre-tunnel':dict(peer='198.51.100.1',download=123456789,upload=987654321,mode='download',limit=2000000000,blocked=False)}

    def fake_run(self,args,check=True,**kwargs):
        args=list(map(str,args));self.calls.append(args)
        if 'retarget' in args:
            data=self.engine.load(self.engine.STATE/'traffic.json');item=data[args[3]]
            item['interface']=args[-1];item['peer']=None;self.engine.save(self.engine.STATE/'traffic.json',data)
        if 'remove' in args and 'NavaTunnel-traffic.sh' in args[1]:
            data=self.engine.load(self.engine.STATE/'traffic.json');data.pop(args[-1],None);self.engine.save(self.engine.STATE/'traffic.json',data)
        return subprocess.CompletedProcess(args,0,'','')

    def config(self,legacy=True,role='iran'):
        self.folder.mkdir(parents=True,exist_ok=True)
        t=dict(id=self.number,name='test-link',role=role,remote_host='198.51.100.1',counter='gre-tunnel',previous_target={'interface':'gre-tunnel'})
        if legacy:
            files=[('units','gre-tunnel.service'),('units','frps.service' if role=='iran' else 'frpc.service'),('frp','frps.toml' if role=='iran' else 'frpc.toml')]
            active={name:True for kind,name in files if kind=='units'}
            t['legacy']=dict(role=role,peer=self.peer,files=files,active=active)
            for kind,name in files:self.engine.save(self.folder/'previous'/kind/name,'saved '+name)
        self.engine.save(self.folder/'config.json',t)
        self.engine.save(self.engine.STATE/'traffic.json',self.traffic)
        for part in ('server','client','ssh'):self.engine.save(self.engine.UNITS/('navalink-'+self.number+'-'+part+'.service'),'owned')
        return t

    def retire(self):
        with contextlib.redirect_stdout(io.StringIO()),patch('pwd.getpwnam',side_effect=KeyError):self.engine.retire()

    def test_clean_install_is_a_noop_without_commands_or_archives(self):
        self.retire();self.assertEqual(self.calls,[]);self.assertFalse(list(self.engine.BACKUPS.iterdir()))

    def test_current_cluster_is_stopped_and_archived_without_touching_regular_tunnels(self):
        self.engine.save(self.engine.STATE/'cluster_v2.json',{'enabled':True,'cluster_secret':'private'})
        self.engine.save(self.engine.STATE/'core.json',{'port':47777})
        self.engine.save(self.engine.UNITS/'NavaTunnel-core.service','owned')
        self.engine.save(self.engine.UNITS/'frps.service','unchanged')
        self.engine.save(self.engine.STATE/'traffic.json',self.traffic)
        self.retire()
        self.assertFalse((self.engine.STATE/'cluster_v2.json').exists())
        self.assertFalse((self.engine.UNITS/'NavaTunnel-core.service').exists())
        self.assertEqual((self.engine.UNITS/'frps.service').read_text(),'unchanged')
        self.assertEqual(self.engine.load(self.engine.STATE/'traffic.json'),self.traffic)
        archive=next(self.engine.BACKUPS.glob('removed-features-*'))
        self.assertEqual(archive.stat().st_mode & 0o777,0o700)
        self.assertEqual((archive/'cluster_v2.json').stat().st_mode & 0o777,0o600)
        self.assertNotIn('private',str(self.calls))
        before=len(self.calls);self.retire();self.assertEqual(len(self.calls),before)

    def test_converted_connection_restores_gre_counter_and_other_tunnels(self):
        self.config();self.engine.save(self.engine.STATE/'peers.json',{'peers':[dict(self.peer,id=2,name='other',gre_if='gre-t2',local_gre='10.200.0.6',peer_gre='10.200.0.5',ports=[8443],frp_port=43000)]})
        self.engine.save(self.engine.UNITS/'frps-2.service','do not change')
        self.retire()
        self.assertFalse(self.folder.exists())
        self.assertEqual(len(self.engine.load(self.engine.STATE/'peers.json')['peers']),2)
        self.assertEqual((self.engine.UNITS/'frps-2.service').read_text(),'do not change')
        self.assertIn(['systemctl','restart','gre-tunnel.service'],self.calls)
        self.assertIn(['systemctl','restart','frps.service'],self.calls)
        self.assertLess(self.calls.index(['systemctl','restart','gre-tunnel.service']),self.calls.index(['systemctl','restart','frps.service']))
        traffic=self.engine.load(self.engine.STATE/'traffic.json')['gre-tunnel']
        self.assertEqual(traffic['download'],123456789);self.assertEqual(traffic['limit'],2000000000)
        self.assertEqual(traffic['interface'],'gre-tunnel');self.assertIsNone(traffic['peer'])

    def test_restore_defers_start_until_the_main_script_rebinds_local_ip(self):
        self.config()
        with patch.dict(os.environ,{'NAVATUNNEL_RESTORE':'1'}):self.retire()
        self.assertTrue((self.engine.UNITS/'gre-tunnel.service').exists())
        self.assertFalse(any(c[:2]==['systemctl','restart'] for c in self.calls))
        self.assertTrue(any('retarget' in c for c in self.calls))

    def test_manual_stop_state_is_respected(self):
        t=self.config();t['legacy']['active']={name:False for name in t['legacy']['active']};self.engine.save(self.folder/'config.json',t)
        self.retire();self.assertFalse(any(c[:2]==['systemctl','restart'] for c in self.calls))

    def test_standalone_connection_is_archived_and_only_its_counter_removed(self):
        self.config(legacy=False);data=self.engine.load(self.engine.STATE/'traffic.json');data['other']=dict(interface='gre-t2',download=42);self.engine.save(self.engine.STATE/'traffic.json',data)
        self.retire()
        data=self.engine.load(self.engine.STATE/'traffic.json');self.assertEqual(data,{'other':{'interface':'gre-t2','download':42}})
        archive=next(self.engine.BACKUPS.glob('removed-features-*'))
        self.assertEqual(json.loads((archive/'traffic-before.json').read_text())['gre-tunnel']['download'],123456789)
        self.assertFalse(any(c[:2]==['systemctl','restart'] for c in self.calls))

    def test_conflicting_rollback_preserves_current_files_and_live_units(self):
        self.config();self.engine.save(self.engine.UNITS/'frps.service','new working service')
        with self.assertRaisesRegex(ValueError,'conflicts'):self.retire()
        self.assertEqual((self.engine.UNITS/'frps.service').read_text(),'new working service')
        self.assertTrue(self.folder.exists());self.assertEqual(self.calls,[])

    def test_invalid_rollback_path_never_writes_outside_managed_directories(self):
        t=self.config();t['legacy']['files']=[['units','../../bad']];self.engine.save(self.folder/'config.json',t)
        with self.assertRaisesRegex(ValueError,'filename'):self.retire()
        self.assertEqual(self.calls,[])

    def test_failed_stop_keeps_state_for_retry(self):
        self.config();original=self.fake_run
        def fail(args,*pos,**kwargs):
            if 'disable' in args:raise subprocess.CalledProcessError(1,args)
            return original(args,*pos,**kwargs)
        self.engine.run=fail
        with self.assertRaises(subprocess.CalledProcessError):self.retire()
        self.assertTrue(self.folder.exists());self.assertTrue(list(self.engine.BACKUPS.glob('removed-features-*')))

    def test_foreign_removes_only_its_ssh_match_block(self):
        self.config(legacy=False,role='foreign')
        before='Port 22\n# NavaTunnel '+self.number+' begin\nMatch User nava'+self.number+'\n    ForceCommand /bin/false\n# NavaTunnel '+self.number+' end\nMatch User unrelated\n    PermitTTY no\n'
        self.engine.SSH_CONFIG.write_text(before)
        keys=self.engine.ROOT_KEYS/'authorized_keys';keys.write_text('keep-root-key\n')
        self.retire()
        self.assertNotIn('nava'+self.number,self.engine.SSH_CONFIG.read_text())
        self.assertIn('Match User unrelated',self.engine.SSH_CONFIG.read_text())
        self.assertEqual(keys.read_text(),'keep-root-key\n')

    def test_invalid_ssh_configuration_is_rolled_back(self):
        t=self.config(legacy=False,role='foreign')
        before='# NavaTunnel '+self.number+' begin\nMatch User nava'+self.number+'\n# NavaTunnel '+self.number+' end\n'
        self.engine.SSH_CONFIG.write_text(before);original=self.fake_run
        def fail(args,*pos,**kwargs):
            if str(args[0])=='/usr/sbin/sshd':raise subprocess.CalledProcessError(1,args)
            return original(args,*pos,**kwargs)
        self.engine.run=fail
        with self.assertRaises(subprocess.CalledProcessError):self.retire()
        self.assertEqual(self.engine.SSH_CONFIG.read_text(),before);self.assertTrue(self.folder.exists())

    def test_foreign_account_name_collision_is_not_deleted(self):
        self.config(legacy=False,role='foreign')
        account=types.SimpleNamespace(pw_dir='/unrelated/home',pw_uid=1111)
        with patch('pwd.getpwnam',return_value=account),self.assertRaisesRegex(ValueError,'ownership'):
            with contextlib.redirect_stdout(io.StringIO()):self.engine.retire()
        self.assertFalse(any(c[0] in ('userdel','pkill') for c in self.calls));self.assertTrue(self.folder.exists())


class RemovedMenusTests(unittest.TestCase):
    def test_legacy_updater_shim_accepts_retirement_only(self):
        script=ROOT/'NavaTunnel-extra.sh'
        for cmd,code in [('cleanup-retired',0),('cleanup-extra-tools',0),('navalink',1),('cluster',1)]:
            result=subprocess.run(['bash',str(script),cmd],capture_output=True,text=True)
            self.assertEqual(result.returncode,code)

    def test_main_help_has_no_removed_features(self):
        result=subprocess.run(['bash',str(ROOT/'NavaTunnel.sh'),'--help'],capture_output=True,text=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        for text in ('NavaLink','cluster','core-service','6501'):self.assertNotIn(text,result.stdout)
