#!/usr/bin/env python3
"""Exercise the fixed SSM wrapper against an isolated fake host, never AWS."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'modules/frontend-test/deploy-command.sh'
OLD = 'a' * 40
NEW = 'b' * 40
MOCK = r"""
import json, os, pathlib, sys
root = pathlib.Path(os.environ['MOCK_HOST'])
state_path = root / 'state.json'
state = json.loads(state_path.read_text())
def save():
    state_path.write_text(json.dumps(state))
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'python3':
    sys.stdin.read()
    revision = args[-1]
    ok = state['running'] and not state['root'] and state['tag'] == 'wes-frontend:' + revision
    sys.exit(0 if ok else 1)
if name == 'deploy-frontend':
    state['helperCalls'] += 1
    if state['scenario'] == 'helper_rollback':
        save(); sys.exit(42)
    if state['scenario'] in ('operator_active', 'operator_finished'):
        state.update(running=True, tag='wes-frontend:' + 'd' * 40, image='sha256:operator')
        save(); sys.exit(42)
    if state['scenario'] == 'start_failure':
        state['running'] = False
        save(); sys.exit(42)
    state.update(running=True, tag='wes-frontend:' + args[-1], image='sha256:new', root=state['scenario']=='root_policy')
    save(); sys.exit(0)
if name == 'flock':
    sys.exit(1 if state['scenario'] == 'wrapper_busy' or (state['scenario'] == 'operator_active' and args[-1] == '9') else 0)
if name == 'docker':
    if args[0] == 'inspect':
        if not state['running']:
            sys.exit(1)
        print(state['tag'] if args[2] == '{{.Config.Image}}' else state['image'])
    elif args[:2] == ['image', 'inspect']:
        print('sha256:new')
    elif args[:2] == ['image', 'tag']:
        state['retaggedImage'] = args[2]
        save()
    elif args[0] == 'rm':
        if args[-1] == 'wes-frontend':
            state['running'] = False
            save()
    elif args[0] == 'run':
        for required in ('--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--memory', '768m', '--pids-limit', '256', '127.0.0.1:3000:3000'):
            assert required in args, required
        assert state['retaggedImage'] == 'sha256:old'
        state.update(running=True, tag=args[-1], image='sha256:old', root=False)
        state['restoreRuns'] += 1
        save()
    else:
        raise AssertionError(args)
else:
    raise AssertionError(name)
"""

class DeploymentRollbackTest(unittest.TestCase):
    def run_scenario(self, scenario):
        with tempfile.TemporaryDirectory(prefix='wes-frontend-rollback-test-') as directory:
            root = Path(directory)
            (root / 'bin').mkdir()
            initial = dict(running=True, tag='wes-frontend:' + OLD, image='sha256:old', root=False, scenario=scenario, helperCalls=0, restoreRuns=0)
            if scenario == 'unsafe_prior':
                initial['root'] = True
            (root / 'state.json').write_text(json.dumps(initial))
            (root / 'current-revision').write_text(OLD + '\n')
            (root / 'previous-image').write_text('wes-frontend:' + 'c' * 40 + '\n')
            for name in ('docker', 'python3', 'deploy-frontend', 'flock'):
                target = root / 'bin' / name
                target.write_text('#!' + sys.executable + '\n' + MOCK)
                target.chmod(0o755)
            wrapper = SOURCE.read_text().replace('/usr/local/bin/deploy-frontend', str(root / 'bin/deploy-frontend')).replace('/opt/wes-frontend/', str(root) + '/').replace('/var/lock/', str(root) + '/')
            target = root / 'wrapper.sh'
            target.write_text(wrapper)
            env = dict(os.environ, PATH=str(root / 'bin') + ':' + os.environ['PATH'], MOCK_HOST=str(root), SSM_ArtifactKey='releases/' + NEW + '.tar.gz', SSM_ArtifactSha256='c' * 64, SSM_Revision=NEW)
            result = subprocess.run(['bash', str(target)], env=env, text=True, capture_output=True, timeout=10)
            state = json.loads((root / 'state.json').read_text())
            return result, state, (root / 'current-revision').read_text().strip()

    def assert_restored(self, scenario):
        result, state, revision = self.run_scenario(scenario)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(state['tag'], 'wes-frontend:' + OLD)
        self.assertEqual(state['image'], 'sha256:old')
        self.assertTrue(state['running'])
        self.assertFalse(state['root'])
        self.assertEqual(state['restoreRuns'], 1)
        self.assertEqual(revision, OLD)

    def test_runtime_root_policy_failure_restores_previous_image(self):
        self.assert_restored('root_policy')

    def test_new_container_start_failure_restores_previous_image(self):
        self.assert_restored('start_failure')

    def test_existing_helper_rollback_is_preserved(self):
        result, state, _ = self.run_scenario('helper_rollback')
        self.assertEqual(result.returncode, 42)
        self.assertTrue(state['running'])
        self.assertEqual(state['image'], 'sha256:old')
        self.assertEqual(state['restoreRuns'], 0)

    def test_healthy_release_needs_no_rollback(self):
        result, state, _ = self.run_scenario('success')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(state['tag'], 'wes-frontend:' + NEW)
        self.assertEqual(state['restoreRuns'], 0)

    def test_ongoing_ssm_wrapper_blocks_new_deployment(self):
        result, state, _ = self.run_scenario('wrapper_busy')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state['helperCalls'], 0)
        self.assertEqual(state['restoreRuns'], 0)

    def test_manual_deployment_in_progress_is_never_rolled_back(self):
        result, state, _ = self.run_scenario('operator_active')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state['image'], 'sha256:operator')
        self.assertEqual(state['restoreRuns'], 0)

    def test_different_completed_release_is_never_rolled_back(self):
        result, state, _ = self.run_scenario('operator_finished')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state['image'], 'sha256:operator')
        self.assertEqual(state['restoreRuns'], 0)

    def test_unsafe_prior_runtime_aborts_before_deployment(self):
        result, state, _ = self.run_scenario('unsafe_prior')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state['helperCalls'], 0)
        self.assertEqual(state['restoreRuns'], 0)

if __name__ == '__main__':
    unittest.main()
