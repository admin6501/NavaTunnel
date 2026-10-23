import json
from pathlib import Path
from test_regressions import ScriptHarness


class MultiForeignTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.peers=[];self.write_peers()
        for p in self.units.glob('*'):p.unlink()
        for p in self.config.glob('*'):p.unlink()
        self.one=dict(id=1,name='Iran-A',remote_pub='192.0.2.10',local_pub='198.51.100.9',frp_port=7000,local_gre='10.201.0.1',peer_gre='10.201.0.2',ports=[443,8443],gre_if='gre-tunnel',frpc_svc='frpc')
        self.two=dict(self.one,id=2,name='Iran-B',remote_pub='192.0.2.20',local_gre='10.201.0.5',peer_gre='10.201.0.6',gre_if='gre-t2',frpc_svc='frpc-2')
        self.record_path=self.state/'foreign.json'

    def save(self,rows):self.record_path.write_text(json.dumps({'connections':rows}))

    def files(self,row):
        (self.config/(row['frpc_svc']+'.toml')).write_text('# NavaTunnel GRE interface: '+row['gre_if']+'\nserverAddr = "'+row['peer_gre']+'"\nserverPort = '+str(row['frp_port'])+'\nauth.token = "privateToken123"\ntransport.protocol = "tcp"\n[[proxies]]\nname="tcp_443"\ntype="tcp"\nlocalIP="127.0.0.1"\nlocalPort=443\nremotePort=443\n')
        (self.units/(row['gre_if']+'.service')).write_text('[Unit]\n[Service]\nExecStart=/bin/sh -c \'ip tunnel add '+row['gre_if']+' mode gre local '+row['local_pub']+' remote '+row['remote_pub']+'; ip addr replace '+row['local_gre']+'/30 dev '+row['gre_if']+'; ip route replace '+row['peer_gre']+'/32 dev '+row['gre_if']+'\'\n[Install]\n')
        (self.units/(row['frpc_svc']+'.service')).write_text('[Unit]\n[Service]\nExecStart=client\n[Install]\n')

    def plan(self,row,force=0,selected=''):
        return self.run_shell('FOREIGN_TOKEN=privateToken123 foreign_registry plan "'+row['local_pub']+'" "'+row['remote_pub']+'" '+str(row['frp_port'])+' '+row['local_gre']+' '+row['peer_gre']+' "443 8443" '+str(force)+' "'+str(selected)+'" ""')

    def test_second_iran_reuses_service_and_control_ports_with_separate_files(self):
        self.save([self.one]);self.files(self.one);before=(self.config/'frpc.toml').read_bytes()
        result=self.plan(self.two)
        self.assertEqual(result.returncode,0,result.stderr)
        planned=json.loads(result.stdout)
        self.assertEqual((planned['id'],planned['gre_if'],planned['frpc_svc']),(2,'gre-t2','frpc-2'))
        self.assertEqual(planned['ports'],[443,8443]);self.assertEqual(planned['frp_port'],7000)
        self.assertEqual((self.config/'frpc.toml').read_bytes(),before)

    def test_import_legacy_client_preserves_files_and_counters(self):
        self.files(self.one);before={p:p.read_bytes() for p in list(self.units.glob('*'))+list(self.config.glob('*'))}
        usage=self.state/'traffic.json';usage.write_text('{"counter":{"download":12345,"limit":9000}}');saved=usage.read_bytes()
        result=self.run_shell('foreign_registry import; foreign_registry list')
        self.assertEqual(result.returncode,0,result.stderr)
        records=json.loads(result.stdout);self.assertEqual(len(records),1)
        self.assertEqual(records[0]['gre_if'],'gre-tunnel');self.assertEqual(records[0]['remote_pub'],self.one['remote_pub'])
        self.assertEqual(self.record_path.stat().st_mode&0o777,0o600)
        for p,content in before.items():self.assertEqual(p.read_bytes(),content)
        self.assertEqual(usage.read_bytes(),saved)

    def test_overlapping_gre_addresses_rejected_even_with_force(self):
        self.save([self.one]);self.files(self.one)
        conflict=dict(self.two,local_gre=self.one['local_gre'],peer_gre=self.one['peer_gre'])
        # Different token means this is not the same Iran migrating to another public IP.
        result=self.plan(conflict,force=0)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('GRE address conflict',result.stderr);self.assertIn('peer-addresses',result.stderr)
        self.assertEqual(len(json.loads(self.record_path.read_text())['connections']),1)

    def test_same_iran_requires_force_and_updates_its_existing_identity_only(self):
        self.save([self.one,self.two]);self.files(self.one);self.files(self.two)
        result=self.plan(self.two);self.assertNotEqual(result.returncode,0)
        result=self.plan(self.two,force=1);self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['frpc_svc'],'frpc-2')

    def test_migrated_iran_matches_original_token_and_inner_pair(self):
        self.save([self.one,self.two]);self.files(self.one);self.files(self.two)
        moved=dict(self.two,remote_pub='192.0.2.99')
        result=self.plan(moved,force=1);self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['id'],2)

    def test_explicit_unknown_id_and_invalid_network_fail_without_writes(self):
        self.save([self.one]);self.files(self.one);before=self.record_path.read_bytes()
        self.assertNotEqual(self.plan(self.two,force=1,selected=999).returncode,0)
        self.assertNotEqual(self.plan(dict(self.two,peer_gre='10.202.0.2')).returncode,0)
        self.assertEqual(self.record_path.read_bytes(),before)

    def test_interface_and_token_operations_use_selected_client_only(self):
        self.save([self.one,self.two]);self.files(self.one);self.files(self.two)
        result=self.run_shell('cli_foreign_manage 2 status','systemctl() { echo active; }')
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn('10.201.0.6:7000',result.stdout);self.assertIn('frpc-2',result.stdout)
        self.assertNotIn('privateToken123',result.stdout)
        result=self.run_shell('cli_foreign_manage 2 token')
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn('privateToken123',result.stdout)

    def test_restart_start_stop_are_scoped(self):
        self.save([self.one,self.two]);self.files(self.one);self.files(self.two)
        result=self.run_shell('cli_foreign_manage 2 restart','systemctl() { echo "$*"; }')
        self.assertIn('restart gre-t2.service',result.stdout);self.assertIn('restart frpc-2.service',result.stdout)
        self.assertNotIn('restart frpc.service',result.stdout);self.assertNotIn('gre-tunnel.service',result.stdout)
        result=self.run_shell('cli_foreign_manage 2 start','systemctl() { echo "$*"; }')
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn('start frpc-2.service',result.stdout)
        (self.state/'stopped/gre-t2').write_text('chaff=0\n')
        result=self.run_shell('cli_foreign_manage 2 restart')
        self.assertNotEqual(result.returncode,0);self.assertIn('stopped',result.stderr)

    def test_new_connection_failure_cleans_only_its_own_resources(self):
        self.save([self.one]);self.files(self.one);before=(self.config/'frpc.toml').read_bytes()
        result=self.run_shell('_setup_foreign_full 198.51.100.9 192.0.2.20 7000 privateToken123 10.201.0.5 10.201.0.6 "443 8443"', '_setup_foreign_one() { echo partial > "${CONFIG_DIR}/${FRPC_SERVICE}.toml"; return 1; }')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.config/'frpc.toml').read_bytes(),before)
        self.assertFalse((self.config/'frpc-2.toml').exists())
        self.assertEqual(len(json.loads(self.record_path.read_text())['connections']),1)

    def test_registry_commit_does_not_reset_other_connection(self):
        self.save([self.one]);result=self.run_shell('FOREIGN_RECORD=\''+json.dumps(self.two)+'\' foreign_registry commit')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(self.record_path.read_text())['connections'][0],self.one)

    def test_failed_replacement_restores_selected_files_and_keeps_other_client(self):
        self.save([self.one,self.two]);self.files(self.one);self.files(self.two)
        before={p:p.read_bytes() for p in list(self.config.glob('*'))+list(self.units.glob('*'))}
        result=self.run_shell('FORCE=1 _setup_foreign_full 198.51.100.9 192.0.2.20 7000 privateToken123 10.201.0.5 10.201.0.6 "443 8443"', '_setup_foreign_one() { echo broken > "${CONFIG_DIR}/${FRPC_SERVICE}.toml"; return 1; }')
        self.assertNotEqual(result.returncode,0)
        for p,content in before.items():self.assertEqual(p.read_bytes(),content)

    def test_selector_maps_row_to_foreign_id_and_does_not_expose_token(self):
        self.save([self.one,dict(self.two,id=23)]);self.files(self.one);self.files(self.two)
        result=self.run_shell("menu_select_foreign <<<'2'")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['id'],23);self.assertNotIn('privateToken',result.stderr)

    def test_list_includes_second_client_after_first_is_removed(self):
        self.save([self.two]);self.files(self.two)
        result=self.run_shell('menu_list_tunnels')
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn('Iran-B',result.stdout);self.assertIn('10.201.0.6',result.stdout)

    def test_restore_rebinds_foreign_registry_and_every_gre_unit(self):
        self.save([self.one,self.two]);self.files(self.one);self.files(self.two)
        result=self.run_shell('restore_rebind_local_ip 198.51.100.99',"ip() { echo '[{\"prefsrc\":\"198.51.100.99\"}]'; }")
        self.assertEqual(result.returncode,0,result.stderr)
        for r in json.loads(self.record_path.read_text())['connections']:self.assertEqual(r['local_pub'],'198.51.100.99')
        self.assertIn('local 198.51.100.99 remote 192.0.2.20',(self.units/'gre-t2.service').read_text())

    def test_restore_honors_a_foreign_manual_stop_when_first_client_uses_another_interface(self):
        row=dict(self.one,gre_if='gre-t3')
        self.save([row]);self.files(row)
        (self.state/'stopped').mkdir();(self.state/'stopped/gre-t3').touch()
        result=self.run_shell('restore_start_tunnels','systemctl() { echo "$*"; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('Preserving manual stop: frpc.service',result.stdout)
        self.assertNotIn('restart frpc.service',result.stdout)


    def test_different_iran_seeds_allocate_distinct_pairs_and_keep_legacy_helper(self):
        a=self.run_shell('menu_gre_pair 192.0.2.10').stdout.strip()
        b=self.run_shell('menu_gre_pair 192.0.2.20').stdout.strip()
        self.assertNotEqual(a,b);self.assertEqual(a,self.run_shell('menu_gre_pair 192.0.2.10').stdout.strip())
        self.assertEqual(self.run_shell('menu_gre_pair').stdout.strip(),'10.200.0.2 10.200.0.1')

class GreAddressChangesTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.peers[0].update(local_pub='192.0.2.10',local_gre='10.200.0.2',peer_gre='10.200.0.1',token='sampleToken12345',frp_port=7000)
        self.write_peers();self.unit=self.units/'gre-tunnel.service'
        self.unit.write_text('[Unit]\n[Service]\nExecStart=ip tunnel add gre-tunnel local 192.0.2.10 remote 192.0.2.1; ip addr replace 10.200.0.2/30 dev gre-tunnel; ip route replace 10.200.0.1/32 dev gre-tunnel\n[Install]\n')
        self.events=self.root/'events';self.backups=self.root/'backups'
        tool=self.root/'bin/systemctl';tool.write_text('#!/bin/bash\necho "$*" >> "$EVENTS"\n[[ "$1" != restart || "${FAIL_RESTART:-0}" != 1 ]]\n');tool.chmod(0o755)
        self.env='export PATH="'+str(self.root/'bin')+':$PATH" EVENTS="'+str(self.events)+'"\nBACKUP_DIR="'+str(self.backups)+'"\n'
        self.traffic=self.state/'traffic.json';self.traffic.write_text('{"keep":{"download":12345,"limit":999999}}')

    def test_address_change_preserves_other_tunnel_token_ports_and_usage(self):
        other=self.peers[1].copy();config=(self.config/'frps.toml').read_bytes();usage=self.traffic.read_bytes()
        result=self.run_shell('cli_peer_addresses --id 1 --local-gre 10.203.0.2 --peer-gre 10.203.0.1',self.env)
        self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads((self.state/'peers.json').read_text())['peers']
        self.assertEqual(data[1],other);self.assertEqual(data[0]['token'],'sampleToken12345');self.assertEqual(data[0]['ports'],[443])
        self.assertIn('10.203.0.2/30',self.unit.read_text());self.assertIn('10.203.0.1/32',self.unit.read_text())
        self.assertEqual(self.traffic.read_bytes(),usage);self.assertEqual((self.config/'frps.toml').read_bytes(),config)
        self.assertIn('hsh1_192.0.2.10_7000_10.203.0.2_10.203.0.1_',result.stdout)
        self.assertNotIn('restart frps',self.events.read_text())

    def test_auto_addresses_do_not_change_stopped_service_state(self):
        (self.state/'stopped').mkdir();(self.state/'stopped/gre-tunnel').touch()
        result=self.run_shell('cli_peer_addresses --id 1 --auto',self.env)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('restart',self.events.read_text())
        self.assertTrue((self.state/'stopped/gre-tunnel').exists())
        self.assertNotEqual(json.loads((self.state/'peers.json').read_text())['peers'][0]['local_gre'],'10.200.0.2')

    def test_restart_failure_restores_registry_and_unit(self):
        old_registry=(self.state/'peers.json').read_bytes();old_unit=self.unit.read_bytes()
        result=self.run_shell('cli_peer_addresses --id 1 --local-gre 10.203.0.2 --peer-gre 10.203.0.1',self.env+'export FAIL_RESTART=1\n')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.state/'peers.json').read_bytes(),old_registry);self.assertEqual(self.unit.read_bytes(),old_unit)

    def test_conflicting_and_invalid_pairs_never_mutate_files(self):
        self.peers[1].update(local_gre='10.203.0.2',peer_gre='10.203.0.1');self.write_peers();old=self.unit.read_bytes()
        for a,b in [('10.203.0.2','10.203.0.1'),('10.204.0.2','10.205.0.1'),('10.204.0.0','10.204.0.1')]:
            result=self.run_shell('cli_peer_addresses --id 1 --local-gre '+a+' --peer-gre '+b,self.env)
            self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.unit.read_bytes(),old);self.assertFalse(self.events.exists())


class ForeignWatchdogTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.record=dict(id=2,name='Iran-B',gre_if='gre-t2',frpc_svc='frpc-2',remote_pub='192.0.2.20')
        (self.state/'foreign.json').write_text(json.dumps({'connections':[self.record]}))
        (self.state/'watchdog.json').write_text(json.dumps(dict(enabled=True,auto_restart=True,consec_fails=99,last_alert='down',backup_every_hours=1)))
        self.context="foreign_context '"+json.dumps(self.record)+"' "

    def test_failure_counts_are_not_inherited_from_the_global_first_tunnel(self):
        result=self.run_shell(self.context+'foreign_watchdog_tick','_watchdog_tick_one() { cat "$WATCHDOG_FILE"; }')
        self.assertEqual(result.returncode,0,result.stderr)
        row=json.loads(result.stdout);self.assertEqual(row['consec_fails'],0);self.assertEqual(row['last_alert'],'')
        self.assertTrue(row['auto_restart']);self.assertEqual(row['backup_every_hours'],0)

    def test_stopped_connection_is_skipped_and_recovery_is_scoped(self):
        (self.state/'stopped').mkdir();(self.state/'stopped/gre-t2').touch()
        result=self.run_shell(self.context+'foreign_watchdog_tick','_watchdog_tick_one() { echo FORBIDDEN; }')
        self.assertEqual(result.returncode,0,result.stderr);self.assertNotIn('FORBIDDEN',result.stdout)
        (self.state/'stopped/gre-t2').unlink()
        result=self.run_shell(self.context+'restart_all_lite','systemctl() { echo "$*"; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('restart frpc-2.service',result.stdout);self.assertNotIn('gre-tunnel',result.stdout)
