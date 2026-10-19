import hashlib
from pathlib import Path
from test_regressions import ScriptHarness


class ClusterCoreUpgradeTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.core=self.root/'bin/NavaTunnel-core'
        self.marker=self.root/'daemon-new'
        self.events=self.root/'core-events'
        (self.units/'NavaTunnel-core.service').write_text('owned Cluster service')
        self.incoming=self.root/'incoming';self.incoming.mkdir()
        self.new=self.incoming/'NavaTunnel-core_linux_amd64'
        self.new.write_text(self.binary('v1.1.1'));self.new.chmod(0o755)
        (self.incoming/'checksums.txt').write_text(hashlib.sha256(self.new.read_bytes()).hexdigest()+'  NavaTunnel-core_linux_amd64\n')
        self.stubs='''
uname() { echo x86_64; }
curl() {
    local url="$5" out="$7"
    while [[ $# -gt 0 ]]; do
        case "$1" in https:*) url=$1; shift;; -o) out=$2; shift 2;; *) shift;; esac
    done
    cp "$INCOMING/${url##*/}" "$out"
}
systemctl() {
    echo "$*" >> "$CORE_EVENTS"
    if [[ "$1" == restart ]]; then
        if [[ "${FAIL_NEW:-0}" == 1 && "$("$CORE_FILE" version)" == v1.1.1 ]]; then return 1; fi
        touch "$DAEMON_MARKER"
    fi
    return 0
}
'''
        self.env='\n'.join('export '+name+'="'+str(value)+'"' for name,value in [('INCOMING',self.incoming),('CORE_EVENTS',self.events),('CORE_FILE',self.core),('DAEMON_MARKER',self.marker)])+'\n'

    def binary(self,version):
        return '#!/bin/bash\nif [[ "$1" == version ]]; then echo '+version+'; elif [[ "$1" == daemon ]]; then if [[ -f "'+str(self.marker)+'" ]]; then echo \'{"version":"v1.1.1"}\'; else echo \'{"version":"v1.1.0"}\'; fi; else exit 1; fi\n'

    def install_old(self):
        self.core.write_text(self.binary('v1.1.0'));self.core.chmod(0o755)

    def test_new_binary_restarts_an_old_background_process(self):
        self.core.write_text(self.binary('v1.1.1'));self.core.chmod(0o755)
        result=self.run_shell('ensure_nava_core',self.env+self.stubs+'\ncurl() { echo FORBIDDEN_DOWNLOAD >&2; return 1; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertIn('restart NavaTunnel-core.service',self.events.read_text())
        self.assertNotIn('FORBIDDEN_DOWNLOAD',result.stderr)

    def test_verified_upgrade_restarts_existing_core_and_preserves_tunnels(self):
        self.install_old();before=(self.state/'peers.json').read_bytes()
        result=self.run_shell('ensure_nava_core',self.env+self.stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.core.read_text(),self.binary('v1.1.1'))
        self.assertTrue(self.marker.exists())
        self.assertEqual((self.state/'peers.json').read_bytes(),before)
        self.assertNotIn('restart frps',self.events.read_text())

    def test_failed_upgrade_restores_previous_executable(self):
        self.install_old();before=self.core.read_bytes()
        result=self.run_shell('ensure_nava_core',self.env+self.stubs+'\nexport FAIL_NEW=1')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.core.read_bytes(),before)
        self.assertIn('previous executable was restored',result.stderr)

    def test_matching_daemon_is_not_restarted(self):
        self.core.write_text(self.binary('v1.1.1'));self.core.chmod(0o755);self.marker.touch()
        result=self.run_shell('ensure_nava_core',self.env+self.stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('restart',self.events.read_text())
