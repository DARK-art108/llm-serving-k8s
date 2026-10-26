"""Exercise installer decisions with fake CLIs. These tests never use a cluster."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'kserve' / 'install-platform.sh'

FAKE_TOOL = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['LAB_TEST_LOG'], 'a') as log:
    log.write(json.dumps([name] + args) + '\\n')
if name == 'yq':
    if args == ['--version']:
        print('yq (https://github.com/mikefarah/yq/) version v4.52.1' if os.environ.get('LAB_TEST_YQ') != 'wrong' else 'yq 3.0 (Python)')
    else:
        print(sys.stdin.read())
elif name == 'kubectl':
    if args == ['config', 'current-context']:
        print('fake-learning-cluster')
    elif args[:2] == ['get', 'namespace']:
        sys.exit(0 if args[2] == os.environ.get('LAB_TEST_NAMESPACE') else 1)
    elif args[:2] == ['get', 'crd']:
        sys.exit(0 if args[2] == os.environ.get('LAB_TEST_CRD') else 1)
elif name == 'helm':
    if args[:2] == ['show', 'crds']:
        print('apiVersion: apiextensions.k8s.io/v1\\nkind: CustomResourceDefinition\\nspec:\\n  group: gateway.envoyproxy.io')
    if os.environ.get('LAB_TEST_FAIL_AI') == 'yes' and 'oci://docker.io/envoyproxy/ai-gateway-helm' in args:
        sys.exit(9)
'''


class PlatformInstallerTests(unittest.TestCase):
    def run_installer(self, **options):
        with tempfile.TemporaryDirectory() as folder:
            temp = Path(folder)
            for name in ('kubectl', 'helm', 'yq'):
                tool = temp / name
                tool.write_text(FAKE_TOOL)
                tool.chmod(0o755)
            log = temp / 'commands.jsonl'
            environment = {**os.environ, **options, 'PATH': str(temp) + os.pathsep + os.environ['PATH'], 'LAB_TEST_LOG': str(log)}
            result = subprocess.run(['bash', str(INSTALLER)], cwd=ROOT, env=environment, capture_output=True, text=True, timeout=20)
            calls = [__import__('json').loads(line) for line in log.read_text().splitlines()]
            return result, calls

    def assert_no_mutations(self, calls):
        for tool, *args in calls:
            if tool == 'helm':
                self.assertNotIn('upgrade', args)
            if tool == 'kubectl':
                self.assertNotIn(args[0], ('apply', 'delete', 'patch', 'rollout'))

    def test_wrong_yq_stops_before_cluster_access(self):
        result, calls = self.run_installer(LAB_TEST_YQ='wrong')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Mike Farah', result.stderr)
        self.assertFalse(any(call[0] == 'kubectl' for call in calls))
        self.assert_no_mutations(calls)

    def test_existing_platform_is_not_changed(self):
        result, calls = self.run_installer(LAB_TEST_NAMESPACE='kserve')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already exists', result.stderr)
        self.assert_no_mutations(calls)

    def test_existing_inference_crds_are_not_adopted(self):
        result, calls = self.run_installer(LAB_TEST_CRD='inferencepools.inference.networking.k8s.io')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already exists', result.stderr)
        self.assert_no_mutations(calls)

    def test_failed_dependency_stops_later_installation(self):
        result, calls = self.run_installer(LAB_TEST_FAIL_AI='yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('oci://ghcr.io/kserve/charts/kserve-llmisvc-resources' in call for call in calls))
        self.assertNotIn('Platform installed.', result.stdout)

    def test_successful_plan_has_webhook_and_api_order(self):
        result, calls = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        inference_api = next(i for i, call in enumerate(calls) if any('v1-manifests.yaml' in arg for arg in call))
        gateway_install = next(i for i, call in enumerate(calls) if 'upgrade' in call and 'eg' in call)
        webhook_wait = next(i for i, call in enumerate(calls) if 'endpoints/llmisvc-webhook-server-service' in call)
        runtimes = next(i for i, call in enumerate(calls) if 'oci://ghcr.io/kserve/charts/kserve-runtime-configs' in call)
        self.assertLess(inference_api, gateway_install)
        self.assertLess(webhook_wait, runtimes)
        self.assertTrue(any('kserve.llmisvc.createGIECRDs=false' in call for call in calls))
        self.assertTrue(any(str(ROOT / 'kserve/platform/gateway.yaml') in call for call in calls))
        self.assertFalse(any('--force-conflicts' in call or 'uninstall' in call for call in calls))


if __name__ == '__main__':
    unittest.main()
