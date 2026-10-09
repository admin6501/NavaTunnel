import json
from pathlib import Path
from test_regressions import ScriptHarness

class CoverCustomTests(ScriptHarness):
    def test_saved_dpi_limits_drive_actual_firewall_rules(self):
        result=self.run_shell('cli_cover_configure dpi --rate 120/minute --burst 25; dpi_shield_on',
            'dpi_collect_reverse_ports() { echo 9443; }; iptables() { echo "$*" >> "'+str(self.root/'rules')+'"; [[ "$*" != *"-C "* && "$*" != *"-L "* ]]; }; sysctl() { return 0; }; ensure_navatunnel_bin() { :; }')
        self.assertEqual(result.returncode,0,result.stderr)
        rules=(self.root/'rules').read_text()
        self.assertIn('--hashlimit-above 120/minute --hashlimit-burst 25',rules)
        self.assertNotIn('--hashlimit-above 60/sec',rules)

    def test_invalid_custom_configuration_keeps_saved_settings(self):
        self.run_shell('init_perf_json')
        before=(self.state/'perf.json').read_bytes()
        for command in ('cli_cover_configure dpi --rate bad --burst 2','cli_cover_configure dpi --rate 60/sec --burst 0','cli_cover_configure chaff --min-ms 200 --max-ms 100 --min-bytes 8 --max-bytes 200','cli_cover_configure chaff --min-ms 100 --max-ms 200 --min-bytes 8 --max-bytes 1400'):
            self.assertNotEqual(self.run_shell(command).returncode,0)
            self.assertEqual((self.state/'perf.json').read_bytes(),before)

    def test_custom_ping_size_respects_stored_tunnel_mtu(self):
        (self.state/'mtu.json').write_text('{"gre-t2":1000}')
        result=self.run_shell('cli_cover_configure chaff --min-ms 200 --max-ms 400 --min-bytes 64 --max-bytes 1200')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('MTU',result.stderr)

    def prepare_peers(self):
        for n,p in enumerate(self.peers):p.update(peer_gre='10.200.0.'+str(1+4*n),chaff_profile='off')
        self.write_peers()
        return 'install_chaff_script() { return 0; }; ss() { return 0; }'

    def test_global_profile_overrides_old_off_on_every_peer(self):
        result=self.run_shell('cli_perf chaff low',self.prepare_peers())
        self.assertEqual(result.returncode,0,result.stderr)
        for file in ('gre-chaff.service','gre-chaff-2.service'):
            self.assertIn(' low ',(self.units/file).read_text())
        result=self.run_shell('cli_perf chaff mid',self.prepare_peers())
        self.assertEqual(result.returncode,0,result.stderr)
        for file in ('gre-chaff.service','gre-chaff-2.service'):
            self.assertIn(' mid ',(self.units/file).read_text())
            self.assertNotIn(' low ',(self.units/file).read_text())

    def test_custom_profile_and_active_edits_rewrite_all_services(self):
        stubs=self.prepare_peers()
        result=self.run_shell('cli_cover_configure chaff --min-ms 500 --max-ms 900 --min-bytes 80 --max-bytes 200; cli_perf chaff custom; cli_cover_configure chaff --min-ms 600 --max-ms 1000 --min-bytes 100 --max-bytes 300',stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        for file in ('gre-chaff.service','gre-chaff-2.service'):
            self.assertIn(' custom 600 1000 100 300',(self.units/file).read_text())
        self.assertEqual((self.state/'perf.json').stat().st_mode&0o777,0o600)

    def test_failed_activation_does_not_print_success(self):
        result=self.run_shell('cli_perf chaff low',self.prepare_peers()+'; systemctl() { [[ "$1" != restart ]]; }')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('Cover traffic mode on low was placed',result.stdout)

    def test_embedded_and_tracked_generator_match(self):
        main=(Path(__file__).resolve().parents[1]/'NavaTunnel.sh').read_text()
        embedded=main.split('cat <<\'EOF\' > "$CHAFF_BIN"\n',1)[1].split('\nEOF',1)[0]+'\n'
        self.assertEqual(embedded,(Path(__file__).resolve().parents[1]/'NavaTunnel-chaff.sh').read_text())

    def test_generator_uses_custom_ranges_for_real_ping_command(self):
        import os,subprocess
        folder=self.root/'mock-bin';folder.mkdir()
        (folder/'sleep').write_text('#!/bin/sh\nexit 0\n');(folder/'sleep').chmod(0o755)
        ping=folder/'ping'
        ping.write_text('#!/bin/sh\necho "$*" >> "'+str(self.root/'ping-calls')+'"\nkill -TERM "$PPID"\n')
        ping.chmod(0o755)
        script=Path(__file__).resolve().parents[1]/'NavaTunnel-chaff.sh'
        result=subprocess.run(['bash',str(script),'10.200.0.1','custom','100','100','123','123'],env={**os.environ,'PATH':str(folder)+':'+os.environ['PATH']},capture_output=True,text=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('-s 123',(self.root/'ping-calls').read_text())

    def test_menu_custom_configuration_saves_valid_values(self):
        result=self.run_shell("menu_cover_configure dpi <<<$'90/sec\\n180'")
        self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads((self.state/'perf.json').read_text())
        self.assertEqual(data['dpi_rate'],'90/sec')
        self.assertEqual(data['dpi_burst'],180)
        result=self.run_shell("menu_cover_configure chaff <<<$'300\\n900\\n64\\n900'")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads((self.state/'perf.json').read_text())['chaff_custom'],dict(min_ms=300,max_ms=900,min_bytes=64,max_bytes=900))
