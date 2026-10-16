import json
from test_regressions import ScriptHarness


class DoctorPeerTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.peers[0]['peer_gre']='10.200.0.1'
        self.peers[1]['peer_gre']='10.200.0.5'
        self.write_peers()
        self.stubs='''
sysctl() { echo 1; }
lsmod() { printf 'ip_gre\\nfou\\n'; }
modprobe() { return 0; }
ip() { if [[ "$*" == *addr* ]]; then echo 'inet 10.200.0.2/30'; elif [[ "$*" == *route* ]]; then echo '[]'; fi; }
ping() { echo "PROBE:$*" >&2; printf 'rtt min/avg/max/mdev = 70/74/78/1 ms\\n'; }
'''

    def test_registry_addresses_override_legacy_defaults(self):
        result=self.run_shell('doctor_peer_targets',self.stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.splitlines(),['gre-tunnel\t10.200.0.1\tfrps','gre-t2\t10.200.0.5\tfrps-2'])
        self.assertNotIn('10.10.10.1',result.stdout)

    def test_health_check_probes_each_peer_with_correct_interface(self):
        result=self.run_shell('doctor_health_check',self.stubs+'''
ping() { printf '%s\\n' "$*" >> "$PEERS_FILE.probes"; echo 'rtt min/avg/max/mdev = 70/74/78/1 ms'; }
''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.state/'peers.json.probes').read_text().splitlines(),['-I gre-tunnel -c 2 -W 2 10.200.0.1','-I gre-t2 -c 2 -W 2 10.200.0.5'])
        self.assertIn('FRP (frps-2)',result.stdout)
        self.assertNotIn('[Failed]',result.stdout)

    def test_icmp_failure_alone_is_warning_not_false_critical_failure(self):
        result=self.run_shell('doctor_health_check',self.stubs+'\nping() { return 1; }')
        self.assertIn('does not prove the tunnel is down',result.stdout)
        self.assertNotIn('[Failed]',result.stdout)
        self.assertIn('Warning',result.stdout)

    def test_inactive_additional_frp_service_still_fails(self):
        result=self.run_shell('doctor_health_check',self.stubs+'\nsystemctl() { [[ "$*" != *frps-2* ]]; }')
        self.assertIn('FRP (frps-2)',result.stdout)
        self.assertIn('[Failed]',result.stdout)

    def test_foreign_client_destination_is_read_without_registry(self):
        self.peers=[];self.write_peers()
        (self.config/'frpc.toml').write_text('serverAddr = "10.200.0.14"\n')
        result=self.run_shell('doctor_peer_targets',self.stubs)
        self.assertEqual(result.stdout.strip(),'gre-tunnel\t10.200.0.14\tfrpc')

    def test_existing_unit_route_is_used_before_guessing_any_address(self):
        self.peers=[];self.write_peers()
        (self.units/'gre-tunnel.service').write_text('ExecStart=ip route replace 10.88.0.9/32 dev gre-tunnel\n')
        result=self.run_shell('doctor_peer_targets',self.stubs)
        self.assertEqual(result.stdout.strip(),'gre-tunnel\t10.88.0.9\tfrps')

    def test_unknown_or_invalid_peer_is_not_replaced_with_example_ip(self):
        self.peers[0]['peer_gre']='bad';self.peers[1]['peer_gre']='999.999.999.999';self.write_peers()
        result=self.run_shell('doctor_health_check',self.stubs)
        self.assertIn('No configured peer address found',result.stdout)
        self.assertNotIn('10.10.10.1',result.stdout)
        self.assertNotIn('[Failed]',result.stdout)

    def test_live_host_route_supports_unregistered_install(self):
        self.peers=[];self.write_peers()
        result=self.run_shell('doctor_peer_targets',self.stubs+'''
ip() { echo '[{"dst":"10.250.8.7/32","dev":"gre-tunnel"}]'; }
''')
        self.assertEqual(result.stdout.strip(),'gre-tunnel\t10.250.8.7\tfrps')
