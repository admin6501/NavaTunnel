import json
from test_regressions import ScriptHarness

class LossStatusTests(ScriptHarness):
    def prepare_connection(self):
        self.peers[1].update(local_pub='203.0.113.1',local_gre='10.200.0.2',peer_gre='10.200.0.1',token='testingToken123',frp_port=7000)
        self.write_peers()

    def test_existing_kcp_record_reports_enabled_even_without_boolean(self):
        self.peers[1]['frp_transport']='kcp';self.write_peers()
        result=self.run_shell('peer_connection_settings 2')
        self.assertEqual(result.stdout.strip(),'kcp\ton')

    def test_protocol_is_authoritative_over_stale_boolean(self):
        self.peers[1].update(frp_transport='wss',loss_recovery=True);self.write_peers()
        result=self.run_shell('peer_connection_settings 2')
        self.assertEqual(result.stdout.strip(),'wss\toff')

    def test_old_boolean_only_record_still_reports_enabled(self):
        self.peers[1]['loss_recovery']=True;self.write_peers()
        self.assertEqual(self.run_shell('peer_connection_settings 2').stdout.strip(),'kcp\ton')

    def test_enable_persists_across_separate_menu_sessions(self):
        self.prepare_connection()
        result=self.run_shell("menu_loss_recovery 2 <<<$'1\\n0'")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('confirmed in the Iran configuration',result.stdout)
        self.assertIn('_loss1_protokcp',result.stdout)
        reopened=self.run_shell("menu_loss_recovery 2 <<<'0'")
        self.assertIn('Selection saved on Iran: Enabled | Protocol: kcp',reopened.stdout)
        self.assertIn('not checked',reopened.stdout)

    def test_disable_is_explicit_and_generates_non_kcp_bundle(self):
        self.prepare_connection()
        self.run_shell('cli_loss_recovery --id 2 --mode on')
        result=self.run_shell("menu_loss_recovery 2 <<<$'2\\n0'")
        self.assertEqual(result.returncode,0,result.stderr)
        records=json.loads((self.state/'peers.json').read_text())['peers']
        self.assertIs(records[1]['loss_recovery'],False)
        self.assertEqual(records[1]['frp_transport'],'tcp')
        self.assertNotIn('loss_recovery',records[0])
        self.assertIn('Disabled | Protocol: tcp',result.stdout)
        command=next(line for line in result.stdout.splitlines() if line.startswith('NavaTunnel setup-foreign'))
        self.assertNotIn('_loss1',command)
        self.assertIn('--force',command)

    def test_enter_and_status_do_not_disable_enabled_setting(self):
        self.run_shell('cli_loss_recovery --id 2 --mode on')
        before=(self.state/'peers.json').read_text()
        for command in ("menu_loss_recovery 2 <<<''", "menu_loss_recovery 2 <<<$'3\\n0'", 'menu_loss_recovery 2 </dev/null'):
            self.assertEqual(self.run_shell(command).returncode,0)
            self.assertEqual((self.state/'peers.json').read_text(),before)

    def test_disable_preserves_wss_and_code_agrees_with_display(self):
        self.prepare_connection()
        self.peers[1].update(frp_transport='wss',loss_recovery=True);self.write_peers()
        result=self.run_shell("menu_loss_recovery 2 <<<$'2\\n0'")
        self.assertIn('Disabled | Protocol: wss',result.stdout)
        self.assertIn('_loss0_protowss',result.stdout)
        self.assertNotIn('_loss1',result.stdout)

    def test_option_nine_opens_enable_disable_menu(self):
        result=self.run_shell("menu_edit_peer <<<$'2\\n10\\n1\\n0\\n0'")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('2) Disable loss recovery',result.stdout)
        self.assertIn('FRP=kcp | Loss recovery: Enabled',result.stdout)
