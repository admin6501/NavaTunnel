from test_regressions import ScriptHarness

class ForeignMenuTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.peers=[];self.write_peers()
        self.client=self.config/'frpc.toml'
        self.client.write_text('''serverAddr = "10.200.0.2"
serverPort = 35305
auth.token = "SECRET_NOT_FOR_DISPLAY"
transport.protocol = "kcp"
[[proxies]]
name = "tcp_23298"
type = "tcp"
localIP = "127.0.0.1"
localPort = 23298
remotePort = 23298
[[proxies]]
name = "udp_53835"
type = "udp"
localIP = "127.0.0.1"
localPort = 53835
remotePort = 53835
''')

    def test_foreign_config_is_listed_without_hub_registry(self):
        result=self.run_shell('menu_list_tunnels','systemctl() { echo active; }')
        self.assertEqual(result.returncode,0,result.stderr)
        for value in ('FRPC','10.200.0.2:35305','kcp','23298','53835','فعال'):
            self.assertIn(value,result.stdout)
        self.assertNotIn('SECRET_NOT_FOR_DISPLAY',result.stdout)
        self.assertNotIn('No peer tunnels',result.stdout)

    def test_main_tunnel_option_four_shows_foreign_tunnel(self):
        result=self.run_shell("menu_tunnel <<<$'4\\n\\n0'")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('FRPC',result.stdout)
        self.assertIn('35305',result.stdout)

    def test_option_three_manages_existing_foreign_tunnel(self):
        result=self.run_shell("menu_tunnel <<<$'3\\n0\\n0'")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('FRPC',result.stdout)
        self.assertIn('ری‌استارت همین تونل',result.stdout)
        self.assertNotIn('ابتدا یک تونل بسازید',result.stderr)

    def test_foreign_restart_does_not_restart_hub_services(self):
        result=self.run_shell("menu_manage_tunnel <<<$'2\\n0'",'systemctl() { echo "$*"; }')
        self.assertIn('restart gre-tunnel.service',result.stdout)
        self.assertIn('restart frpc',result.stdout)
        self.assertNotIn('restart frps',result.stdout)

    def test_both_roles_display_and_route_independently(self):
        self.peers=[dict(id=2,name='iran-peer',gre_if='gre-t2')];self.write_peers()
        result=self.run_shell('menu_list_tunnels','peer_list_pretty() { echo IRAN_PEER_LIST; }')
        self.assertIn('IRAN_PEER_LIST',result.stdout)
        self.assertIn('FRPC',result.stdout)
        result=self.run_shell("menu_manage_tunnel <<<'1'",'menu_edit_peer() { echo MANAGE_IRAN; }')
        self.assertIn('MANAGE_IRAN',result.stdout)
        result=self.run_shell("menu_manage_tunnel <<<$'2\\n0'")
        self.assertIn('FRPC',result.stdout)

    def test_missing_and_invalid_client_config(self):
        self.client.unlink()
        result=self.run_shell('menu_list_tunnels')
        self.assertIn('هیچ تونلی',result.stdout)
        self.client.write_text('invalid TOML [')
        result=self.run_shell('foreign_tunnel_summary')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('ناموفق',result.stderr)

    def test_eof_exits_foreign_manager_without_mutation(self):
        before=self.client.read_text()
        result=self.run_shell('menu_manage_tunnel </dev/null')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.client.read_text(),before)
