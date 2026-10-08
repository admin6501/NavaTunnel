from test_regressions import ScriptHarness

class ConnectionCodeTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.peers[1].update(name='moshtari2',remote_pub='178.104.63.124',local_pub='37.32.40.233',frp_port=27913,local_gre='10.200.0.14',peer_gre='10.200.0.13',token='testingToken123',ports=[11002,11003,8080,2067,2095,8443,8888,443,2087,2096,51820,51821,206,23913])
        self.write_peers()

    def test_option_five_shows_long_bundle_and_pauses_before_menu(self):
        result=self.run_shell("menu_edit_peer <<<$'2\\n5\\n0'",'pause_prompt() { echo CODE_PAUSED; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('NavaTunnel setup-foreign --bundle hsh1_37.32.40.233_27913_10.200.0.14_10.200.0.13_',result.stdout)
        self.assertIn('11002-11003-8080-2067-2095-8443-8888-443-2087-2096-51820-51821-206-23913',result.stdout)
        command=result.stdout.index('NavaTunnel setup-foreign')
        paused=result.stdout.index('CODE_PAUSED',command)
        next_menu=result.stdout.index('تونل: moshtari2',command)
        self.assertLess(paused,next_menu)

    def test_missing_connection_data_returns_explicit_error(self):
        self.peers[1].pop('local_gre');self.write_peers()
        result=self.run_shell('peer_token 2')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('اطلاعات اتصال',result.stderr)
        self.assertNotIn('BUNDLE:',result.stdout)
        result=self.run_shell("menu_edit_peer <<<$'2\\n5\\n0'",'pause_prompt() { echo CODE_PAUSED; }')
        self.assertIn('دریافت کد اتصال ناموفق',result.stdout)
        self.assertNotIn('NavaTunnel setup-foreign',result.stdout)

    def test_invalid_ports_do_not_produce_connection_command(self):
        self.peers[1]['ports']=[70000];self.write_peers()
        result=self.run_shell('peer_token 2')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('BUNDLE:',result.stdout)
