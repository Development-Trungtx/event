"""Regression tests for failure paths; no real Kubernetes, credentials, Docker, or app required."""
import http.server
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import threading
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FAKE = r'''#!/usr/bin/env python3
import json,os,pathlib,sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['FAKE_CALLS'],'a') as f: f.write(json.dumps([name,*args])+'\n')
state=json.load(open(os.environ['FAKE_STATE']))
if name=='helm':
    verb=args[0]
    if verb=='version': print('v3.22.1')
    elif verb=='list': print(json.dumps([] if state.get('absent') else [{'status':state.get('status','deployed')}]))
    elif verb=='history': print(json.dumps(state.get('history',[{'revision':1,'status':'deployed'}])))
    elif verb=='status': print(json.dumps({'version':3}))
    elif verb in ('upgrade','rollback'): sys.exit(state.get(verb+'_rc',0))
    else: sys.exit('Unexpected Helm command: '+repr(args))
elif name=='kubectl':
    if args[:2]==['config','current-context']: print(state.get('context','test-context'))
    elif 'can-i' in args: print('yes')
    elif 'get' in args: print('')
    else: sys.exit('Unexpected kubectl command: '+repr(args))
'''

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(503 if self.path=='/fail' else 200)
        self.send_header('Content-Type','application/json')
        self.end_headers()
        self.wfile.write(b'{"status":"UP"}')
    def log_message(self,*args):
        pass

class DeliveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        cls.thread=threading.Thread(target=cls.http.serve_forever,daemon=True)
        cls.thread.start()
    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown();cls.http.server_close();cls.thread.join()
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='cicd-test-',dir=os.environ.get('RUNNER_TEMP',str(ROOT.parent)));self.addCleanup(self.tmp.cleanup)
        self.work=pathlib.Path(self.tmp.name);binpath=self.work/'bin';binpath.mkdir()
        for name in ('helm','kubectl'):
            p=binpath/name;p.write_text(FAKE);p.chmod(0o755)
        self.state=self.work/'state.json';self.state.write_text('{}')
        self.calls=self.work/'calls';self.calls.touch()
        self.bundle=self.work/'bundle';self.bundle.mkdir()
        shutil.copytree(ROOT/'helm/order-service',self.bundle/'chart')
        self.meta={'repository':'example/order-service','source_sha':'a'*40,'source_ref':'refs/heads/dev','image_repository':'ghcr.io/example/order-service','image_digest':'sha256:'+'b'*64}
        self.write_meta()
        self.env=dict(os.environ,TMPDIR=str(self.work),PATH=str(binpath)+os.pathsep+os.environ['PATH'],FAKE_CALLS=str(self.calls),FAKE_STATE=str(self.state),NAMESPACE='order-dev',RELEASE_NAME='order-service-dev',EXPECTED_KUBE_CONTEXT='test-context',TARGET_ENVIRONMENT='dev',BUNDLE_DIR=str(self.bundle),DIAGNOSTICS_DIR=str(self.work/'diagnostics'),SMOKE_URL=f'http://127.0.0.1:{self.http.server_port}/ready',SMOKE_ATTEMPTS='1',SMOKE_RETRY_SECONDS='0',GITHUB_STEP_SUMMARY=str(self.work/'summary'))
    def write_meta(self):
        (self.bundle/'release.json').write_text(json.dumps(self.meta))
    def configure(self,**state): self.state.write_text(json.dumps(state))
    def run_script(self,name,*args):
        return subprocess.run(['bash',str(ROOT/'scripts'/name),*args],env=self.env,text=True,capture_output=True,timeout=15)
    def mutations(self):
        calls=[json.loads(line) for line in self.calls.read_text().splitlines()]
        return [c[1] for c in calls if c[0]=='helm' and c[1] in ('upgrade','rollback','uninstall')]
    def test_success_no_rollback(self):
        result=self.run_script('deploy.sh')
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(self.mutations(),['upgrade'])
        self.assertIn('SUCCESS',(self.work/'summary').read_text())
    def test_upgrade_failure_recovers_but_run_stays_failed(self):
        self.configure(upgrade_rc=1)
        result=self.run_script('deploy.sh')
        self.assertNotEqual(result.returncode,0);self.assertEqual(self.mutations(),['upgrade','rollback'])
        self.assertIn('restored and smoke test passed',(self.work/'summary').read_text())
    def test_first_install_failure_never_uninstalls(self):
        self.configure(absent=True,upgrade_rc=1)
        result=self.run_script('deploy.sh')
        self.assertNotEqual(result.returncode,0);self.assertEqual(self.mutations(),['upgrade'])
        self.assertIn('resources preserved',(self.work/'summary').read_text())
    def test_smoke_failure_triggers_rollback(self):
        self.env['SMOKE_URL']=self.env['SMOKE_URL'].replace('/ready','/fail')
        result=self.run_script('deploy.sh')
        self.assertNotEqual(result.returncode,0);self.assertEqual(self.mutations(),['upgrade','rollback'])
        self.assertIn('recovery also failed',(self.work/'summary').read_text())
    def test_wrong_context_cannot_mutate(self):
        self.configure(context='wrong-cluster')
        result=self.run_script('deploy.sh')
        self.assertNotEqual(result.returncode,0);self.assertEqual(self.mutations(),[])
    def test_pending_release_is_not_overwritten(self):
        self.configure(status='pending-upgrade')
        result=self.run_script('deploy.sh')
        self.assertNotEqual(result.returncode,0);self.assertEqual(self.mutations(),[])
    def test_invalid_digest_cannot_mutate(self):
        self.meta['image_digest']='sha256:'+'0'*64;self.write_meta()
        result=self.run_script('deploy.sh')
        self.assertNotEqual(result.returncode,0);self.assertEqual(self.mutations(),[])
    def test_environment_ref_mismatch_cannot_mutate(self):
        self.env['TARGET_ENVIRONMENT']='production'
        result=self.run_script('deploy.sh')
        self.assertNotEqual(result.returncode,0);self.assertEqual(self.mutations(),[])
    def test_manual_rollback_rejects_failed_revision(self):
        self.configure(history=[{'revision':1,'status':'failed'}])
        result=self.run_script('rollback.sh','1')
        self.assertNotEqual(result.returncode,0);self.assertEqual(self.mutations(),[])
    def test_manual_rollback_accepts_successful_revision(self):
        result=self.run_script('rollback.sh','1')
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(self.mutations(),['rollback'])
    def test_failed_cluster_query_is_not_treated_as_first_install(self):
        # A transport failure must abort before any Helm upgrade.
        wrapper=self.work/'bin/helm'
        wrapper.write_text(FAKE.replace("elif verb=='list':", "elif verb=='list': sys.exit(1)\n    elif verb=='unused':"))
        result=self.run_script('deploy.sh')
        self.assertNotEqual(result.returncode,0);self.assertEqual(self.mutations(),[])

class CandidateTests(unittest.TestCase):
    def test_obsolete_candidate_is_skipped_without_failure(self):
        class API(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200);self.end_headers();self.wfile.write(json.dumps({'object':{'sha':'c'*40}}).encode())
            def log_message(self,*args): pass
        with tempfile.TemporaryDirectory(prefix='cicd-test-',dir=os.environ.get('RUNNER_TEMP',str(ROOT.parent))) as tmp:
            root=pathlib.Path(tmp)
            (root/'release.json').write_text(json.dumps({'repository':'example/order-service','source_sha':'a'*40,'source_ref':'refs/heads/dev','image_repository':'ghcr.io/example/order-service','image_digest':'sha256:'+'b'*64}))
            api=http.server.ThreadingHTTPServer(('127.0.0.1',0),API)
            t=threading.Thread(target=api.serve_forever,daemon=True);t.start()
            try:
                env=dict(os.environ,BUNDLE_DIR=tmp,EXPECTED_SOURCE_SHA='a'*40,GITHUB_REPOSITORY='example/order-service',GITHUB_REF='refs/heads/dev',TARGET_ENVIRONMENT='dev',GITHUB_OUTPUT=str(root/'output'),GH_TOKEN='test-placeholder',GITHUB_API_URL=f'http://127.0.0.1:{api.server_port}')
                result=subprocess.run(['python3',str(ROOT/'scripts/check-candidate.py')],env=env,text=True,capture_output=True,timeout=10)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual((root/'output').read_text(),'deploy=false\n')
            finally: api.shutdown();api.server_close();t.join()

class ChartTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('helm'),'Helm is needed for render tests')
    def test_invalid_digest_rejected_by_schema(self):
        result=subprocess.run(['helm','template','test',str(ROOT/'helm/order-service'),'--set-string','image.digest=latest'],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
    @unittest.skipUnless(shutil.which('helm'),'Helm is needed for render tests')
    def test_optional_resources_render(self):
        result=subprocess.run(['helm','template','test',str(ROOT/'helm/order-service'),'-f',str(ROOT/'helm/order-service/values-prod.yaml'),'--set','ingress.enabled=true','--set','networkPolicy.enabled=true'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        for kind in ('Ingress','NetworkPolicy','PodDisruptionBudget'):
            self.assertIn('kind: '+kind,result.stdout)
        self.assertIn('automountServiceAccountToken: false',result.stdout)


class ReleaseBundleTests(unittest.TestCase):
    def test_pushed_digest_and_bundle_checksums(self):
        import hashlib
        with tempfile.TemporaryDirectory(prefix='cicd-bundle-',dir=os.environ.get('RUNNER_TEMP',str(ROOT.parent))) as tmp:
            p=pathlib.Path(tmp);inspection=p/'image.json'
            digest='sha256:'+'b'*64
            inspection.write_text(json.dumps([{'RepoDigests':['ghcr.io/example/order-service@'+digest]}]))
            env=dict(os.environ,GITHUB_REPOSITORY='example/order-service',GITHUB_SHA='a'*40,GITHUB_REF='refs/heads/dev',GITHUB_RUN_ID='123',GITHUB_RUN_ATTEMPT='1')
            result=subprocess.run(['python3','scripts/create-release-bundle.py',str(inspection),'ghcr.io/example/order-service',str(p/'bundle')],cwd=ROOT,env=env,text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            bundle=p/'bundle';meta=json.loads((bundle/'release.json').read_text())
            self.assertEqual(meta['image_digest'],digest)
            self.assertTrue((bundle/'chart/Chart.yaml').is_file())
            self.assertTrue((bundle/'scripts/deploy.sh').is_file())
            self.assertFalse((bundle/'scripts/tests').exists())
            for line in (bundle/'SHA256SUMS').read_text().splitlines():
                expected,name=line.split('  ',1)
                self.assertEqual(hashlib.sha256((bundle/name).read_bytes()).hexdigest(),expected)
    def test_unrelated_registry_digest_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='cicd-bundle-',dir=os.environ.get('RUNNER_TEMP',str(ROOT.parent))) as tmp:
            p=pathlib.Path(tmp);inspection=p/'image.json'
            inspection.write_text(json.dumps([{'RepoDigests':['ghcr.io/other/app@sha256:'+'b'*64]}]))
            result=subprocess.run(['python3','scripts/create-release-bundle.py',str(inspection),'ghcr.io/example/order-service',str(p/'bundle')],cwd=ROOT,text=True,capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse((p/'bundle').exists())

if __name__=='__main__': unittest.main()
