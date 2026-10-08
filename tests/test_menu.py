import json
from test_regressions import ScriptHarness

class MenuTests(ScriptHarness):
    def test_selection_maps_row_to_peer_not_id(self):
        self.peers[1]['id']=501; self.write_peers()
        result=self.run_shell("menu_select_peer <<<'2'")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.strip(),'501')

    def test_cancel_and_eof_return(self):
        for command in ("menu_select_peer <<<'0'",'menu_select_peer </dev/null',"menu_select_peer <<<'9999999999999999'"):
            self.assertNotEqual(self.run_shell(command).returncode,0)
        self.assertEqual(self.run_shell('menu_tunnel </dev/null').returncode,0)
        self.assertNotEqual(self.run_shell('prompt_ip value label "" </dev/null').returncode,0)

    def test_enter_keeps_name_without_edit_call(self):
        result=self.run_shell("menu_edit_peer <<<$'1\\n2\\n\\n0'",'cli_edit_peer() { echo UNEXPECTED; return 1; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('UNEXPECTED',result.stdout)

    def test_restart_only_selected_peer(self):
        result=self.run_shell("menu_edit_peer <<<$'2\\n6\\n0'",'systemctl() { echo "$*"; }')
        self.assertIn('restart gre-t2.service',result.stdout)
        self.assertIn('restart frps-2.service',result.stdout)
        self.assertNotIn('restart frps.service',result.stdout)

    def test_allocator_skips_used_pair_for_large_peer_id(self):
        self.peers[1].update(id=501,local_gre='10.200.0.2',peer_gre='10.200.0.1');self.write_peers()
        result=self.run_shell('menu_gre_pair')
        self.assertEqual(result.stdout.strip(),'10.200.0.6 10.200.0.5')

    def test_traffic_row_maps_actual_counter_id(self):
        (self.state/'traffic.json').write_text(json.dumps({'gre-t501':dict(interface='gre-t501',download=2**30,upload=0,limit=0,mode='both')}))
        result=self.run_shell("menu_select_traffic <<<'1'")
        self.assertEqual(result.stdout.strip(),'gre-t501')
        self.assertIn('1.00 GiB',result.stderr)

    def test_traffic_mode_default_and_cancel(self):
        self.assertEqual(self.run_shell("menu_traffic_mode <<<''").stdout.strip(),'both')
        self.assertNotEqual(self.run_shell("menu_traffic_mode <<<'0'").returncode,0)

    def test_simple_limit_means_gigabytes(self):
        (self.state/'traffic.json').write_text(json.dumps({'gre-t2':dict(interface='gre-t2',download=0,upload=0,limit=0,mode='both')}))
        result=self.run_shell("menu_traffic <<<$'2\\n1\\n100\\n3\\n\\n0'",'cli_traffic() { echo "CALL:$*"; }')
        self.assertIn('CALL:limit gre-t2 100GB --mode both',result.stdout)

    def test_failed_creation_does_not_announce_success(self):
        result=self.run_shell("menu_add_peer <<<$'example\\nn'",'''prompt_ip() { printf -v "$1" '%s' '192.0.2.1'; }
prompt_ports() { printf -v "$1" '%s' '443'; }
curl() { echo 192.0.2.1; }
cli_add_peer() { return 1; }
''')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('تونل ساخته شد',result.stdout)

    def test_existing_single_tunnel_import_is_idempotent(self):
        (self.units/'gre-tunnel.service').write_text('ip tunnel add gre-tunnel mode gre local 192.0.2.10 remote 192.0.2.20\nip addr replace 10.10.10.2/30\nip route replace 10.10.10.1/32')
        self.peers=[];self.write_peers()
        result=self.run_shell('menu_import_existing; menu_import_existing')
        self.assertEqual(result.returncode,0,result.stderr)
        records=json.loads((self.state/'peers.json').read_text())['peers']
        self.assertEqual(len(records),1)
        self.assertEqual(records[0]['remote_pub'],'192.0.2.20')
        self.assertTrue(records[0]['legacy'])

    def test_ports_prompt_rejects_partially_invalid_input(self):
        result=self.run_shell("prompt_ports ports label <<<$'443,bad\\n8443'; echo \"$ports\"")
        self.assertEqual(result.stdout.splitlines()[-1],'8443')
