import json
import tomllib
from test_regressions import ScriptHarness

class ControlPortTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        for n,p in enumerate(self.peers):
            p.update(frp_port=7000+10*n,token='retainedToken123',local_pub='203.0.113.1',local_gre=f'10.200.0.{2+4*n}',peer_gre=f'10.200.0.{1+4*n}')
        self.write_peers()
        (self.config/'frps-2.toml').write_text('bindPort = 7010\nkcpBindPort = 7010\nquicBindPort = 7011\nauth.token = "retainedToken123"\ntransport.tls.force = true\nallowPorts = [{ start = 8443, end = 8443 }]\n')
        self.stubs='ss() { return 0; }\nip() { return 0; }\n'

    def test_manual_and_automatic_creation_prompt(self):
        result=self.run_shell("menu_control_port_prompt 0 '443' <<< '7400'",self.stubs)
        self.assertEqual(result.stdout.strip(),'7400')
        result=self.run_shell("menu_control_port_prompt 0 '443' <<< ''",self.stubs+'gen_random_port() { echo 7500; }')
        self.assertEqual(result.stdout.strip(),'7500')
        result=self.run_shell("menu_control_port_prompt 2 <<< 'auto'",self.stubs+'gen_random_port() { echo 7600; }')
        self.assertEqual(result.stdout.strip(),'7600')

    def test_conflicting_manual_input_reprompts(self):
        result=self.run_shell("menu_control_port_prompt 0 <<<$'7010\\n7700'",self.stubs)
        self.assertEqual(result.stdout.strip(),'7700')
        self.assertIn('conflicts',result.stderr)

    def test_invalid_range_companion_and_service_conflicts(self):
        for port in ('0','65536','bad','7010','7009','7011','443','8442'):
            with self.subTest(port=port):
                result=self.run_shell('peer_control_port_check '+port+' 0',self.stubs)
                self.assertNotEqual(result.returncode,0)
        self.assertNotEqual(self.run_shell('peer_control_port_check 7800 0 "7801,8080"',self.stubs).returncode,0)

    def test_tcp_udp_and_fou_listeners_are_checked(self):
        for extra in ('ss() { echo "LISTEN 0 128 0.0.0.0:7800 0.0.0.0:*"; }',
                      'ss() { [[ "$*" == *lun ]] && echo "UNCONN 0 0 [::]:7801 [::]:*"; return 0; }',
                      'ip() { echo "port 7800 ipproto 47"; }'):
            result=self.run_shell('peer_control_port_check 7800 0',self.stubs+extra)
            self.assertNotEqual(result.returncode,0)

    def test_change_updates_only_selected_frps_and_preserves_other_state(self):
        before=json.loads((self.state/'peers.json').read_text())
        traffic=self.state/'traffic.json';traffic.write_text('{"unchanged":123}')
        other=(self.config/'frps.toml').read_bytes()
        result=self.run_shell('cli_peer_control_port --id 2 --port 7900',self.stubs+'systemctl() { echo "$*" >> "'+str(self.root/'calls')+'"; }')
        self.assertEqual(result.returncode,0,result.stderr)
        new=json.loads((self.state/'peers.json').read_text())
        self.assertEqual(new['peers'][0],before['peers'][0])
        self.assertEqual(new['peers'][1],{**before['peers'][1],'frp_port':7900})
        config=tomllib.loads((self.config/'frps-2.toml').read_text())
        self.assertEqual((config['bindPort'],config['kcpBindPort'],config['quicBindPort']),(7900,7900,7901))
        self.assertEqual(config['auth']['token'],'retainedToken123')
        self.assertTrue(config['transport']['tls']['force'])
        self.assertEqual(config['allowPorts'],[dict(start=8443,end=8443)])
        self.assertEqual((self.config/'frps.toml').read_bytes(),other)
        self.assertEqual(traffic.read_text(),'{"unchanged":123}')
        self.assertIn('_7900_10.200.0.6_10.200.0.5_',result.stdout)
        self.assertIn('--force',result.stdout)
        self.assertNotIn('gre-t2',(self.root/'calls').read_text())
        self.assertEqual((self.config/'frps-2.toml').stat().st_mode&0o777,0o600)

    def test_failed_restart_rolls_back_registry_and_config(self):
        paths=[self.state/'peers.json',self.config/'frps-2.toml']
        old={p:p.read_bytes() for p in paths}
        result=self.run_shell('cli_peer_control_port --id 2 --port 7900',self.stubs+'''systemctl() {
if [[ "$1" == restart ]] && grep -q 'bindPort = 7900' "'''+str(self.config/'frps-2.toml')+'''"; then return 1; fi
return 0;
}''')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('previous settings were restored',result.stderr)
        for p,content in old.items(): self.assertEqual(p.read_bytes(),content)

    def test_port_65535_wraps_quic_companion(self):
        result=self.run_shell('cli_peer_control_port --id 2 --port 65535',self.stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        config=tomllib.loads((self.config/'frps-2.toml').read_text())
        self.assertEqual(config['quicBindPort'],65534)

    def test_cancel_and_missing_argument_preserve_registry(self):
        before=(self.state/'peers.json').read_bytes()
        for cmd in ("menu_control_port_prompt 2 <<< ''","menu_control_port_prompt 0 <<< '0'",'cli_peer_control_port --id 2 --port'):
            self.assertNotEqual(self.run_shell(cmd,self.stubs).returncode,0)
        self.assertEqual((self.state/'peers.json').read_bytes(),before)

    def test_creation_passes_manual_control_port_to_setup(self):
        result=self.run_shell("menu_add_peer <<<$'new-name\\nn\\n7900'",self.stubs+'''
menu_import_existing() { return 0; }
prompt_ip() { printf -v "$1" '%s' '203.0.113.1'; }
prompt_ports() { printf -v "$1" '%s' '9443'; }
curl() { echo 203.0.113.1; }
gen_token32() { echo retainedToken123; }
cli_add_peer() { echo "SETUP:$*"; }
''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('--frp-port 7900',result.stdout)
        self.assertIn('The tunnel was built',result.stdout)

    def test_menu_edit_control_port_is_scoped_to_selected_peer(self):
        result=self.run_shell("menu_edit_peer <<<$'2\\n13\\n7900\\n\\n0'",self.stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        records=json.loads((self.state/'peers.json').read_text())['peers']
        self.assertEqual(records[0]['frp_port'],7000)
        self.assertEqual(records[1]['frp_port'],7900)
        self.assertIn('NavaTunnel setup-foreign --bundle',result.stdout)
        self.assertIn('--force',result.stdout)
