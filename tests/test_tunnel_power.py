import json
from test_regressions import ScriptHarness

class TunnelPowerTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        for path in self.units.glob('*.service'):
            path.write_text('[Unit]\nDescription=fixture\n[Service]\nExecStart=/bin/true\n')
        (self.state/'traffic.json').write_text('{"saved":{"interface":"gre-t2","download":123,"upload":0,"limit":0,"mode":"both"}}')
        self.calls=self.root/'calls'
        self.active=self.root/'active';self.active.mkdir()
        for unit in ('gre-tunnel.service','gre-t2.service','frps.service','frps-2.service','frpc.service','gre-chaff.service'):
            (self.active/unit).touch()
        self.stubs='''systemctl() {
  echo "$*" >> "'''+str(self.calls)+'''"
  local unit="${@: -1}"
  case "$1" in
    start) [[ "$unit" != "$FAIL_START" ]] || return 1; touch "'''+str(self.active)+'''/$unit" ;;
    stop) rm -f "'''+str(self.active)+'''/$unit" ;;
    is-active) [[ -f "'''+str(self.active)+'''/$unit" ]] ;;
    *) return 0 ;;
  esac
}'''

    def test_stop_and_start_are_scoped_and_preserve_configuration(self):
        registry=(self.state/'peers.json').read_bytes()
        config=(self.config/'frps-2.toml').read_bytes()
        result=self.run_shell('cli_tunnel_power stop --id 2',self.stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        marker=self.state/'stopped/gre-t2'
        self.assertTrue(marker.exists())
        self.assertFalse((self.active/'gre-t2.service').exists())
        self.assertFalse((self.active/'frps-2.service').exists())
        self.assertTrue((self.active/'frps.service').exists())
        self.assertNotIn('gre-tunnel.service',self.calls.read_text())
        self.assertIn('ConditionPathExists=!'+str(marker),(self.units/'frps-2.service').read_text())
        result=self.run_shell('cli_tunnel_power start --id 2',self.stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(marker.exists())
        self.assertTrue((self.active/'gre-t2.service').exists())
        self.assertTrue((self.active/'frps-2.service').exists())
        starts=[s for s in self.calls.read_text().splitlines() if s.startswith('start ')]
        self.assertEqual(starts,['start gre-t2.service','start frps-2.service'])
        self.assertEqual((self.state/'peers.json').read_bytes(),registry)
        self.assertEqual((self.config/'frps-2.toml').read_bytes(),config)
        self.assertEqual((self.state/'traffic.json').read_text(),'{"saved":{"interface":"gre-t2","download":123,"upload":0,"limit":0,"mode":"both"}}')

    def test_repeated_operations_do_not_duplicate_unit_conditions(self):
        result=self.run_shell('cli_tunnel_power stop --id 2; cli_tunnel_power stop --id 2; cli_tunnel_power start --id 2',self.stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        for unit in ('gre-t2','frps-2'):
            self.assertEqual((self.units/(unit+'.service')).read_text().count('ConditionPathExists='),1)

    def test_foreign_stop_and_start(self):
        (self.config/'frpc.toml').write_text('serverAddr="10.200.0.2"\n')
        (self.units/'frpc.service').write_text('[Unit]\n[Service]\nExecStart=/bin/true\n')
        result=self.run_shell('cli_tunnel_power stop --foreign; cli_tunnel_power start --foreign',self.stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        calls=self.calls.read_text()
        self.assertIn('stop frpc.service',calls)
        self.assertIn('start frpc.service',calls)
        self.assertNotIn('frps-2.service',calls)

    def test_failed_start_stops_partial_services_and_keeps_marker(self):
        self.run_shell('cli_tunnel_power stop --id 2',self.stubs)
        result=self.run_shell('cli_tunnel_power start --id 2',self.stubs+'\nFAIL_START=frps-2.service')
        self.assertNotEqual(result.returncode,0)
        self.assertTrue((self.state/'stopped/gre-t2').exists())
        self.assertFalse((self.active/'gre-t2.service').exists())
        self.assertFalse((self.active/'frps-2.service').exists())

    def test_invalid_target_and_missing_unit_do_not_stop_other_tunnel(self):
        (self.units/'frps-2.service').unlink()
        result=self.run_shell('cli_tunnel_power stop --id 2',self.stubs)
        self.assertNotEqual(result.returncode,0)
        self.assertTrue((self.active/'gre-t2.service').exists())
        self.assertFalse((self.state/'stopped/gre-t2').exists())
        self.assertNotEqual(self.run_shell('cli_tunnel_power stop --id 999',self.stubs).returncode,0)
        self.assertNotEqual(self.run_shell('cli_tunnel_power stop --id',self.stubs).returncode,0)

    def test_menu_stop_and_start_target_selected_tunnel(self):
        result=self.run_shell("menu_edit_peer <<<$'2\\n2\\n\\n1\\n\\n0'",self.stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('stop frps-2.service',self.calls.read_text())
        self.assertIn('start frps-2.service',self.calls.read_text())
        self.assertNotIn('stop frps.service',self.calls.read_text())

    def test_invalid_unit_aborts_before_altering_any_service(self):
        (self.units/'frps-2.service').write_text('malformed')
        original=(self.units/'gre-t2.service').read_bytes()
        result=self.run_shell('cli_tunnel_power stop --id 2',self.stubs)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.units/'gre-t2.service').read_bytes(),original)
        self.assertFalse((self.state/'stopped/gre-t2').exists())

    def test_reconfiguration_does_not_bypass_intentional_stop(self):
        self.run_shell('cli_tunnel_power stop --id 2',self.stubs)
        result=self.run_shell('setup_gre_iface gre-t2 203.0.113.1 192.0.2.2 10.200.0.6 10.200.0.5',self.stubs)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('manually stopped',result.stderr)
        self.assertFalse((self.active/'gre-t2.service').exists())

    def test_start_does_not_enable_previously_inactive_cover_traffic(self):
        (self.active/'gre-chaff.service').unlink()
        result=self.run_shell('cli_tunnel_power stop --id 1; cli_tunnel_power start --id 1',self.stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('start gre-chaff.service',self.calls.read_text())
        self.assertFalse((self.active/'gre-chaff.service').exists())
