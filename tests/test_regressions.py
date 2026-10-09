import json
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest

ROOT=Path(__file__).resolve().parents[1]

class ScriptHarness(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        self.state=self.root/'state';self.config=self.root/'frp';self.units=self.root/'units'
        for folder in (self.state,self.config,self.units,self.root/'bin'):folder.mkdir()
        source=(ROOT/'NavaTunnel.sh').read_text().rsplit('\nif [[ $# -gt 0 ]]; then',1)[0]
        for a,b in [('/etc/gre-panel',str(self.state)),('/etc/frp',str(self.config)),('/etc/systemd/system',str(self.units)),('/usr/local/bin',str(self.root/'bin'))]:source=source.replace(a,b)
        self.library=self.root/'library.sh';self.library.write_text(source)
        self.peers=[dict(id=1,name='same-name',remote_pub='192.0.2.1',gre_if='gre-tunnel',frps_svc='frps',legacy=True,ports=[443]),dict(id=2,name='same-name',remote_pub='192.0.2.2',gre_if='gre-t2',frps_svc='frps-2',legacy=False,ports=[8443])]
        self.write_peers()
        (self.config/'frps.toml').write_text('bindPort = 7000\nauth.token = "test"\n')
        (self.config/'frps-2.toml').write_text('bindPort = 7001\n')
        for name in ('gre-tunnel','gre-t2','frps','frps-2','gre-chaff'):(self.units/(name+'.service')).write_text('fixture')

    def write_peers(self):
        (self.state/'peers.json').write_text(json.dumps({'peers':self.peers}))

    def run_shell(self, command, extra=''):
        stubs='''
systemctl() { return 0; }
ip() { return 0; }
ufw() { return 1; }
cli_traffic() { return 0; }
watchdog_get_peer_gre() { return 0; }
remove_tunnel_force() { echo "FORBIDDEN global teardown" >&2; return 98; }
'''
        return subprocess.run(['bash','-c','source "$1"\n'+stubs+extra+'\n'+command,'regression',str(self.library)],text=True,capture_output=True,timeout=5)

class ScriptRegressionTests(ScriptHarness):
    def test_remove_legacy_peer_preserves_second_peer(self):
        result=self.run_shell('cli_remove_peer --id 1 --force')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual([p['id'] for p in json.loads((self.state/'peers.json').read_text())['peers']],[2])
        self.assertFalse((self.units/'frps.service').exists())
        self.assertFalse((self.config/'frps.toml').exists())
        self.assertTrue((self.units/'frps-2.service').exists())
        self.assertTrue((self.units/'gre-t2.service').exists())
        self.assertTrue((self.config/'frps-2.toml').exists())

    def test_edit_ports_writes_valid_server_toml(self):
        result=self.run_shell('cli_edit_peer --id 1 --ports "9443, 10443"')
        self.assertEqual(result.returncode,0,result.stderr)
        config=tomllib.loads((self.config/'frps.toml').read_text())
        self.assertEqual(config['bindPort'],7000)
        self.assertNotIn('proxies',config)
        self.assertEqual(config['allowPorts'],[{'start':9443,'end':9443},{'start':10443,'end':10443}])
        self.assertEqual((self.config/'frps.toml').stat().st_mode&0o777,0o600)

    def test_duplicate_peer_names_cannot_bypass_port_conflict(self):
        before=(self.config/'frps.toml').read_text()
        result=self.run_shell('cli_edit_peer --id 1 --ports 8443')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.config/'frps.toml').read_text(),before)

    def test_missing_option_value_returns_without_looping(self):
        for command in ('cli_add_peer --token','cli_edit_peer --id','cli_setup_foreign --bundle','cli_remove_peer --id','backup_now --keep'):
            result=self.run_shell(command)
            self.assertNotEqual(result.returncode,0,command)
            self.assertIn('The value of this option is not entered',result.stderr)

    def test_carrier_mode_command_is_not_shadowed(self):
        result=self.run_shell('cli_carrier mode fou:443','carrier_apply() { echo "applied:$1"; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('applied:fou:443',result.stdout)
        self.assertEqual(json.loads((self.state/'carrier.json').read_text())['mode'],'fou:443')

    def test_carrier_status_python_output_compiles(self):
        result=self.run_shell('cli_carrier status')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('Number of redirects:',result.stdout)

    def test_wss_without_relay_does_not_touch_interfaces(self):
        result=self.run_shell('carrier_apply wss:8443','carrier_init_kernel() { echo "KERNEL_TOUCHED"; }')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('KERNEL_TOUCHED',result.stdout)

    def test_invalid_and_overflowing_ports_are_rejected(self):
        for value in ('0','65536','18446744073709551617','abc'):
            self.assertNotEqual(self.run_shell('is_valid_port '+value).returncode,0,value)
        self.assertEqual(self.run_shell('is_valid_port 65535').returncode,0)

    def test_client_only_peer_options_are_not_reported_as_applied(self):
        result=self.run_shell('cli_edit_peer --id 1 --encrypt')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('FRP client on the foreign server',result.stderr)


class FailureRegressionTests(ScriptHarness):
    # Reuse fixtures without re-running inherited regression tests below.
    def test_busy_server_port_returns_failure_and_clean_stdout(self):
        result=self.run_shell('ensure_port_available 7000 server','is_port_in_use() { return 0; }; log_msg() { :; }')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,'')

    def test_warn_only_port_returns_numeric_stdout(self):
        result=self.run_shell('ensure_port_available 7000 proxy 0 warn-only','is_port_in_use() { return 0; }; log_msg() { :; }')
        self.assertEqual(result.returncode,0)
        self.assertEqual(result.stdout.strip(),'7000')

    def test_archive_failure_cannot_produce_successful_backup(self):
        extra='''
ensure_backup_key() { touch "${NAVATUNNEL_STATE_DIR}/backup.key"; }
tar() { return 2; }
openssl() {
    local outfile
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-out" ]]; then outfile="$2"; shift 2; else shift; fi
    done
    cat >/dev/null
    touch "$outfile"
}
'''
        result=self.run_shell('backup_now "'+str(self.root/'backups')+'"',extra)
        self.assertNotEqual(result.returncode,0,result.stdout)
        self.assertEqual(list((self.root/'backups').glob('*.enc')),[])

    def test_archive_with_only_server_binary_is_not_a_complete_install(self):
        import tarfile
        payload=self.root/'frps';payload.write_text('test binary')
        archive=self.root/'partial.tar.gz'
        with tarfile.open(archive,'w:gz') as tar:
            tar.add(payload,arcname='frp_fixture/frps')
        extra="""
detect_arch() { FRP_ARCH=amd64; }
get_latest_frp_version() { FRP_VERSION=999; }
upstream_release_asset_url() { echo fixture; }
download_with_fallback() { cp \""""+str(archive)+"""\" \"$1\"; }
"""
        result=self.run_shell('install_frp_binaries all',extra)
        self.assertNotEqual(result.returncode,0,result.stdout)
        self.assertNotIn('Install FRP done in',result.stdout)

    def test_failed_dependencies_are_not_cached_as_installed(self):
        extra='''
log_msg() { :; }
command() {
    if [[ "$1" == "-v" ]]; then
        case "$2" in ping|apt-get|yum) return 1 ;; *) return 0 ;; esac
    fi
    builtin command "$@"
}
'''
        result=self.run_shell('ensure_dependencies_smart',extra)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.state/'.deps_installed').exists())

if __name__=='__main__':unittest.main()
