import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('bootstrap_presets',ROOT/'skills/ba-bootstrap/scripts/bootstrap_linux.py'); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
class Presets(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='preset ü space '); self.addCleanup(self.tmp.cleanup); self.root=Path(self.tmp.name)
        self.id=b.identity('Starter Project','A useful desktop app',str(self.root),'cicely-f'); self.engine=b.Bootstrap(self.root/'state',request=lambda *_:(404,None))
    def test_godot_preparation_retains_vendor_bytes_import_uids_and_renderer(self):
        zipbytes=io.BytesIO()
        with zipfile.ZipFile(zipbytes,'w') as z:
            for name,data in {'plugin.cfg':b'[plugin]\n','gut_cmdln.gd':b'extends SceneTree\n','LICENSE.md':b'License\r\n','binary.bin':bytes(range(256))}.items(): z.writestr('Gut-abc/addons/gut/'+name,data)
        self.engine.metadata=lambda _: {'object':{'type':'commit','sha':'a'*40}}
        self.engine.fetch=lambda _,p:Path(p).write_bytes(zipbytes.getvalue())
        def runner(args,**kwargs):
            root=Path(args[args.index('--path')+1])
            for path in root.rglob('*.gd'): Path(str(path)+'.uid').write_text('uid://fixture\n')
            return subprocess.CompletedProcess(args,0,'imported')
        self.engine.runner=runner; selection=b.selection(self.id,'godot',renderer='mobile'); journal=self.engine.new_journal(self.id,selection); self.engine.save(journal)
        with patch.dict('os.environ',{'GODOT':'/bin/true'}): source,manifest=self.engine.prepare(journal)
        self.assertIn('renderer/rendering_method="mobile"',(source/'project.godot').read_text())
        self.assertEqual((source/'addons/gut/binary.bin').read_bytes(),bytes(range(256)))
        self.assertEqual((source/'addons/gut/LICENSE.md').read_bytes(),b'License\r\n')
        self.assertTrue((source/'tools/verify_selftest.sh').is_file())
        self.assertTrue(any(e['path'].endswith('.gd.uid') for e in manifest))
        self.engine.freeze(journal,source,manifest)
        self.engine.snapshot(journal)
        self.engine.fetch=lambda *_:self.fail('prepared retries must not redownload')
        self.engine.prepare(journal)
    def test_godot_failed_download_rolls_back_source_and_keeps_failure_receipt(self):
        self.engine.metadata=lambda _: {'object':{'type':'commit','sha':'a'*40}}
        def failed(*_): raise RuntimeError('network fixture failure')
        self.engine.fetch=failed; journal=self.engine.new_journal(self.id,b.selection(self.id,'godot')); self.engine.save(journal)
        with self.assertRaisesRegex(RuntimeError,'network fixture'): self.engine.prepare(journal)
        source=self.engine.preparation_source(journal)
        self.assertFalse((source/'project.godot').exists())
        self.assertEqual(b.read_json(source/'tools/verify.json')['preset'],'foundation')
        self.assertTrue(journal['preparation']['checkpoints']['godot-source-failed']['rolledBack'])
    def test_tauri_preparation_uses_verified_generator_and_freezes_locks(self):
        payload=b'verified generator archive fixture'; integrity='sha512-'+base64.b64encode(hashlib.sha512(payload).digest()).decode(); calls=[]
        self.engine.metadata=lambda url: {'versions':[{'num':'2.5.0','yanked':False}]} if 'crates.io' in url else {'versions':{'3.1.0':{'version':'3.1.0','dist':{'tarball':'https://registry.npmjs.org/create-tauri-app/-/create-tauri-app-3.1.0.tgz','integrity':integrity}}}}
        self.engine.fetch=lambda _,p:Path(p).write_bytes(payload)
        def cargo_metadata(): return {'resolve':{'root':'app','nodes':[{'id':'app','deps':[{'name':'tauri','pkg':'tauri'}]}]},'packages':[{'id':'tauri','name':'tauri','version':'2.5.0'}]}
        def runner(args,cwd=None,**kwargs):
            calls.append(args); cwd=Path(cwd); output=''
            if args[0]=='npm' and 'exec' in args:
                if '--help' in args: output='--tauri-version [1 | 2] --template vanilla-ts --manager --identifier --yes'
                else:
                    files={'package.json':json.dumps({'name':'generated','version':'0.1.0','scripts':{},'devDependencies':{}}),'tsconfig.json':'{}','vite.config.ts':'port: 1420, strictPort: true, "**/src-tauri/**"','index.html':'<html/>','src/main.ts':'starter','src/styles.css':'starter','src-tauri/Cargo.toml':'[package]\nname = "generated"\nversion = "0.1.0"\n[lib]\nname = "generated_lib"\n[dependencies]\ntauri = { version = "2", features = [] }\n','src-tauri/tauri.conf.json':json.dumps({'build':{'frontendDist':'../dist'},'app':{'windows':[{'title':'Generated'}]},'bundle':{'icon':['icons/32x32.png']}}),'src-tauri/src/main.rs':'fn main() { generated_lib::run() }','src-tauri/src/lib.rs':'pub fn run() {}','src-tauri/build.rs':'fn main() {}','src-tauri/capabilities/default.json':'{}','src-tauri/icons/32x32.png':b'fixture icon binary\x00\xff','.gitignore':'node_modules/\n'}
                    for name,data in files.items():
                        p=cwd/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(data.encode() if isinstance(data,str) else data)
            elif args[0]=='npm' and 'install' in args:
                package=b.read_json(cwd/'package.json'); (cwd/'package-lock.json').write_text(json.dumps({'lockfileVersion':3,'packages':{'':{k:package[k] for k in ('name','version','devDependencies')},'node_modules/vitest':{'version':'3.2.1'},'node_modules/jsdom':{'version':'26.1.0'}}}))
            elif args[0]=='npm' and 'ci' in args: (cwd/'node_modules').mkdir(exist_ok=True)
            elif args[0]=='cargo' and 'generate-lockfile' in args: (cwd/'src-tauri/Cargo.lock').write_text('version = 4\n')
            elif args[0]=='cargo' and 'metadata' in args: output=json.dumps(cargo_metadata())
            return subprocess.CompletedProcess(args,0,output)
        self.engine.runner=runner; selected=b.selection(self.id,'tauri'); journal=self.engine.new_journal(self.id,selected); self.engine.save(journal)
        source,manifest=self.engine.prepare(journal)
        self.assertEqual(b.read_json(source/'src-tauri/tauri.conf.json')['identifier'],'com.cicely-f.starter-project')
        self.assertIn('tauri = { version = "^2.5.0"',(source/'src-tauri/Cargo.toml').read_text())
        self.assertIn('starter_project_lib::run()',(source/'src-tauri/src/main.rs').read_text())
        self.assertEqual(b.read_json(source/'package.json')['devDependencies']['vitest'],'^3.2.1')
        self.assertEqual((source/'src-tauri/icons/32x32.png').read_bytes(),b'fixture icon binary\x00\xff')
        self.assertTrue(any(e['path']=='src-tauri/Cargo.lock' for e in manifest))
        self.engine.freeze(journal,source,manifest); self.engine.snapshot(journal)
        count=len(calls); self.engine.prepare(journal); self.assertEqual(len(calls),count)
    def test_lock_refuses_parallel_invocation(self):
        path=self.root/'state/test.json'
        with b.lock(path):
            with self.assertRaisesRegex(ValueError,'locked'):
                with b.lock(path): pass
    def test_acquired_artifact_digest_failure_preserves_evidence(self):
        path=self.root/'cache/item'; artifact={'name':'item','uri':'https://fixture.invalid/item','sha256':'0'*64}
        with self.assertRaisesRegex(ValueError,'digest mismatch'): b.acquire(artifact,path,lambda _,p:Path(p).write_bytes(b'bad'))
        self.assertFalse(path.exists()); self.assertEqual(len(list(path.parent.glob('*.partial'))),1)
if __name__=='__main__': unittest.main()
