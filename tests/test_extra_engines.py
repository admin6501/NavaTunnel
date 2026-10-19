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
        for name in ('STATE','UNITS','BIN','FRP','ROOT_KEYS','CARRIER_HOME'):
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


class NetworkToolsTests(ExtraHarness):
    def test_mux_setting_is_saved_without_restarting_services_or_losing_tokens(self):
        path=self.engine.FRP/'frpc.toml';path.write_text('auth.token="preserved"\ntransport.tcpMux = true\n[[proxies]]\nname="one"\ntype="tcp"\nlocalPort=443\nremotePort=443\n')
        self.invoke(['tcp-mux','off'])
        cfg=tomllib.loads(path.read_text());self.assertFalse(cfg['transport']['tcpMux']);self.assertEqual(cfg['auth']['token'],'preserved')
        self.assertFalse(self.engine.load(self.engine.STATE/'perf.json',{})['tcp_mux'])
        self.assertFalse(any('restart' in cmd for cmd,_ in self.calls))

    def test_mtu_probe_stays_below_interface_mtu_and_is_readonly_by_default(self):
        original=self.fake_run
        def run(args,check=True,**kwargs):
            result=original(args,check=check,**kwargs)
            if args[0]=='ip':result.stdout='[{"mtu":1380}]'
            if args[0]=='ping':result.returncode=0 if int(args[args.index('-s')+1])<=1172 else 1
            return result
        self.engine.run=run
        out=io.StringIO()
        with contextlib.redirect_stdout(out):self.invoke(['path-mtu','--peer','10.200.0.1'])
        self.assertIn('1200',out.getvalue())
        probes=[int(cmd[cmd.index('-s')+1]) for cmd,_ in self.calls if cmd[0]=='ping']
        self.assertLessEqual(max(probes),1352)
        self.assertFalse(any(cmd[0].endswith('/NavaTunnel') for cmd,_ in self.calls))

    def test_no_icmp_baseline_means_no_mtu_mutation(self):
        def run(args,check=True,**kwargs):return subprocess.CompletedProcess(args,1 if args[0]=='ping' else 0,'[{"mtu":1380}]' if args[0]=='ip' else '','')
        self.engine.run=run
        with self.assertRaises(ValueError):self.invoke(['path-mtu','--peer','10.200.0.1','--apply'])

    def test_pool_advisor_never_changes_settings_or_restarts(self):
        self.invoke(['pool'])
        self.assertTrue(all(cmd[0]=='journalctl' for cmd,_ in self.calls))


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
            for page,choice in (('navalink','2'),('network','3')):
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
        with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):self.invoke(['menu','cluster'])

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

    def test_each_upstream_submenu_opens_and_returns(self):
        # Exercise the real Bash/heredoc stdin path for every added menu.
        source=(ROOT/'NavaTunnel-extra.sh').read_text().replace("STATE=Path('/etc/gre-panel')",'STATE=Path('+repr(str(self.root))+')').replace('if os.geteuid()!=0:', 'if False:')
        helper=self.root/'upstream.sh';helper.write_text(source)
        for topic in range(1,11):
            with self.subTest(topic=topic):
                result=subprocess.run(['bash',str(helper),'menu','upstream'],input=str(topic)+'\n0\n0\n',text=True,capture_output=True,timeout=5)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertGreaterEqual(result.stdout.count('0) Back'),3)
                self.assertNotIn('operation failed',result.stderr)
