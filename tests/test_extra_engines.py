import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import tomllib
import types
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]


class ExtraHarness(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.engine=types.ModuleType('extra_test')
        code=(ROOT/'NavaTunnel-extra.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
        exec(compile(code,'NavaTunnel-extra.sh','exec'),self.engine.__dict__)
        for name in ('STATE','UNITS','BIN','FRP','ROOT_KEYS','CARRIER_HOME','BACKUPS','SYSCTL'):
            path=self.root/name;path.mkdir();setattr(self.engine,name,path)
        self.engine.EXTRA=self.engine.BIN/'NavaTunnel-extra.sh'
        self.engine.SSH_CONFIG=self.root/'sshd_config';self.engine.SSH_CONFIG.write_text('Port 22\n')
        self.calls=[]
        self.engine.run=self.fake_run
        self.record=dict(id='012345abcdef',name='sample',role='iran',local_pub='203.0.113.1',remote_host='198.51.100.1',ssh_port=2222,control_port=42000,ports=[443,8443],token='a'*48,stopped=False,public_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZm test')

    def fake_run(self,args,check=True,input=None,**kwargs):
        args=list(map(str,args));self.calls.append((args,input))
        output=''
        if '-T' in args and args[0].endswith('/sshd'):output='allowtcpforwarding remote\npermitopen none\n'
        if args[0]=='ip':output='[]'
        return subprocess.CompletedProcess(args,0,output,'')

    def invoke(self,args):
        with patch('os.geteuid',return_value=0):return self.engine.invoke(args)


class NavaLinkTests(ExtraHarness):
    def test_server_and_client_toml_have_distinct_roles_and_random_token(self):
        server=tomllib.loads(self.engine.nava_config(self.record))
        client=tomllib.loads(self.engine.nava_config(dict(self.record,role='foreign')))
        self.assertEqual(server['bindAddr'],'127.0.0.1');self.assertEqual(server['proxyBindAddr'],'0.0.0.0')
        self.assertFalse(server['transport']['tcpMux']);self.assertEqual(server['auth']['token'],'a'*48)
        self.assertNotIn('bindPort',client);self.assertNotIn('proxyBindAddr',client)
        self.assertTrue(client['transport']['tls']['enable'])
        self.assertEqual({p['type'] for p in client['proxies']},{'tcp','udp'})
        self.assertEqual(len(client['proxies']),4)

    def test_converted_client_retains_port_mapping_and_proxy_options(self):
        t=dict(self.record,role='foreign',proxy_sections='[[proxies]]\nname="custom"\ntype="tcp"\nlocalIP="127.0.0.2"\nlocalPort=9443\nremotePort=443\ntransport.proxyProtocolVersion="v2"\n')
        cfg=tomllib.loads(self.engine.nava_config(t))
        custom=next(p for p in cfg['proxies'] if p['name']=='custom')
        self.assertEqual(custom['localPort'],9443);self.assertEqual(custom['localIP'],'127.0.0.2')
        self.assertEqual(custom['transport']['proxyProtocolVersion'],'v2')
        self.assertEqual(len(cfg['proxies']),4)

    def test_carrier_uses_dedicated_account_verified_host_key_and_only_reverse_loopback(self):
        self.engine.install_nava(self.record)
        unit=(self.engine.UNITS/'navalink-012345abcdef-ssh.service').read_text()
        self.assertIn('StrictHostKeyChecking=yes',unit);self.assertIn('UserKnownHostsFile=',unit)
        self.assertIn('-R 127.0.0.1:42000:127.0.0.1:42000',unit)
        self.assertIn('nava012345abcdef@198.51.100.1',unit);self.assertNotIn('root@',unit)
        self.assertNotIn('-L ',unit)
        config=self.engine.STATE/'navalink/012345abcdef/config.json'
        self.assertEqual(config.stat().st_mode & 0o777,0o600)

    def test_foreign_carrier_account_cannot_execute_commands_or_open_local_forwards(self):
        home=self.engine.CARRIER_HOME/self.record['id']
        account=types.SimpleNamespace(pw_dir=str(home),pw_uid=os.getuid(),pw_gid=os.getgid())
        with patch('pwd.getpwnam',return_value=account):self.engine.carrier_account(self.record)
        text=self.engine.SSH_CONFIG.read_text()
        self.assertIn('AllowTcpForwarding remote',text);self.assertIn('PermitOpen none',text)
        self.assertIn('ForceCommand /bin/false',text);self.assertIn('PermitTTY no',text)
        self.assertIn('PermitListen 127.0.0.1:42000',text)
        keys=(home/'.ssh/authorized_keys').read_text()
        self.assertIn('restrict,port-forwarding,permitlisten=',keys)
        self.assertNotIn('permitopen="none"',keys)  # invalid authorized_keys syntax
        self.assertEqual(self.engine.SSH_CONFIG.read_text().splitlines()[0],'Port 22')

    def test_bad_effective_ssh_policy_rolls_back_config_and_authorization(self):
        home=self.engine.CARRIER_HOME/self.record['id']
        account=types.SimpleNamespace(pw_dir=str(home),pw_uid=os.getuid(),pw_gid=os.getgid())
        before=self.engine.SSH_CONFIG.read_bytes()
        original=self.fake_run
        def run(args,**kwargs):
            result=original(args,**kwargs)
            if '-T' in args and str(args[0]).endswith('/sshd'):result.stdout='allowtcpforwarding yes\n'
            return result
        self.engine.run=run
        with patch('pwd.getpwnam',return_value=account),self.assertRaises(ValueError):self.engine.carrier_account(self.record)
        self.assertEqual(self.engine.SSH_CONFIG.read_bytes(),before)
        self.assertFalse((home/'.ssh/authorized_keys').exists())

    def test_invalid_id_or_bundle_is_rejected_without_commands(self):
        for args in (['navalink','stop','--id','../../root'],['navalink','join','--bundle','not_a_bundle']):
            with self.assertRaises(ValueError):self.invoke(args)
        self.assertEqual(self.calls,[])

    def test_status_does_not_print_token_or_private_key(self):
        self.engine.install_nava(self.record)
        out=io.StringIO()
        with contextlib.redirect_stdout(out):self.invoke(['navalink','status'])
        self.assertNotIn('a'*48,out.getvalue());self.assertNotIn(self.record['public_key'],out.getvalue())
        self.assertIn('all IPv4 wire traffic',out.getvalue())

    def test_converting_one_peer_preserves_others_and_keeps_private_rollback(self):
        t=dict(self.record)
        peer=dict(id=1,gre_if='gre-tunnel',frps_svc='frps',remote_pub=t['remote_host'],local_pub=t['local_pub'],token='legacy-token',ports=[443])
        other=dict(id=2,gre_if='gre-t2',frps_svc='frps-2',remote_pub='198.51.100.2')
        self.engine.save(self.engine.STATE/'peers.json',dict(peers=[peer,other]))
        self.engine.save(self.engine.STATE/'traffic.json',{'gre-tunnel':dict(interface='gre-tunnel',download=100,upload=200,mode='both',limit=900)})
        for file in ('frps.service','gre-tunnel.service','frps-2.service'):(self.engine.UNITS/file).write_text('original '+file)
        (self.engine.FRP/'frps.toml').write_text('auth.token="legacy-token"\n')
        self.engine.suspend_legacy(t,1)
        self.assertEqual(self.engine.load(self.engine.STATE/'peers.json',{})['peers'],[other])
        self.assertTrue((self.engine.UNITS/'frps-2.service').exists())
        self.assertFalse((self.engine.UNITS/'frps.service').exists())
        self.assertEqual(t['counter'],'gre-tunnel')
        self.engine.resume_legacy(t)
        self.assertEqual({p['id'] for p in self.engine.load(self.engine.STATE/'peers.json',{})['peers']},{1,2})
        self.assertEqual((self.engine.FRP/'frps.toml').read_text(),'auth.token="legacy-token"\n')
        self.assertTrue(any('retarget' in cmd and '--interface' in cmd for cmd,_ in self.calls))
        self.assertEqual(self.engine.load(self.engine.STATE/'traffic.json',{})['gre-tunnel']['download'],100)

    def test_mismatched_conversion_is_rejected_before_stopping_any_unit(self):
        self.engine.save(self.engine.STATE/'peers.json',dict(peers=[dict(id=1,remote_pub='198.51.100.9')]))
        with self.assertRaises(ValueError):self.engine.suspend_legacy(dict(self.record),1)
        self.assertEqual(self.calls,[])

    def test_restore_does_not_start_manually_stopped_connection(self):
        t=dict(self.record,stopped=True);self.engine.install_nava(t)
        self.calls=[];self.engine.ensure_cores=lambda:None;self.engine.wire_counter=lambda *a:None
        self.invoke(['navalink','restore'])
        self.assertFalse(any('start' in cmd for cmd,_ in self.calls))




from test_regressions import ScriptHarness

class ReservedConversionTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.peers=self.peers[1:];self.write_peers()
        folder=self.state/'navalink/012345abcdef';folder.mkdir(parents=True)
        (folder/'config.json').write_text(json.dumps(dict(id='012345abcdef',role='iran',name='NavaLink',ports=[9443],control_port=42000,legacy=dict(peer=dict(id=1,local_gre='10.200.0.2',peer_gre='10.200.0.1')))))

    def test_converted_peer_id_and_gre_addresses_are_reserved_for_rollback(self):
        result=self.run_shell('peer_next_id; menu_gre_pair')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.splitlines()[0],'3')
        self.assertEqual(result.stdout.splitlines()[1],'10.200.0.6 10.200.0.5')

    def test_navalink_service_and_control_ports_remain_reserved(self):
        result=self.run_shell('peer_ports_used')
        self.assertIn('9443:NavaLink',result.stdout)
        result=self.run_shell('peer_control_port_check 42000 0')
        self.assertNotEqual(result.returncode,0)


class HelperInputTests(unittest.TestCase):
    def test_real_shell_wrapper_preserves_menu_input(self):
        # Keep the actual heredoc/exec path, replacing only privileged setup.
        with tempfile.TemporaryDirectory() as folder:
            source=(ROOT/'NavaTunnel-extra.sh').read_text()
            source=source.replace("STATE=Path('/etc/gre-panel')", "STATE=Path("+repr(folder)+")")
            source=source.replace("if os.geteuid()!=0:", "if False:")
            script=Path(folder)/'helper.sh';script.write_text(source)
            for page,choice in (('navalink','2'),):
                with self.subTest(page=page):
                    result=subprocess.run(['bash',str(script),'menu',page],input=choice+'\n\n0\n',text=True,capture_output=True,timeout=5)
                    self.assertEqual(result.returncode,0,result.stderr)
                    self.assertGreaterEqual(result.stdout.count('0) Back'),2)
                    self.assertNotIn('operation failed',result.stderr)

class RetiredCleanupTests(ExtraHarness):
    def test_empty_installation_is_a_noop_and_preserves_key_format(self):
        path=self.engine.ROOT_KEYS/'authorized_keys';path.write_text('unrelated-key')
        self.engine.cleanup_retired()
        self.assertEqual(self.calls,[]);self.assertEqual(path.read_text(),'unrelated-key')

    def test_cleanup_removes_only_owned_state_units_rules_and_health_keys(self):
        state=self.engine.STATE
        self.engine.save(state/'cluster.json',dict(enabled=True,ports=[443]))
        self.engine.save(state/'traffic.json',dict(untouched=True))
        self.engine.save(state/'navalink'/'012345abcdef'/'config.json',self.record)
        for suffix in ('service','timer'):(self.engine.UNITS/('NavaTunnel-cluster.'+suffix)).write_text('old')
        keys=self.engine.ROOT_KEYS/'authorized_keys'
        keys.write_text('other-root-key\nrestrict,command="health" ssh-ed25519 AAA nava-cluster-012345abcdef\n')
        original=self.fake_run
        def runner(args,*pos,**kwargs):
            result=original(args,*pos,**kwargs)
            if '-S' in args:
                if args[-1]=='PREROUTING':result.stdout='-A PREROUTING -p tcp --dport 443 -m comment --comment navatunnel-cluster -j NAVA-CLUSTER\n-A PREROUTING -p tcp --dport 80 -j OTHER\n'
                if args[-1]=='POSTROUTING':result.stdout='-A POSTROUTING -m connmark --mark 0x4e560000/0xffff0000 -m conntrack --ctstate DNAT -j MASQUERADE\n-A POSTROUTING -o eth0 -j MASQUERADE\n'
            return result
        self.engine.run=runner;self.engine.cleanup_retired()
        self.assertEqual(keys.read_text(),'other-root-key\n')
        self.assertFalse((state/'cluster.json').exists())
        self.assertTrue((state/'traffic.json').exists());self.assertTrue((state/'navalink'/'012345abcdef'/'config.json').exists())
        for cmd,_ in self.calls:
            if '-F' in cmd or '-X' in cmd:self.assertEqual(cmd[-1],'NAVA-CLUSTER')
            if '-D' in cmd:self.assertTrue('navatunnel-cluster' in cmd or '0x4e560000/0xffff0000' in cmd)
        self.calls=[];self.engine.cleanup_retired();self.assertEqual(self.calls,[])

    def test_failure_preserves_configuration_for_retry(self):
        self.engine.save(self.engine.STATE/'cluster.json',dict(enabled=True))
        def fail(*args,**kwargs):raise ValueError('firewall unavailable')
        self.engine.run=fail
        with self.assertRaises(ValueError):self.engine.cleanup_retired()
        self.assertTrue((self.engine.STATE/'cluster.json').exists())

    def test_removed_commands_and_menu_are_not_available(self):
        with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):self.invoke(['cluster','enable'])
        with patch('builtins.input',return_value='0'),contextlib.redirect_stdout(io.StringIO()):self.invoke(['menu','cluster'])

class UpstreamToolsTests(ExtraHarness):
    def test_direct_mode_only_installs_tcp_ssh_unit(self):
        t=dict(self.record,mode='direct')
        self.engine.install_nava(t)
        self.assertEqual(self.engine.names(t),['navalink-012345abcdef-ssh.service'])
        self.assertEqual(self.engine.names(dict(t,role='foreign')),[])
        command=list(map(str,self.engine.ssh_carrier_command(t)))
        self.assertNotIn('-R',command)
        self.assertIn('0.0.0.0:443:127.0.0.1:443',command)
        self.assertIn('StrictHostKeyChecking=yes',command)
        self.assertFalse(list((self.engine.STATE/'navalink'/t['id']).glob('*.toml')))

    def test_per_link_pool_is_preserved(self):
        conf=tomllib.loads(self.engine.nava_config(dict(self.record,role='foreign',pool_count=73)))
        self.assertEqual(conf['transport']['poolCount'],73)

    def test_cluster_menu_status_is_read_only_and_no_other_tools_are_shown(self):
        with patch('builtins.input',side_effect=['1','','0']),contextlib.redirect_stdout(io.StringIO()) as output:
            self.engine.menu('cluster')
        calls=[args for args,_ in self.calls]
        self.assertTrue(any(args[1:4]==['advanced','cluster','status'] for args in calls),calls)
        for label in ('Reverse-path doctor','Auto Pool','Benchmark','Connectivity Rescue','State-change alerts','History, usage'):
            self.assertNotIn(label,output.getvalue())

    def test_removed_commands_are_rejected(self):
        for args in (['path-mtu','--peer','10.200.0.1'],['tcp-mux','status'],['pool'],['menu','upstream'],['menu','network']):
            with self.subTest(args=args),contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):self.engine.invoke(args)


class RemovedToolsMigrationTests(ExtraHarness):
    def test_empty_server_is_a_noop(self):
        self.engine.cleanup_extra_tools()
        self.assertEqual(self.calls,[])
        self.assertEqual(list(self.engine.BACKUPS.iterdir()),[])

    def test_cleanup_archives_removed_state_and_preserves_cluster_navalink_and_quotas(self):
        state=self.engine.STATE
        preserved={'cluster_v2.json':{'enabled':True,'cluster_secret':'keep-private'},'traffic.json':{'gre-tunnel':{'download':123,'limit':456}},'peers.json':{'peers':[{'id':1,'gre_if':'gre-tunnel'}]},'navalink/012345abcdef/config.json':self.record}
        for name,value in preserved.items():self.engine.save(state/name,value)
        self.engine.save(state/'alerts.json',{'enabled':True,'webhook_url':'https://example.test/private'})
        self.engine.save(state/'rescue.json',{'role':'origin','token':'secret'})
        self.engine.save(state/'auto_pool.json',{'pool_count':80})
        self.engine.save(state/'perf.json',{'auto_pool':True,'proxy_encryption':True,'chaff_profile':'off'})
        self.engine.save(state/'core.json',{'port':47777,'metrics_token':'secret','revpath_auto':True})
        self.engine.save(self.engine.FRP/'dial.env','DIAL_MODE=auto\n')
        self.engine.save(self.engine.UNITS/'navatunnel-rescue-frpc.service','owned unit')
        self.engine.save(self.engine.UNITS/'NavaTunnel-core.service','retained Cluster unit')
        self.engine.save(self.engine.UNITS/'frps.service','retained FRP unit')
        self.engine.save(self.engine.UNITS/'frps-wss.service','retained FRP TLS front')
        before={name:(state/name).read_bytes() for name in preserved}
        with patch('shutil.which',return_value='/usr/sbin/nft'):
            self.engine.cleanup_extra_tools()
        for name,value in before.items():self.assertEqual((state/name).read_bytes(),value)
        for name in ('alerts.json','rescue.json','auto_pool.json'):self.assertFalse((state/name).exists())
        self.assertEqual(json.loads((state/'core.json').read_text()),{'port':47777})
        self.assertEqual(json.loads((state/'perf.json').read_text()),{'proxy_encryption':True,'chaff_profile':'off'})
        for name in ('NavaTunnel-core.service','frps.service','frps-wss.service'):self.assertTrue((self.engine.UNITS/name).exists())
        self.assertTrue((state/'core-restart-required').exists())
        calls=[a for a,_ in self.calls]
        self.assertIn(['systemctl','stop','NavaTunnel-core.service'],calls)
        self.assertNotIn(['systemctl','disable','--now','NavaTunnel-core.service'],calls)
        self.assertFalse(any(a[0]=='iptables' for a in calls),calls)
        self.assertEqual([a[-1] for a in calls if a[:3]==['nft','delete','table']],['navatunnel_rescue','navatunnel_dnat'])
        archive=next(self.engine.BACKUPS.iterdir())
        self.assertEqual(archive.stat().st_mode & 0o777,0o700)
        self.assertEqual((archive/'alerts.json').stat().st_mode & 0o777,0o600)
        self.assertEqual(json.loads((archive/'rescue.json').read_text())['token'],'secret')
        calls_before=len(self.calls);self.engine.cleanup_extra_tools();self.assertEqual(len(self.calls),calls_before)

    def test_failed_owned_service_stop_is_reported_and_keeps_configuration(self):
        self.engine.save(self.engine.STATE/'rescue.json',{'role':'entry'})
        self.engine.save(self.engine.UNITS/'navatunnel-rescue-frpc.service','owned')
        def fail(args,**kwargs):
            if list(map(str,args))==['systemctl','disable','--now','navatunnel-rescue-frpc.service']:raise ValueError('stop failed')
            return self.fake_run(args,**kwargs)
        self.engine.run=fail
        with self.assertRaises(ValueError):self.engine.cleanup_extra_tools()
        self.assertTrue((self.engine.STATE/'rescue.json').exists())
        self.assertTrue((self.engine.UNITS/'navatunnel-rescue-frpc.service').exists())

    def test_active_gre_wss_is_moved_to_fou_without_rewriting_other_peers(self):
        self.engine.save(self.engine.STATE/'wss_carrier.json',{'enabled':True,'gre_interface':'gre-t3'})
        self.engine.save(self.engine.STATE/'carrier.json',{'active_carrier':'wss:8443','mode':'wss:8443','fou_port1':443,'candidates':['direct','wss:8443','fou:443']})
        peers={'peers':[{'id':1,'gre_if':'gre-tunnel','carrier':'direct'},{'id':3,'gre_if':'gre-t3','carrier':'wss:8443'}]}
        self.engine.save(self.engine.STATE/'peers.json',peers)
        with patch('subprocess.run',return_value=subprocess.CompletedProcess([],0,'','')) as migrate:
            self.engine.cleanup_extra_tools()
        args=migrate.call_args.args[0]
        self.assertEqual(args,[str(self.engine.BIN/'NavaTunnel'),'retire-wss-carrier','gre-t3','443'])
        self.assertEqual(migrate.call_args.kwargs['env']['NAVATUNNEL_RETIRING_TOOLS'],'1')
        current=json.loads((self.engine.STATE/'peers.json').read_text())
        self.assertEqual(current['peers'][0],peers['peers'][0])
        self.assertEqual(current['peers'][1]['carrier'],'fou:443')
        carrier=json.loads((self.engine.STATE/'carrier.json').read_text())
        self.assertEqual(carrier['active_carrier'],'fou:443')
        self.assertEqual(carrier['candidates'],['direct','fou:443'])

    def test_current_cluster_daemon_is_not_stopped_during_retirement(self):
        self.engine.save(self.engine.STATE/'alerts.json',{'enabled':True})
        self.engine.save(self.engine.UNITS/'NavaTunnel-core.service','retained')
        def run(args,*pos,**kwargs):
            result=self.fake_run(args,*pos,**kwargs)
            if list(map(str,args))[1:]==['daemon','ping']:result.stdout='{"version":"v1.1.1"}'
            return result
        self.engine.run=run
        self.engine.cleanup_extra_tools()
        self.assertFalse((self.engine.STATE/'core-restart-required').exists())
        self.assertNotIn(['systemctl','stop','NavaTunnel-core.service'],[a for a,_ in self.calls])
