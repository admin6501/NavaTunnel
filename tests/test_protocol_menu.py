import json
from test_regressions import ScriptHarness

BASE='hsh1_203.0.113.1_7000_10.10.10.2_10.10.10.1_testToken123456_443_fou443-55555'

class ProtocolMenuTests(ScriptHarness):
    def test_all_menu_choices_and_cancel(self):
        for choice,protocol in enumerate(('tcp','kcp','quic','websocket','wss'),1):
            result=self.run_shell("menu_protocol_prompt <<<'%s'"%choice)
            self.assertEqual(result.stdout.strip(),protocol)
            self.assertIn('خارج',result.stderr)
        self.assertEqual(self.run_shell("menu_protocol_prompt quic <<<''").stdout.strip(),'quic')
        for command in ("menu_protocol_prompt <<<'0'",'menu_protocol_prompt </dev/null'):
            self.assertNotEqual(self.run_shell(command).returncode,0)

    def test_protocol_saved_only_for_selected_tunnel(self):
        for protocol in ('tcp','kcp','quic','websocket','wss'):
            result=self.run_shell('cli_peer_protocol --id 2 --protocol '+protocol)
            self.assertEqual(result.returncode,0,result.stderr)
            records=json.loads((self.state/'peers.json').read_text())['peers']
            self.assertNotIn('frp_transport',records[0])
            self.assertEqual(records[1]['frp_transport'],protocol)
            self.assertIs(records[1]['loss_recovery'],protocol=='kcp')

    def test_menu_option_ten_changes_selected_protocol(self):
        result=self.run_shell("menu_edit_peer <<<$'2\\n11\\n3\\n0'")
        self.assertEqual(result.returncode,0,result.stderr)
        records=json.loads((self.state/'peers.json').read_text())['peers']
        self.assertEqual(records[1]['frp_transport'],'quic')
        self.assertNotIn('frp_transport',records[0])

    def test_protocol_roundtrip_for_every_transport(self):
        for protocol in ('tcp','kcp','quic','websocket','wss'):
            loss='on' if protocol=='kcp' else 'off'
            command='b=$(bundle_make 203.0.113.1 7000 10.10.10.2 10.10.10.1 testToken "443" 443-55555 '+loss+' '+protocol+'); bundle_parse "$b"; echo "$B_FRP_TRANSPORT:$B_LOSS_RECOVERY"'
            result=self.run_shell(command)
            self.assertEqual(result.stdout.strip(),protocol+':'+loss)

    def test_foreign_inherits_bundle_protocol(self):
        for protocol in ('quic','websocket','wss'):
            result=self.run_shell('cli_setup_foreign --local-pub 203.0.113.2 --bundle '+BASE+'_loss0_proto'+protocol,
                'tunnel_present() { return 1; }\nsetup_foreign_server_noninteractive() { echo "TRANSPORT:${10}"; }\ncarrier_set_fou_ports() { return 0; }\ncarrier_init_kernel() { return 0; }')
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('TRANSPORT:'+protocol,result.stdout)

    def test_quick_foreign_menu_passes_selected_protocol(self):
        result=self.run_shell("menu_tunnel <<<$'2\\n"+BASE+"\\n5\\n\\n0'",
            'tunnel_present() { return 1; }\ncli_setup_foreign() { echo "APPLY:$*"; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('--frp-transport wss --loss-recovery off',result.stdout)

    def test_loss_toggle_keeps_protocol_consistent(self):
        self.run_shell('cli_peer_protocol --id 2 --protocol quic; cli_loss_recovery --id 2 --mode on')
        record=json.loads((self.state/'peers.json').read_text())['peers'][1]
        self.assertEqual(record['frp_transport'],'kcp')
        self.run_shell('cli_loss_recovery --id 2 --mode off')
        record=json.loads((self.state/'peers.json').read_text())['peers'][1]
        self.assertEqual(record['frp_transport'],'tcp')

    def test_bad_protocol_and_inconsistent_bundle_rejected(self):
        before=(self.state/'peers.json').read_text()
        for flags in ('--id 2 --protocol invalid','--id 2 --protocol','--id 99 --protocol quic'):
            self.assertNotEqual(self.run_shell('cli_peer_protocol '+flags).returncode,0)
            self.assertEqual((self.state/'peers.json').read_text(),before)
        for suffix in ('_loss1_protoquic','_loss0_protoinvalid','_loss0_protoquic_extra'):
            self.assertNotEqual(self.run_shell('bundle_parse '+BASE+suffix).returncode,0)
