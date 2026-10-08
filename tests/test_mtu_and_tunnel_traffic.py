import json
from test_regressions import ScriptHarness

class MtuTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.unit=self.units/'gre-t2.service'
        self.unit.write_text('[Unit]\nDescription=GRE\n[Service]\nType=oneshot\nExecStart=/bin/sh -c "ip link set dev gre-t2 up mtu 1380"\n[Install]\nWantedBy=multi-user.target\n')
        self.other=(self.units/'gre-tunnel.service').read_text()

    def test_save_apply_and_reload_persistent_mtu_for_selected_tunnel(self):
        result=self.run_shell('cli_mtu --interface gre-t2 --value 1300','iptables() { return 0; }\nip() { echo "IP:$*"; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('IP:link set dev gre-t2 mtu 1300',result.stdout)
        self.assertIn('mtu 1300',self.unit.read_text())
        self.assertIn('mtu-apply gre-t2',self.unit.read_text())
        self.assertEqual(json.loads((self.state/'mtu.json').read_text()),{'gre-t2':1300})
        self.assertEqual(self.run_shell('tunnel_mtu_get gre-t2').stdout.strip(),'1300')
        self.assertEqual((self.units/'gre-tunnel.service').read_text(),self.other)
        self.assertEqual(self.run_shell('tunnel_mtu_apply gre-t2','iptables() { return 0; }\nip() { echo "$*"; }').stdout.strip(),'link set dev gre-t2 mtu 1300')

    def test_repeated_change_has_one_boot_hook(self):
        result=self.run_shell('cli_mtu --interface gre-t2 --value 1300; cli_mtu --interface gre-t2 --value 1280','iptables() { return 0; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.unit.read_text().count('mtu-apply gre-t2'),1)
        self.assertEqual(json.loads((self.state/'mtu.json').read_text())['gre-t2'],1280)

    def test_invalid_mtu_and_interface_cannot_change_state(self):
        before=self.unit.read_text()
        for args in ('--interface gre-t2 --value 500','--interface gre-t2 --value 1500','--interface eth0 --value 1300','--interface gre-t2 --value 12345678901234567890'):
            self.assertNotEqual(self.run_shell('cli_mtu '+args).returncode,0)
        self.assertEqual(self.unit.read_text(),before)
        self.assertFalse((self.state/'mtu.json').exists())

    def test_failed_live_apply_rolls_back_unit_and_state(self):
        before=self.unit.read_text()
        result=self.run_shell('cli_mtu --interface gre-t2 --value 1300','iptables() { return 0; }\nip() { [[ "$*" != *1300* ]]; }')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.unit.read_text(),before)
        self.assertFalse((self.state/'mtu.json').exists())

    def test_low_mtu_rejected_for_kcp(self):
        self.peers[1]['frp_transport']='kcp';self.write_peers()
        result=self.run_shell('cli_mtu --interface gre-t2 --value 1300')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('1378',result.stderr)

    def test_enabling_kcp_requires_suitable_saved_mtu(self):
        (self.state/'mtu.json').write_text(json.dumps({'gre-t2':1300}))
        before=(self.state/'peers.json').read_text()
        for command in ('cli_peer_protocol --id 2 --protocol kcp','cli_loss_recovery --id 2 --mode on'):
            result=self.run_shell(command)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('1378',result.stderr)
            self.assertEqual((self.state/'peers.json').read_text(),before)

    def test_mtu_persists_through_carrier_application(self):
        (self.state/'mtu.json').write_text(json.dumps({'gre-t2':1300}))
        source=self.library.read_text()
        self.assertIn('TARGET_MTU=$(tunnel_mtu_get "$dev")',source)
        self.assertIn('mtu-apply ${IFNAME}',source)

class PerTunnelTrafficTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.data={'custom-counter':dict(interface='gre-t2',download=2**30,upload=2*2**30,mode='download',limit=4*2**30,blocked=False),
                   'other-counter':dict(interface='gre-tunnel',download=0,upload=0,mode='both',limit=0,blocked=False)}
        (self.state/'traffic.json').write_text(json.dumps(self.data))

    def test_counter_lookup_uses_interface_not_assumed_peer_id(self):
        self.assertEqual(self.run_shell('traffic_id_for_interface gre-t2').stdout.strip(),'custom-counter')

    def test_show_download_upload_total_and_charged_volume(self):
        result=self.run_shell('traffic_summary custom-counter')
        for value in ('دانلود: 1.000 GiB','آپلود: 2.000 GiB','مجموع دانلود و آپلود: 3.000 GiB','مصرف محاسبه‌شده برای سقف: 1.000 GiB','سقف مصرف: 4.000 GiB'):
            self.assertIn(value,result.stdout)

    def test_selected_traffic_limit_and_reset_do_not_target_other_tunnel(self):
        result=self.run_shell("menu_tunnel_traffic gre-t2 <<<$'2\\n100\\n4\\ny\\n0'",'cli_traffic() { echo "CALL:$*" >> "'+str(self.root/'calls')+'"; }')
        self.assertEqual(result.returncode,0,result.stderr)
        calls=(self.root/'calls').read_text()
        self.assertIn('CALL:limit custom-counter 100GB',calls)
        self.assertIn('CALL:reset custom-counter',calls)
        self.assertNotIn('other-counter',calls)

    def test_failed_refresh_still_shows_saved_usage(self):
        result=self.run_shell("menu_tunnel_traffic gre-t2 <<<'0'",'cli_traffic() { return 1; }')
        self.assertIn('آخرین مصرف ذخیره‌شده',result.stdout)
        self.assertIn('3.000 GiB',result.stdout)

    def test_missing_counter_cancel_does_not_register_or_reset(self):
        (self.state/'traffic.json').write_text('{}')
        result=self.run_shell("menu_tunnel_traffic gre-t2 <<<'n'",'traffic_register() { echo UNEXPECTED; }')
        self.assertEqual(result.returncode,0)
        self.assertNotIn('UNEXPECTED',result.stdout)
        self.assertEqual((self.state/'traffic.json').read_text(),'{}')

    def test_menu_is_vertical_and_sequential(self):
        result=self.run_shell("menu_edit_peer <<<$'2\\n0'")
        lines=result.stdout.splitlines()
        entries=[line for line in lines if line.startswith(tuple(str(n)+')' for n in range(12)))]
        self.assertEqual([int(line.split(')')[0]) for line in entries],list(range(1,12))+[0])
        self.assertIn('3.000 GiB',result.stdout)
