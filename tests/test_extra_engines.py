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

    def test_read_only_cluster_key_does_not_replace_unrelated_root_keys(self):
        key=self.engine.ROOT_KEYS/'authorized_keys';key.write_text('existing-root-key\n')
        self.engine.authorize(self.record['public_key'],'nava-cluster-test','restrict,command="/bin/false"')
        self.engine.authorize(self.record['public_key'],'nava-cluster-test','restrict,command="/bin/false"')
        text=key.read_text();self.assertIn('existing-root-key',text);self.assertEqual(text.count('nava-cluster-test'),1)
        self.assertEqual(key.stat().st_mode & 0o777,0o600)

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


class ClusterTests(ExtraHarness):
    def test_health_debounce_and_recovery_require_multiple_checks(self):
        state=None
        for _ in range(2):state=self.engine.debounced(state,False,3,2,True)
        self.assertTrue(state['healthy'])
        state=self.engine.debounced(state,False,3,2,True);self.assertFalse(state['healthy'])
        state=self.engine.debounced(state,True,3,2);self.assertFalse(state['healthy'])
        state=self.engine.debounced(state,True,3,2);self.assertTrue(state['healthy'])

    def config(self):return dict(mode='failover',ports=[443],nodes=[dict(host='198.51.100.1',weight=2,ssh_port=22),dict(host='198.51.100.2',weight=1,ssh_port=22)],local_weight=1,failures=3,recoveries=3,enabled=True)

    def test_failover_stays_local_while_local_is_healthy(self):
        cfg=self.config();health={'local':{'healthy':True},'198.51.100.1':{'healthy':True}}
        self.assertEqual(self.engine.choose_targets(cfg,health),[])
        health['local']['healthy']=False
        self.assertEqual(self.engine.choose_targets(cfg,health),[dict(host='198.51.100.1',weight=2)])

    def test_low_latency_selects_healthy_candidate_only(self):
        cfg=self.config();cfg['mode']='lowest-latency'
        health={'local':{'healthy':False},'198.51.100.1':dict(healthy=False,latency_ms=1),'198.51.100.2':dict(healthy=True,latency_ms=90)}
        self.assertEqual(self.engine.choose_targets(cfg,health),[dict(host='198.51.100.2',weight=1)])

    def test_weighted_nat_keeps_local_share_and_preserves_other_chains(self):
        cfg=self.config();cfg['mode']='weighted'
        targets=self.engine.choose_targets(cfg,{'local':{'healthy':True},'198.51.100.1':{'healthy':True}})
        text=self.engine.cluster_rules(targets)
        self.assertIn('--probability 0.3333333333',text);self.assertIn('-j RETURN',text)
        self.assertIn('DNAT --to-destination 198.51.100.1',text)
        self.assertNotIn('-F PREROUTING',text);self.assertNotIn(':PREROUTING',text)
        self.engine.cluster_firewall(cfg,targets)
        self.assertIn('--noflush',self.calls[0][0])

    def test_cluster_is_disabled_after_initial_configuration(self):
        self.invoke(['cluster','init','--ports','443,8443'])
        cfg=self.engine.load(self.engine.STATE/'cluster.json',{})
        self.assertFalse(cfg['enabled']);self.assertEqual(self.calls,[])

    def test_cluster_refuses_its_own_public_ip(self):
        self.engine.save(self.engine.STATE/'peers.json',dict(peers=[dict(local_pub='203.0.113.1')]))
        with self.assertRaises(ValueError):self.invoke(['cluster','add','--host','203.0.113.1'])

    def test_boot_change_reapplies_saved_failover_rules(self):
        cfg=self.config();self.engine.save(self.engine.STATE/'cluster.json',cfg)
        self.engine.save(self.engine.STATE/'cluster-runtime.json',dict(boot='old-boot',health={},targets=[]))
        self.engine.local_health=lambda:dict(healthy=True,ports=[443])
        applied=[];self.engine.cluster_firewall=lambda config,targets:applied.append(targets)
        self.invoke(['cluster','tick'])
        self.assertEqual(applied,[[]])
        self.assertEqual(self.engine.load(self.engine.STATE/'cluster-runtime.json',{})['boot'],self.engine.BOOT)

    def test_cluster_disable_clears_only_its_owned_rules(self):
        cfg=self.config();self.engine.save(self.engine.STATE/'cluster.json',cfg)
        self.invoke(['cluster','disable'])
        for cmd,body in self.calls:
            self.assertNotIn('-F',cmd)
            if '-D' in cmd:self.assertTrue('navatunnel-cluster' in cmd or self.engine.MARK in cmd)
        self.assertFalse(self.engine.load(self.engine.STATE/'cluster.json',{})['enabled'])

    def test_healthy_service_requires_a_control_session_not_only_active_process(self):
        self.engine.save(self.engine.STATE/'peers.json',dict(peers=[dict(peer_gre='10.200.0.1',frp_port=42128,frps_svc='frps',ports=[443],gre_if='gre-tunnel')]))
        self.assertFalse(self.engine.local_health()['healthy'])
        self.engine.session_up=lambda *a:True
        health=self.engine.local_health();self.assertTrue(health['healthy']);self.assertEqual(health['ports'],[443])


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
