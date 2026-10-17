from test_regressions import ScriptHarness


class RestoreCoreTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.archive=self.root/'backup.enc';self.archive.write_text('fixture')
        self.events=self.root/'events'
        self.stubs='''
ensure_backup_key() { :; }
openssl() { while [[ $# -gt 0 ]]; do if [[ "$1" == -out ]]; then touch "$2"; break; fi; shift; done; }
tar() { if [[ "$1" == -ztf ]]; then echo etc/frp/frps.toml; else echo extract >> "$EVENTS"; fi; }
ensure_dependencies_smart() { echo deps >> "$EVENTS"; }
install_frp_binaries() { echo "cores:$1" >> "$EVENTS"; }
restore_start_tunnels() { echo start >> "$EVENTS"; }
repair_traffic_monitor() { echo traffic >> "$EVENTS"; }
'''
        (self.state/'backup.key').touch()
        self.extra='export EVENTS="'+str(self.events)+'"\n'+self.stubs

    def restore(self, flags='', extra=''):
        return self.run_shell('backup_restore "'+str(self.archive)+'" '+flags,self.extra+extra)

    def test_real_restore_installs_cores_before_extract_and_restart(self):
        result=self.restore()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.events.read_text().splitlines(),['deps','cores:all','extract','start','traffic'])
        self.assertIn('restore was successful',result.stdout)

    def test_core_failure_prevents_extract_restart_and_false_success(self):
        result=self.restore(extra='\ninstall_frp_binaries() { echo failed >> "$EVENTS"; return 1; }')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('extract',self.events.read_text());self.assertNotIn('start',self.events.read_text())
        self.assertNotIn('restore was successful',result.stdout)

    def test_dry_run_does_not_install_cores_or_restart(self):
        result=self.restore('--dry-run')
        self.assertEqual(result.returncode,0,result.stderr);self.assertFalse(self.events.exists())

    def test_startup_failure_never_reports_restore_success(self):
        result=self.restore(extra='\nrestore_start_tunnels() { return 1; }')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('some tunnel services failed',result.stderr)
        self.assertNotIn('restore was successful',result.stdout)

    def test_traffic_repair_failure_prevents_restore_success(self):
        result=self.restore(extra='\nrepair_traffic_monitor() { return 1; }')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('traffic monitoring could not be initialized',result.stderr)
        self.assertNotIn('restore was successful',result.stdout)

    def test_restored_units_enabled_and_started_gre_before_frp(self):
        result=self.run_shell('restore_start_tunnels','systemctl() { echo "$*"; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('enable frps.service',result.stdout)
        self.assertIn('restart frps-2.service',result.stdout)
        self.assertLess(result.stdout.index('restart gre-t2.service'),result.stdout.index('restart frps-2.service'))

    def test_manual_stop_preserved_for_matching_gre_and_frp(self):
        (self.state/'stopped').mkdir();(self.state/'stopped/gre-t2').touch()
        result=self.run_shell('restore_start_tunnels','systemctl() { echo "$*"; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('restart frps-2.service',result.stdout);self.assertNotIn('restart gre-t2.service',result.stdout)
        self.assertIn('restart frps.service',result.stdout)

    def test_bad_executable_core_is_not_considered_installed(self):
        binary=self.root/'bad-core';binary.write_text('#!/nonexistent/interpreter\n');binary.chmod(0o755)
        result=self.run_shell('frp_binary_ready "'+str(binary)+'"')
        self.assertNotEqual(result.returncode,0)

    def test_valid_core_version_probe_succeeds(self):
        binary=self.root/'good-core';binary.write_text('#!/bin/sh\necho 0.71.0\n');binary.chmod(0o755)
        result=self.run_shell('frp_binary_ready "'+str(binary)+'"')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'')
