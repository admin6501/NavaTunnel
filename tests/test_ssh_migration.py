import io
import json
import subprocess
import tarfile
from test_regressions import ScriptHarness


class SshMigrationTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        (self.state/'backup.key').write_text('original-private-key')
        self.backup=self.root/'selected.enc'
        with tarfile.open(self.backup,'w:gz') as tar:
            info=tarfile.TarInfo('etc/frp/frps.toml');data=b'bindPort=7000\n';info.size=len(data);tar.addfile(info,io.BytesIO(data))
        (self.root/'bin/NavaTunnel-traffic.sh').write_text('#!/bin/bash\ntrue\n')
        (self.root/'bin/NavaTunnel-extra.sh').write_text('#!/bin/bash\ntrue\n')
        self.events=self.root/'events';self.upload=self.root/'uploaded.tar.gz'
        self.stubs='export MIG_EVENTS="'+str(self.events)+'" MIG_UPLOAD="'+str(self.upload)+'"\n'+'''
ensure_traffic_helper() { return 0; }
openssl() {
    local src dst
    while [[ $# -gt 0 ]]; do case "$1" in -in) src=$2;shift 2;; -out) dst=$2;shift 2;; *) shift;; esac; done
    cp "$src" "$dst"
}
ssh() {
    local remote=${!#}
    echo "$remote" >> "$MIG_EVENTS"
    case "$remote" in
        'if [ '* ) [[ "$MIG_FAIL" != preflight ]] || return 1; echo NAVATUNNEL_ROOT ;;
        *mktemp* ) echo /var/tmp/navatunnel-migrate.TEST1234 ;;
        *'tar -xzf'* ) cat > "$MIG_UPLOAD" ;;
        *run.sh* ) [[ "$MIG_FAIL" != install ]] || return 1 ;;
    esac
}
'''

    def migrate(self,extra='',flags=''):
        return self.run_shell('cli_migrate --host 45.144.17.77 --backup "'+str(self.backup)+'" '+flags,self.stubs+extra)

    def test_upload_contains_scripts_original_key_backup_and_noninteractive_installer(self):
        result=self.migrate()
        self.assertEqual(result.returncode,0,result.stderr)
        with tarfile.open(self.upload) as tar:
            members={m.name.removeprefix('./'):m for m in tar.getmembers()}
            for name in ('NavaTunnel.sh','NavaTunnel-traffic.sh','backup.enc','backup.key','run.sh'):self.assertIn(name,members)
            self.assertEqual(tar.extractfile(members['backup.key']).read(),b'original-private-key')
            self.assertEqual(members['backup.key'].mode & 0o777,0o600)
            script=tar.extractfile(members['run.sh']).read().decode()
            self.assertIn('backup restore "$archive" --local-ip "$public_ip"',script)
            self.assertIn('pre-migration-',script)
            syntax=subprocess.run(['bash','-n'],input=script,text=True,capture_output=True)
            self.assertEqual(syntax.returncode,0,syntax.stderr)
            self.assertNotIn('StrictHostKeyChecking=no',script)
        self.assertIn('SSH migration completed',result.stdout)
        self.assertNotIn('original-private-key',result.stdout+result.stderr+self.events.read_text())
        self.assertIn("rm -rf -- '/var/tmp/navatunnel-migrate.TEST1234'",self.events.read_text())

    def test_passwordless_sudo_is_used_for_remote_privileged_steps(self):
        sudo_stubs=self.stubs.replace('echo NAVATUNNEL_ROOT','echo NAVATUNNEL_SUDO')
        result=self.run_shell('cli_migrate --host 45.144.17.77 --user ubuntu --backup "'+str(self.backup)+'"',sudo_stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        commands=self.events.read_text()
        self.assertIn('sudo -n mktemp',commands)
        self.assertIn('sudo -n tar -xzf',commands)
        self.assertIn('sudo -n bash',commands)

    def test_failed_ssh_preflight_never_uploads_or_installs(self):
        result=self.migrate('\nexport MIG_FAIL=preflight')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.upload.exists())
        self.assertNotIn('mktemp',self.events.read_text())

    def test_failed_remote_restore_does_not_report_migration_success(self):
        result=self.migrate('\nexport MIG_FAIL=install')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Migration failed on the destination',result.stderr)
        self.assertNotIn('SSH migration completed',result.stdout)
        self.assertIn("rm -rf -- '/var/tmp/navatunnel-migrate.TEST1234'",self.events.read_text())

    def test_shell_injection_inputs_and_missing_values_are_rejected_before_ssh(self):
        for command in ('cli_migrate --host "45.144.17.77;id"','cli_migrate --host 45.144.17.77 --port "22;id"','cli_migrate --host 45.144.17.77 --user "root;id"','cli_migrate --host'):
            result=self.run_shell(command,self.stubs)
            self.assertNotEqual(result.returncode,0,command)
        self.assertFalse(self.events.exists())

    def test_bad_backup_stops_before_remote_directory_creation(self):
        self.backup.write_text('invalid backup')
        result=self.migrate()
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('mktemp',self.events.read_text())
        self.assertFalse(self.upload.exists())

    def test_menu_passes_selected_ssh_fields_to_migration(self):
        result=self.run_shell("menu_migrate <<<$'45.144.17.77\\n2222\\nubuntu\\n/key\\n/backup.enc\\n203.0.113.1'",'cli_migrate() { printf "%s\\n" "$@"; }')
        self.assertEqual(result.returncode,0,result.stderr)
        for value in ('45.144.17.77','2222','ubuntu','/key','/backup.enc','203.0.113.1'):self.assertIn(value,result.stdout)

    def test_rebinding_preserves_remote_gre_target_tokens_and_traffic(self):
        self.peers[0]['local_pub']='192.0.2.9';self.peers[0]['token']='secretToken';self.write_peers()
        unit=self.units/'gre-tunnel.service';unit.write_text('ip link add gre-tunnel type gre local 192.0.2.9 remote 198.51.100.1\nip route add 10.200.0.1/32 dev gre-tunnel\n')
        traffic=self.state/'traffic.json';traffic.write_text('{"counter":{"download":900}}')
        result=self.run_shell('restore_rebind_local_ip 45.144.17.77',"ip() { echo '[{\"prefsrc\":\"10.0.0.8\"}]'; }")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('local 10.0.0.8 remote 198.51.100.1',unit.read_text())
        data=json.loads((self.state/'peers.json').read_text());self.assertEqual(data['peers'][0]['local_pub'],'45.144.17.77');self.assertEqual(data['peers'][0]['token'],'secretToken')
        self.assertEqual(json.loads(traffic.read_text()),{'counter':{'download':900}})

    def test_backup_menu_option_eight_enters_migration(self):
        result=self.run_shell("menu_diagnostics_backup <<<$'8\\n0'",'menu_migrate() { echo MIGRATION_MENU; }; pause_prompt() { :; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('MIGRATION_MENU',result.stdout)

    def test_cancelled_menu_has_no_ssh_side_effect(self):
        result=self.run_shell("menu_migrate <<< ''",self.stubs)
        self.assertEqual(result.returncode,0,result.stderr);self.assertFalse(self.events.exists())
