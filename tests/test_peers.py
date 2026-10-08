import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'NavaTunnel.sh'

class PeerAllocationTests(unittest.TestCase):
    def next_id(self, ids):
        body = re.search(r'^peer_next_id\(\) \{\n.*?^\}', SCRIPT.read_text(), re.M | re.S).group()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'peers.json'
            path.write_text(json.dumps({'peers':[{'id':i} for i in ids]}))
            result = subprocess.run(['bash','-c',
                'peer_require_py() { return 0; }\nPEERS_FILE="$1"\n'+body+'\npeer_next_id',
                'peer-test',str(path)], text=True,capture_output=True,check=True)
            return int(result.stdout.strip())

    def test_sixth_foreign_server_can_be_added(self):
        self.assertEqual(self.next_id([1,2,3,4,5]),6)

    def test_large_peer_registry_has_no_fixed_cap(self):
        self.assertEqual(self.next_id(range(1,501)),501)

    def test_freed_id_is_reused(self):
        self.assertEqual(self.next_id([1,2,4,5,6,7,100]),3)

    def test_empty_registry_starts_at_one(self):
        self.assertEqual(self.next_id([]),1)

class FrpBundleTests(unittest.TestCase):
    def inspect(self, bundle):
        return subprocess.run(['bash',str(SCRIPT),'bundle','inspect',bundle],
                              text=True,capture_output=True)

    def test_frp_bundle_still_parses_and_masks_token(self):
        token='AsecretToken123456789'
        bundle=f'hsh1_203.0.113.1_7000_10.10.10.2_10.10.10.1_{token}_443_fou443-55555'
        result=self.inspect(bundle)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('203.0.113.1',result.stdout)
        self.assertIn('7000',result.stdout)
        self.assertNotIn(token,result.stdout)

    def test_non_frp_bundle_prefix_is_rejected(self):
        result=self.inspect('other_203.0.113.1_7000_token')
        self.assertNotEqual(result.returncode,0)

if __name__=='__main__': unittest.main()
