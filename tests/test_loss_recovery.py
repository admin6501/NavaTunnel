import json
from test_regressions import ScriptHarness

BUNDLE='hsh1_203.0.113.1_7000_10.10.10.2_10.10.10.1_AtestToken123456789_443_fou443-55555'

class LossRecoveryTests(ScriptHarness):
    def foreign(self, flags):
        return self.run_shell('cli_setup_foreign --local-pub 203.0.113.2 --bundle '+BUNDLE+' '+flags,
            'tunnel_present() { return 1; }\nsetup_foreign_server_noninteractive() { echo "PROTOCOL:${10}"; }\ncarrier_set_fou_ports() { return 0; }\ncarrier_init_kernel() { return 0; }')

    def test_yes_no_and_invalid_answer(self):
        for value,expected in [('y','on'),('Y','on'),('n','off'),('','off')]:
            result=self.run_shell("menu_loss_prompt <<<'"+value+"'")
            self.assertEqual(result.stdout.strip(),expected)
        result=self.run_shell("menu_loss_prompt <<<$'invalid\\ny'")
        self.assertEqual(result.stdout.strip(),'on')
        self.assertNotEqual(self.run_shell('menu_loss_prompt </dev/null').returncode,0)

    def test_bundle_defaults_off_and_carries_on(self):
        result=self.run_shell('bundle_parse '+BUNDLE+'; echo "$B_LOSS_RECOVERY"; bundle_parse '+BUNDLE+'_loss1; echo "$B_LOSS_RECOVERY $B_FOU_P1 $B_FOU_P2"')
        self.assertEqual(result.stdout.splitlines(),['off','on 443 55555'])
        self.assertNotEqual(self.run_shell('bundle_parse '+BUNDLE+'_unknown').returncode,0)

    def test_bundle_creation_round_trip_with_empty_ports(self):
        result=self.run_shell('b=$(bundle_make 203.0.113.1 7000 10.10.10.2 10.10.10.1 testToken "" 443-55555 on); bundle_parse "$b"; echo "$B_LOSS_RECOVERY:$B_PORTS"')
        self.assertEqual(result.stdout.strip(),'on:')

    def test_toggle_affects_only_selected_peer(self):
        for mode,expected in [('on',True),('off',False)]:
            result=self.run_shell('cli_loss_recovery --id 2 --mode '+mode)
            self.assertEqual(result.returncode,0,result.stderr)
            peers=json.loads((self.state/'peers.json').read_text())['peers']
            self.assertNotIn('loss_recovery',peers[0])
            self.assertIs(peers[1]['loss_recovery'],expected)

    def test_invalid_mode_and_missing_peer_do_not_change_registry(self):
        before=(self.state/'peers.json').read_text()
        for flags in ['--id 1 --mode invalid','--id 99 --mode on','--id 1 --mode']:
            self.assertNotEqual(self.run_shell('cli_loss_recovery '+flags).returncode,0)
            self.assertEqual((self.state/'peers.json').read_text(),before)

    def test_foreign_on_selects_kcp_and_off_selects_tcp(self):
        for mode,protocol in [('on','kcp'),('off','tcp')]:
            result=self.foreign('--loss-recovery '+mode)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('PROTOCOL:'+protocol,result.stdout)

    def test_bundle_enables_kcp_without_extra_flags(self):
        result=self.run_shell('cli_setup_foreign --local-pub 203.0.113.2 --bundle '+BUNDLE+'_loss1',
            'tunnel_present() { return 1; }\nsetup_foreign_server_noninteractive() { echo "PROTOCOL:${10}"; }\ncarrier_set_fou_ports() { return 0; }\ncarrier_init_kernel() { return 0; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('PROTOCOL:kcp',result.stdout)

    def test_explicit_off_overrides_bundle_on(self):
        result=self.run_shell('cli_setup_foreign --local-pub 203.0.113.2 --bundle '+BUNDLE+'_loss1 --loss-recovery off',
            'tunnel_present() { return 1; }\nsetup_foreign_server_noninteractive() { echo "PROTOCOL:${10}"; }\ncarrier_set_fou_ports() { return 0; }\ncarrier_init_kernel() { return 0; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('PROTOCOL:tcp',result.stdout)

    def test_conflicting_transport_rejected_before_setup(self):
        result=self.foreign('--loss-recovery on --frp-transport quic')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('PROTOCOL:',result.stdout)

    def test_old_bundle_allows_explicit_kcp_transport(self):
        result=self.foreign('--frp-transport kcp')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('PROTOCOL:kcp',result.stdout)

    def test_create_peer_persists_choice_and_emits_matching_bundle(self):
        self.peers=[];self.write_peers()
        flags='--local-pub 203.0.113.1 --remote-pub 203.0.113.2 --frp-port 7000 --token testingToken123 --local-gre 10.200.0.2 --peer-gre 10.200.0.1 --ports 443'
        result=self.run_shell('cli_add_peer '+flags+' --loss-recovery on',
            'install_frp_binaries() { return 0; }\nsetup_gre_systemd() { return 0; }\npeer_write_frps() { return 0; }\ntunnel_present() { return 1; }\nss() { return 0; }\nsleep() { return 0; }')
        self.assertEqual(result.returncode,0,result.stderr)
        records=json.loads((self.state/'peers.json').read_text())['peers']
        self.assertIs(records[0]['loss_recovery'],True)
        self.assertIn('_loss1',result.stdout)
        code=self.run_shell('peer_token 1')
        self.assertIn('_loss1',code.stdout)

    def test_server_listens_for_kcp_on_the_same_control_port(self):
        import tomllib
        result=self.run_shell('peer_write_frps "-2" 7001 testingToken', 'perf_get_tls() { echo 0; }')
        self.assertEqual(result.returncode,0,result.stderr)
        config=tomllib.loads((self.config/'frps-2.toml').read_text())
        self.assertEqual(config['kcpBindPort'],7001)
        self.assertEqual(config['bindPort'],7001)
