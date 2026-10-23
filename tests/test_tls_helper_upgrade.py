import hashlib
from test_regressions import ScriptHarness


class TlsHelperUpgradeTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.core=self.root/'bin/NavaTunnel-core';self.events=self.root/'events'
        self.incoming=self.root/'incoming';self.incoming.mkdir()
        incoming=self.incoming/'NavaTunnel-core_linux_amd64'
        incoming.write_text('#!/bin/bash\n[[ "$1" == version ]] && echo v1.2.0\n');incoming.chmod(0o755)
        (self.incoming/'checksums.txt').write_text(hashlib.sha256(incoming.read_bytes()).hexdigest()+'  NavaTunnel-core_linux_amd64\n')
        self.core.write_text('#!/bin/bash\necho v1.1.1\n');self.core.chmod(0o755)
        self.old=self.core.read_bytes()
        self.stubs='export INCOMING="'+str(self.incoming)+'" EVENTS="'+str(self.events)+'"\n'+'''
uname() { echo x86_64; }
curl() {
    local url out
    while [[ $# -gt 0 ]]; do case "$1" in https:*) url=$1;shift;; -o) out=$2;shift 2;; *) shift;; esac; done
    cp "$INCOMING/${url##*/}" "$out"
}
systemctl() {
    echo "$*" >> "$EVENTS"
    [[ "${FAIL_RESTART:-0}" != 1 || "$1" != restart ]]
}
'''

    def test_upgrade_restarts_only_active_wss_front(self):
        (self.units/'frps-wss.service').write_text('owned front')
        result=self.run_shell('ensure_nava_core',self.stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('v1.2.0',self.core.read_text())
        events=self.events.read_text();self.assertIn('restart frps-wss.service',events)
        self.assertNotIn('restart frps.service',events);self.assertNotIn('NavaTunnel-core.service',events)

    def test_failed_front_restart_restores_previous_executable(self):
        (self.units/'frps-wss.service').write_text('owned front')
        result=self.run_shell('ensure_nava_core',self.stubs+'\nexport FAIL_RESTART=1')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.core.read_bytes(),self.old)
        self.assertIn('previous executable was restored',result.stderr)

    def test_invalid_checksum_preserves_installed_executable(self):
        (self.incoming/'checksums.txt').write_text('0'*64+'  NavaTunnel-core_linux_amd64\n')
        result=self.run_shell('ensure_nava_core',self.stubs)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.core.read_bytes(),self.old)
        self.assertIn('checksum verification failed',result.stderr)

    def test_tcp_installation_removes_old_core_without_a_download_or_tunnel_restart(self):
        result=self.run_shell('cleanup_retired_features',self.stubs+'\nensure_nava_core() { echo FORBIDDEN_DOWNLOAD >&2; return 1; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(self.core.exists());self.assertNotIn('FORBIDDEN',result.stderr)
        if self.events.exists():self.assertNotIn('restart',self.events.read_text())
