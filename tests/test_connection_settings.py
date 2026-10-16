import json
import tomllib
from test_regressions import ScriptHarness


class ConnectionSettingsTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.peers[0].update(token='originalToken123', local_pub='203.0.113.1', local_gre='10.200.0.2', peer_gre='10.200.0.1', frp_port=7000)
        self.peers[1].update(token='otherToken123', frp_port=7001)
        self.write_peers()
        (self.config/'frps.toml').write_text('bindPort = 7000\nauth.token = "originalToken123"\ntransport.tls.force = true\n')
        (self.config/'frps-2.toml').write_text('bindPort = 7001\nauth.token = "otherToken123"\n')
        self.client=self.config/'frpc.toml'
        self.client.write_text('serverAddr = "10.200.0.2"\nserverPort = 7000\nauth.token = "originalToken123"\ntransport.protocol = "tcp"\n[[proxies]]\nname="tcp_443"\nlocalPort=443\nremotePort=443\n')
        self.unit=self.units/'gre-tunnel.service'
        self.unit.write_text('[Unit]\n[Service]\nExecStart=/bin/sh -c "ip link add gre-tunnel type gre local 192.0.2.99 remote 203.0.113.1 ttl 255 || ip tunnel add gre-tunnel mode gre remote 203.0.113.1; ip addr add 10.200.0.1/30 dev gre-tunnel"\n')
        self.calls=self.root/'calls'
        systemctl=self.root/'bin/systemctl'
        systemctl.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$CALLS"\nif [[ "$*" == restart* && -n "$FAIL_RESTART" && ! -f "$FAIL_RESTART" ]]; then touch "$FAIL_RESTART"; exit 1; fi\nexit 0\n')
        systemctl.chmod(0o755)
        self.env='export PATH="'+str(self.root/'bin')+':$PATH" CALLS="'+str(self.calls)+'"\n'
        self.traffic=self.state/'traffic.json';self.traffic.write_text('{"retained":{"download":123456,"limit":999999}}')

    def call(self, command, extra=''):
        return self.run_shell(command,self.env+extra)

    def test_explicit_view_uses_selected_config_without_exposing_other_token(self):
        result=self.call('cli_connection_token --id 2')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('otherToken123',result.stdout)
        self.assertNotIn('originalToken123',result.stdout)
        result=self.call('cli_connection_token --foreign')
        self.assertIn('originalToken123',result.stdout)

    def test_iran_edit_updates_only_selected_config_registry_and_bundle(self):
        other=(self.config/'frps-2.toml').read_bytes();traffic=self.traffic.read_bytes()
        result=self.call('cli_connection_token --id 1 --token manualToken456; peer_token 1')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('_manualToken456_',result.stdout)
        cfg=tomllib.loads((self.config/'frps.toml').read_text())
        self.assertEqual(cfg['auth']['token'],'manualToken456');self.assertTrue(cfg['transport']['tls']['force'])
        records=json.loads((self.state/'peers.json').read_text())['peers']
        self.assertEqual(records[0]['token'],'manualToken456');self.assertEqual(records[1]['token'],'otherToken123')
        self.assertEqual((self.config/'frps-2.toml').read_bytes(),other);self.assertEqual(self.traffic.read_bytes(),traffic)
        self.assertNotIn('frps-2',self.calls.read_text())
        self.assertEqual((self.config/'frps.toml').stat().st_mode & 0o777,0o600)

    def test_foreign_edit_preserves_proxy_settings_and_hub_registry(self):
        registry=(self.state/'peers.json').read_bytes()
        result=self.call('cli_connection_token --foreign --token manualToken456')
        self.assertEqual(result.returncode,0,result.stderr)
        cfg=tomllib.loads(self.client.read_text())
        self.assertEqual(cfg['auth']['token'],'manualToken456');self.assertEqual(cfg['proxies'][0]['localPort'],443)
        self.assertEqual((self.state/'peers.json').read_bytes(),registry)
        self.assertIn('restart frpc',self.calls.read_text());self.assertNotIn('restart frps',self.calls.read_text())

    def test_auth_table_layout_is_preserved(self):
        self.client.write_text('serverAddr="10.200.0.2"\n[auth]\nmethod="token"\ntoken="originalToken123"\n[transport]\nprotocol="tcp"\n')
        result=self.call('cli_connection_token --foreign --token manualToken456')
        self.assertEqual(result.returncode,0,result.stderr)
        cfg=tomllib.loads(self.client.read_text());self.assertEqual(cfg['auth']['token'],'manualToken456');self.assertEqual(cfg['transport']['protocol'],'tcp')

    def test_invalid_token_never_changes_anything(self):
        before=self.client.read_bytes()
        for token in ('short','bad_token123','bad"token123','bad token123'):
            result=self.call('cli_connection_token --foreign --token '+__import__('shlex').quote(token))
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(self.client.read_bytes(),before)
        self.assertFalse(self.calls.exists())

    def test_token_restart_failure_rolls_back_config_and_registry(self):
        config=(self.config/'frps.toml').read_bytes();registry=(self.state/'peers.json').read_bytes()
        result=self.call('cli_connection_token --id 1 --token manualToken456','export FAIL_RESTART="'+str(self.root/'once')+'"\n')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Previous settings restored',result.stderr)
        self.assertEqual((self.config/'frps.toml').read_bytes(),config);self.assertEqual((self.state/'peers.json').read_bytes(),registry)

    def test_stopped_tunnel_token_edit_never_starts_it(self):
        (self.state/'stopped').mkdir();(self.state/'stopped/gre-tunnel').touch()
        result=self.call('cli_connection_token --foreign --token manualToken456')
        self.assertEqual(result.returncode,0,result.stderr);self.assertFalse(self.calls.exists())
        self.assertIn('remains stopped',result.stdout)

    def test_foreign_iran_ip_rewrites_all_fallbacks_and_keeps_everything_else(self):
        config=self.client.read_bytes();traffic=self.traffic.read_bytes()
        result=self.call('cli_foreign_iran_ip --ip 203.0.113.50')
        self.assertEqual(result.returncode,0,result.stderr)
        unit=self.unit.read_text();self.assertEqual(unit.count('remote 203.0.113.50'),2)
        self.assertIn('local 192.0.2.99',unit);self.assertIn('10.200.0.1/30',unit)
        self.assertEqual(self.client.read_bytes(),config);self.assertEqual(self.traffic.read_bytes(),traffic)
        self.assertIn('restart gre-tunnel.service',self.calls.read_text());self.assertIn('restart frpc',self.calls.read_text())

    def test_foreign_iran_ip_failure_restores_old_unit(self):
        before=self.unit.read_bytes()
        result=self.call('cli_foreign_iran_ip --ip 203.0.113.50','export FAIL_RESTART="'+str(self.root/'once')+'"\n')
        self.assertNotEqual(result.returncode,0);self.assertEqual(self.unit.read_bytes(),before)
        self.assertIn('Previous settings restored',result.stderr)

    def test_invalid_or_cancelled_ip_changes_do_not_mutate(self):
        before=self.unit.read_bytes()
        self.assertNotEqual(self.call('cli_foreign_iran_ip --ip not-an-ip').returncode,0)
        result=self.call("menu_foreign_iran_ip <<<$'203.0.113.50\\nn'")
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(self.unit.read_bytes(),before)
        self.assertFalse(self.calls.exists())
        self.assertEqual(self.call("menu_foreign_iran_ip <<< ''").returncode,0)
        self.assertEqual(self.unit.read_bytes(),before)

    def test_ip_change_preserves_stopped_state(self):
        (self.state/'stopped').mkdir();(self.state/'stopped/gre-tunnel').touch()
        result=self.call('cli_foreign_iran_ip --ip 203.0.113.50')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('restart',self.calls.read_text())

    def test_token_menus_are_available_on_both_sides(self):
        result=self.call("menu_edit_peer <<<$'1\\n15\\n0\\n0'")
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn('Connection token: originalToken123',result.stdout)
        result=self.call("menu_foreign_tunnel <<<$'8\\n0\\n0'")
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn('Connection token: originalToken123',result.stdout)
        self.assertIn('9) Change Iran server public IP',result.stdout)

    def test_creation_accepts_manual_token(self):
        result=self.call("menu_add_peer <<<$'example\\nn\\n7002\\nmanualToken456'",'''
menu_import_existing() { return 0; }
prompt_ip() { printf -v "$1" '%s' '192.0.2.99'; }
prompt_ports() { printf -v "$1" '%s' '9443'; }
menu_control_port_prompt() { read -r v; echo "$v"; }
curl() { echo 192.0.2.99; }
cli_add_peer() { echo "CREATED:$*"; }
''')
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn('--token manualToken456',result.stdout)
