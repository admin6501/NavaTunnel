import json
from test_regressions import ScriptHarness


class TrafficRepairTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        self.data={'gre-tunnel':dict(interface='gre-tunnel',download=1643625000000,upload=204405000000,limit=917000000000,mode='download',blocked=True)}
        self.statefile=self.state/'traffic.json';self.statefile.write_text(json.dumps(self.data))
        helper=self.root/'bin/NavaTunnel-traffic.sh'
        helper.write_text('#!/bin/bash\necho "$*" >> "$TEST_EVENTS"\nif [[ "$1" == "$TEST_FAIL" ]]; then exit 1; fi\n')
        self.events=self.root/'events'
        self.stubs='''
ensure_traffic_helper() { echo helper >> "$TEST_EVENTS"; }
install_traffic_monitor() { echo install >> "$TEST_EVENTS"; }
systemctl() { echo "systemctl:$*" >> "$TEST_EVENTS"; [[ "$*" != "$TEST_SYSTEM_FAIL" ]]; }
'''
        self.stubs='export TEST_EVENTS="'+str(self.events)+'"\n'+self.stubs

    def test_repair_initializes_sampling_and_timer_without_resetting_saved_state(self):
        result=self.run_shell('repair_traffic_monitor',self.stubs)
        self.assertEqual(result.returncode,0,result.stderr)
        lines=self.events.read_text().splitlines()
        self.assertEqual(lines[:4],['helper','install','discover','tick'])
        self.assertIn('systemctl:enable --now NavaTunnel-traffic.timer',lines)
        self.assertIn('systemctl:is-active --quiet NavaTunnel-traffic.timer',lines)
        self.assertEqual(json.loads(self.statefile.read_text()),self.data)
        self.assertNotIn('reset',lines)

    def test_counter_failure_never_reports_success_or_enables_timer(self):
        for action in ('discover','tick'):
            self.events.unlink(missing_ok=True)
            result=self.run_shell('repair_traffic_monitor',self.stubs+'\nexport TEST_FAIL='+action)
            self.assertNotEqual(result.returncode,0)
            self.assertNotIn('monitoring is active',result.stdout)
            self.assertNotIn('enable --now',self.events.read_text())

    def test_timer_failure_is_propagated(self):
        result=self.run_shell('repair_traffic_monitor',self.stubs+'\nexport TEST_SYSTEM_FAIL="enable --now NavaTunnel-traffic.timer"')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('monitoring is active',result.stdout)

    def test_repair_cli_is_routed_to_monitor_repair(self):
        # Override the harness stub with the real CLI wrapper.
        text=self.library.read_text();start=text.index('cli_traffic() {');end=text.index('\ntraffic_register() {',start)
        result=self.run_shell('cli_traffic repair',self.stubs+'\n'+text[start:end])
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('tick',self.events.read_text().splitlines())
