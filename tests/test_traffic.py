import json
from pathlib import Path
import subprocess
import tempfile
import types
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'NavaTunnel-traffic.sh'

class Firewall:
    def __init__(self):
        self.rules = {key: [] for key in ('INPUT', 'OUTPUT', 'FORWARD')}
        self.bytes = {}

    def __call__(self, *args, check=True):
        op, chain, *rest = args
        code, output = 0, ''
        if op == '-N': self.rules[chain] = []; self.bytes[chain] = 0
        elif op == '-S': code = 0 if chain in self.rules else 1
        elif op == '-C': code = 0 if tuple(rest) in self.rules.get(chain, []) else 1
        elif op == '-A': self.rules[chain].append(tuple(rest))
        elif op == '-I': self.rules[chain].insert(int(rest[0])-1, tuple(rest[1:]))
        elif op == '-D': self.rules[chain].remove(tuple(rest))
        elif op == '-F': self.rules[chain] = []
        elif op == '-X': del self.rules[chain]; del self.bytes[chain]
        elif op == '-L': output = f'0 {self.bytes[chain]} RETURN all -- * * 0.0.0.0/0 0.0.0.0/0 /* nava-count */\n'
        else: raise AssertionError(args)
        if code and check: raise subprocess.CalledProcessError(code, args)
        return subprocess.CompletedProcess(args, code, output, '')

class TrafficHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.engine = types.ModuleType('traffic_test_engine')
        code = SOURCE.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        exec(compile(code, str(SOURCE), 'exec'), self.engine.__dict__)
        self.engine.STATE = Path(self.tmp.name) / 'traffic.json'
        self.fw = Firewall()
        self.engine.ipt = self.fw
        self.data = {}
        self.engine.add(self.data, 'one', peer='192.0.2.1')
        self.engine.add(self.data, 'two', peer='192.0.2.2')

    def charge(self, name, down, up):
        d, u = self.engine.chains(name)
        self.fw.bytes[d] += down; self.fw.bytes[u] += up
        self.engine.sample(name, self.data[name])
        self.engine.enforce(name, self.data[name])

class TrafficTests(TrafficHarness):
    def test_direction_modes_and_isolated_quota(self):
        t = self.data['one']; t['limit'] = 100; t['mode'] = 'download'
        self.charge('one', 80, 500)
        self.assertFalse(t['blocked']); self.assertEqual(self.engine.consumed(t), 80)
        t['mode'] = 'upload'; self.engine.enforce('one', t)
        self.assertTrue(t['blocked'])
        self.assertFalse(self.data['two']['blocked'])
        self.assertTrue(all(('-j', 'DROP') in self.fw.rules[c] for c in self.engine.chains('one')))
        self.assertTrue(all(('-j', 'DROP') not in self.fw.rules[c] for c in self.engine.chains('two')))
        t['mode'] = 'both'; self.assertEqual(self.engine.consumed(t), 580)

    def test_reset_keeps_baseline_and_reopens(self):
        t=self.data['one']; t['limit']=100
        self.charge('one', 70, 40); self.assertTrue(t['blocked'])
        self.engine.sample('one', t)
        t['download']=t['upload']=0; self.engine.enforce('one', t)
        self.assertFalse(t['blocked'])
        self.charge('one', 5, 7)
        self.assertEqual((t['download'], t['upload']), (5, 7))

    def test_repeated_samples_never_double_charge(self):
        self.charge('one', 123, 456)
        self.engine.sample('one', self.data['one'])
        self.assertEqual(self.engine.consumed(self.data['one']), 579)

    def test_counter_reset_and_reboot_preserve_totals(self):
        self.charge('one', 100, 50)
        d,u=self.engine.chains('one')
        self.fw.bytes[d]=10; self.fw.bytes[u]=5
        self.engine.sample('one', self.data['one'])
        self.assertEqual(self.engine.consumed(self.data['one']), 165)
        self.data['one']['boot']='previous-boot'
        self.fw.bytes[d]=200; self.fw.bytes[u]=100
        self.engine.sample('one', self.data['one'])
        self.assertEqual(self.engine.consumed(self.data['one']), 465)

    def test_recreate_firewall_restores_blocked_quota(self):
        t=self.data['one']; t['limit']=100
        self.charge('one', 90, 20)
        self.fw.rules={k:[] for k in ('INPUT','OUTPUT','FORWARD')}; self.fw.bytes={}
        self.engine.sample('one', t)
        self.assertEqual(self.engine.consumed(t), 110)
        self.assertTrue(all(('-j','DROP') in self.fw.rules[c] for c in self.engine.chains('one')))

    def test_increased_or_removed_limit_unblocks(self):
        t=self.data['one']; t['limit']=100
        self.charge('one', 101, 0); self.assertTrue(t['blocked'])
        t['limit']=200; self.engine.enforce('one',t); self.assertFalse(t['blocked'])
        t['limit']=1; self.engine.enforce('one',t); self.assertTrue(t['blocked'])
        t['limit']=0; self.engine.enforce('one',t); self.assertFalse(t['blocked'])

    def test_detach_removes_only_one_tunnel_rules(self):
        self.engine.detach('one', self.data['one'])
        for c in self.engine.chains('one'): self.assertNotIn(c, self.fw.rules)
        for c in self.engine.chains('two'): self.assertIn(c, self.fw.rules)
        self.assertEqual(len(self.fw.rules['FORWARD']), 2)

    def test_units_validation_and_duplicate_endpoints(self):
        self.assertEqual(self.engine.size('1GB'), 10**9)
        self.assertEqual(self.engine.size('917'), 917*10**9)
        self.assertEqual(self.engine.size('0'), 0)
        self.assertEqual(self.engine.size(' 1gb '), 10**9)
        self.assertEqual(self.engine.size('2.5GB'), 2500000000)
        for bad in ('-1', 'NaN', '1XB', 'abc', '1GiB', '2.5MB', '100B', '1TB'):
            with self.assertRaises(ValueError): self.engine.size(bad)
        with self.assertRaises(ValueError): self.engine.add(self.data,'dup',peer='192.0.2.1')
        with self.assertRaises(ValueError): self.engine.add(self.data,'bad;name',peer='192.0.2.3')
        with self.assertRaises(ValueError): self.engine.add(self.data,'bad',peer='::1')

    def test_failed_upload_read_does_not_partially_charge_download(self):
        before=dict(self.data['one'])
        d,u=self.engine.chains('one')
        self.fw.bytes[d]=100
        original=self.engine.ipt
        def fail_upload(*args,**kwargs):
            if args[0]=='-L' and args[1]==u:
                raise subprocess.CalledProcessError(1,args)
            return original(*args,**kwargs)
        self.engine.ipt=fail_upload
        with self.assertRaises(subprocess.CalledProcessError):
            self.engine.sample('one',self.data['one'])
        self.assertEqual(self.data['one'],before)
        self.engine.ipt=original
        self.engine.sample('one',self.data['one'])
        self.assertEqual(self.data['one']['download'],100)

    def test_state_persistence_and_permissions(self):
        self.charge('one', 17, 33); self.engine.save(self.data)
        disk=json.loads(self.engine.STATE.read_text())
        self.assertEqual(disk['one']['download'],17)
        self.assertEqual(disk['one']['upload'],33)
        self.assertEqual(self.engine.STATE.stat().st_mode & 0o777,0o600)


class TrafficCliTests(TrafficHarness):
    def invoke(self, *args):
        import contextlib
        import io
        from unittest.mock import patch
        self.engine.save(self.data)
        with patch.object(self.engine.sys, 'argv', ['traffic', *args]), \
             patch.object(self.engine.os, 'geteuid', return_value=0), \
             contextlib.redirect_stdout(io.StringIO()):
            self.engine.main()
        self.data=json.loads(self.engine.STATE.read_text())

    def test_cli_limit_mode_reset_and_remove(self):
        d,u=self.engine.chains('one')
        self.fw.bytes[d]=80; self.fw.bytes[u]=60
        self.invoke('limit','one','0.0000001GB','--mode','download')
        self.assertEqual(self.data['one']['limit'],100)
        self.assertFalse(self.data['one']['blocked'])
        self.invoke('mode','one','both')
        self.assertTrue(self.data['one']['blocked'])
        self.invoke('reset','one')
        self.assertFalse(self.data['one']['blocked'])
        self.assertEqual(self.data['one']['download'],0)
        self.fw.bytes[d]+=9
        self.invoke('status','one')
        self.assertEqual(self.data['one']['download'],9)
        self.invoke('remove','one')
        self.assertNotIn('one',self.data)
        self.assertIn('two',self.data)

    def test_partial_chain_creation_is_repaired(self):
        d,_=self.engine.chains('one')
        self.fw.rules[d]=[]
        self.engine.ensure('one',self.data['one'])
        self.assertIn(('-m','comment','--comment','nava-count','-j','RETURN'),self.fw.rules[d])

if __name__ == '__main__': unittest.main()
