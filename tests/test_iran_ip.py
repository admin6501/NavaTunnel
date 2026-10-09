import json
from test_regressions import ScriptHarness

class IranIPTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.backups=self.root/'backups'
        for p in self.peers:
            p.update(local_pub='198.51.100.1',local_gre='10.200.0.2',peer_gre='10.200.0.1',token='retained',frp_port=7000,frp_transport='tcp')
            (self.units/(p['gre_if']+'.service')).write_text(
                'ExecStart=/bin/sh -c "ip link add '+p['gre_if']+' type gre local 198.51.100.1 remote '+p['remote_pub']+' ttl 255; ip link set dev '+p['gre_if']+' up mtu 1300"\n')
        self.write_peers()
        self.bin=self.root/'bin'
        self.install_command('ip','''if [ "$1" = -o ]; then echo '2: eth0 inet 198.51.100.9/24'; else echo '192.0.2.1 dev eth0 src 10.0.0.4'; fi''')
        self.install_command('systemctl','''echo "$*" >> "$CALL_LOG"
if [ "$FAIL_RESTART" = 1 ] && [ "$1" = restart ] && [ "$2" = gre-t2.service ]; then exit 1; fi''')
        self.extra='export PATH="'+str(self.bin)+':$PATH" CALL_LOG="'+str(self.root/'calls')+'"\nBACKUP_DIR="'+str(self.backups)+'"\n'

    def install_command(self,name,body):
        path=self.bin/name; path.write_text('#!/bin/sh\n'+body+'\n');path.chmod(0o755)

    def test_updates_all_peers_preserving_other_settings(self):
        traffic=self.state/'traffic.json';traffic.write_text('{"retained":123}')
        before=[dict(p) for p in self.peers]
        frp=(self.config/'frps.toml').read_bytes()
        result=self.run_shell('cli_iran_ip --ip 198.51.100.9',self.extra)
        self.assertEqual(result.returncode,0,result.stderr)
        updated=json.loads((self.state/'peers.json').read_text())['peers']
        for old,new in zip(before,updated):
            self.assertEqual(new,{**old,'local_pub':'198.51.100.9'})
            unit=(self.units/(new['gre_if']+'.service')).read_text()
            self.assertIn('local 198.51.100.9 remote '+new['remote_pub'],unit)
            self.assertIn('mtu 1300',unit)
        self.assertEqual(traffic.read_text(),'{"retained":123}')
        self.assertEqual((self.config/'frps.toml').read_bytes(),frp)
        calls=(self.root/'calls').read_text()
        self.assertNotIn('frps',calls)
        backup=next(self.backups.iterdir())
        self.assertEqual(backup.stat().st_mode&0o777,0o700)
        self.assertEqual(json.loads((backup/'peers.json').read_text())['peers'],before)

    def test_restart_failure_restores_registry_and_units(self):
        before={p:p.read_bytes() for p in [self.state/'peers.json',self.units/'gre-tunnel.service',self.units/'gre-t2.service']}
        result=self.run_shell('cli_iran_ip --ip 198.51.100.9',self.extra+'export FAIL_RESTART=1\n')
        self.assertNotEqual(result.returncode,0)
        for p,content in before.items(): self.assertEqual(p.read_bytes(),content)
        self.assertIn('Recovery failed',result.stderr)

    def test_missing_unit_aborts_before_mutation(self):
        (self.units/'gre-t2.service').unlink()
        before=(self.state/'peers.json').read_bytes()
        result=self.run_shell('cli_iran_ip --ip 198.51.100.9',self.extra)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.state/'peers.json').read_bytes(),before)
        self.assertFalse((self.root/'calls').exists())

    def test_nat_uses_local_route_address_not_unbound_public_ip(self):
        result=self.run_shell('cli_iran_ip --ip 203.0.113.9',self.extra)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('local 10.0.0.4 remote', (self.units/'gre-tunnel.service').read_text())
        self.assertEqual(json.loads((self.state/'peers.json').read_text())['peers'][0]['local_pub'],'203.0.113.9')

    def test_invalid_input_and_cancellation_do_not_mutate(self):
        before=(self.state/'peers.json').read_bytes()
        result=self.run_shell('cli_iran_ip --ip invalid',self.extra)
        self.assertNotEqual(result.returncode,0)
        result=self.run_shell("menu_iran_ip <<< $'198.51.100.9\\nn'",self.extra+'menu_import_existing() { return 0; }\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.state/'peers.json').read_bytes(),before)

    def test_menu_outputs_new_bundle_for_each_foreign_server(self):
        result=self.run_shell("menu_iran_ip <<< $'198.51.100.9\\ny'",self.extra+'menu_import_existing() { return 0; }\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.count('NavaTunnel setup-foreign --bundle'),2)
        self.assertEqual(result.stdout.count(' --force'),2)
        self.assertIn('hsh1_198.51.100.9_',result.stdout)
        self.assertIn('192.0.2.1',result.stdout)
        self.assertIn('192.0.2.2',result.stdout)
