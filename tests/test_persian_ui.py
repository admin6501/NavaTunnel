from contextlib import redirect_stdout
import io
from pathlib import Path
import re
import subprocess
import unittest
from test_regressions import ScriptHarness
from test_traffic import TrafficHarness

ROOT=Path(__file__).resolve().parents[1]

class PersianInterfaceTests(unittest.TestCase):
    def test_main_and_traffic_help_are_persian(self):
        for script in ('NavaTunnel.sh','NavaTunnel-traffic.sh'):
            result=subprocess.run(['bash',str(ROOT/script),'--help'],text=True,capture_output=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('روش استفاده:',result.stdout)
            self.assertNotIn('usage:',result.stdout)
            self.assertNotIn('show this help message',result.stdout)

    def test_invalid_traffic_input_has_persian_error(self):
        result=subprocess.run(['bash',str(ROOT/'NavaTunnel-traffic.sh'),'limit','sample','bad-size'],text=True,capture_output=True,timeout=5)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('مقدار نامنفی',result.stderr)
        self.assertNotIn('invalid argument_size value',result.stderr)

    def test_no_english_interactive_prompts_or_legacy_menu_captions(self):
        forbidden=r'\b(?:Select an|Select option|Press Enter|Enter setup|Enter IRAN|Enter FOREIGN|Invalid option|Back to|PERFORMANCE & SECURITY|DIAGNOSTICS & BACKUP|MAINTENANCE & UPDATE)\b'
        for script in ROOT.glob('*.sh'):
            for number,line in enumerate(script.read_text().splitlines(),1):
                if line.lstrip().startswith('#'): continue
                if re.search(r'\b(echo|read|print)\b',line):
                    self.assertIsNone(re.search(forbidden,line),f'{script.name}:{number}: {line}')

class LocalizedTrafficDisplayTests(TrafficHarness):
    def test_card_shows_total_and_quota_direction_without_wide_table(self):
        self.engine.add(self.data,'sample',peer='192.0.2.3',limit=4*10**9,mode='download')
        self.data['sample'].update(download=10**9,upload=2*10**9)
        out=io.StringIO()
        with redirect_stdout(out): self.engine.show(self.data)
        rendered=out.getvalue()
        self.assertIn('دانلود: 1.000 GB',rendered)
        self.assertIn('مجموع: 3.000 GB',rendered)
        self.assertIn('مصرف برای سقف: 1.000 GB',rendered)
        self.assertNotIn('\t',rendered)

class RegisteredTrafficReuseTests(ScriptHarness):
    def test_reregistering_interface_reuses_custom_counter(self):
        import json
        (self.state/'traffic.json').write_text(json.dumps({'previous-name':dict(interface='gre-t2',download=10,upload=20)}))
        result=self.run_shell('traffic_register gre-t2 --interface gre-t2',
            'ensure_traffic_helper() { return 0; }\ncli_traffic() { echo "$*"; }')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.strip(),'status previous-name')
        self.assertEqual(json.loads((self.state/'traffic.json').read_text())['previous-name']['download'],10)
