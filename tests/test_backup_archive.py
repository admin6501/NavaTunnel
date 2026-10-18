import io
from pathlib import Path
import tarfile
from test_regressions import ScriptHarness


class SafeArchiveTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.destination=self.root/'destination';self.destination.mkdir()
        text=self.library.read_text().replace("target=Path('/')/name","target=Path("+repr(str(self.destination))+")/name").replace("target=Path('/')/member.name", "target=Path("+repr(str(self.destination))+")/member.name")
        self.library.write_text(text)

    def archive(self,members):
        path=self.root/'archive.tar.gz'
        with tarfile.open(path,'w:gz') as tar:
            for name,kind,data in members:
                entry=tarfile.TarInfo(name);entry.mode=0o777
                if kind=='file':entry.size=len(data);tar.addfile(entry,io.BytesIO(data))
                else:entry.type=kind;entry.linkname='/etc/shadow';tar.addfile(entry)
        return path

    def test_valid_files_extract_atomically_with_private_permissions(self):
        path=self.archive([('etc/frp/frps.toml','file',b'auth.token="secret"'),('etc/gre-panel/navalink/012345abcdef/config.json','file',b'{}')])
        result=self.run_shell('backup_archive extract "'+str(path)+'"')
        self.assertEqual(result.returncode,0,result.stderr)
        output=self.destination/'etc/frp/frps.toml'
        self.assertEqual(output.read_bytes(),b'auth.token="secret"');self.assertEqual(output.stat().st_mode & 0o777,0o600)

    def test_unsafe_members_links_and_devices_are_rejected(self):
        for entry in [('../outside','file',b'x'),('/etc/shadow','file',b'x'),('etc/ssh/authorized_keys','file',b'x'),('etc/gre-panel/key',tarfile.SYMTYPE,b''),('etc/gre-panel/key',tarfile.LNKTYPE,b''),('etc/gre-panel/key',tarfile.FIFOTYPE,b'')]:
            path=self.archive([entry]);result=self.run_shell('backup_archive extract "'+str(path)+'"')
            self.assertNotEqual(result.returncode,0,entry)
        self.assertEqual(list(self.destination.iterdir()),[])

    def test_all_members_are_validated_before_any_write(self):
        path=self.archive([('etc/frp/frps.toml','file',b'changed'),('../../outside','file',b'bad')])
        result=self.run_shell('backup_archive extract "'+str(path)+'"')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.destination/'etc/frp/frps.toml').exists())

    def test_existing_destination_symlink_cannot_escape_root(self):
        (self.destination/'etc').mkdir();(self.destination/'etc/frp').symlink_to(self.root/'outside')
        path=self.archive([('etc/frp/frps.toml','file',b'bad')])
        result=self.run_shell('backup_archive extract "'+str(path)+'"')
        self.assertNotEqual(result.returncode,0);self.assertFalse((self.root/'outside').exists())

    def test_duplicate_archive_members_are_rejected(self):
        path=self.archive([('etc/frp/frps.toml','file',b'one'),('etc/frp/frps.toml','file',b'two')])
        self.assertNotEqual(self.run_shell('backup_archive validate "'+str(path)+'"').returncode,0)
