import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
SCRIPT=ROOT/'tools/test-bootstrap-presets-native.sh'
class NativeDriver(unittest.TestCase):
    def test_help_selects_native_entry_point(self):
        self.assertTrue(SCRIPT.exists(),'native preset verification entry point missing')
        result=subprocess.run([str(SCRIPT),'--help'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr); self.assertIn('--fixture-parent',result.stdout)
    def test_missing_godot_fails_before_acquisition_and_retains_json_evidence(self):
        self.assertTrue(SCRIPT.exists(),'native preset verification entry point missing')
        with tempfile.TemporaryDirectory(prefix='native space ü ') as tmp:
            root=Path(tmp)
            result=subprocess.run([str(SCRIPT),'--preset','godot','--fixture-parent',str(root/'fixtures'),'--evidence-root',str(root/'evidence')],env={**os.environ,'GODOT':'/no-such-fixture-godot'},capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            receipts=list((root/'evidence').glob('*/receipt.json')); self.assertEqual(len(receipts),1,result.stdout+result.stderr)
            report=json.loads(receipts[0].read_text()); self.assertFalse(report['passed']); self.assertIn('prerequisites',report['error'].lower())
            self.assertFalse(list((root/'fixtures').rglob('gut.zip')))
if __name__=='__main__': unittest.main()
