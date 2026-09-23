"""Run with python3 -m unittest discover -s tests -p 'test_qsmxt*.py'."""
import json
import os
import re
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMMAND = json.loads((ROOT / 'container-service/commands/qsmxt-session.json').read_text())
SCRIPT = shlex.split(COMMAND['command-line'])[2]
# The numerical minIP stage is covered separately with real NIfTI fixtures.
start = SCRIPT.index("python3 - /work/bids/derivatives/qsmxt <<'PYMINIP'\n")
end = SCRIPT.index('\nPYMINIP\n', start) + len('\nPYMINIP\n')
SCRIPT = SCRIPT[:start] + SCRIPT[end:]


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = os.environ.copy()
        for inp in COMMAND['inputs']:
            value = str(inp['default-value']).lower() if isinstance(inp['default-value'], bool) else inp['default-value']
            for key, replacement in COMMAND['environment-variables'].items():
                if replacement == inp['replacement-key']:
                    self.env[key] = value
        self.env['TEST_ROOT'] = str(self.root)
        fake = self.root / 'qsmxt'
        fake.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['TEST_ROOT'])
bids = root / 'work/bids'
if sys.argv[1] == 'dicom-convert':
    anat = bids / 'sub-01/anat'; anat.mkdir(parents=True, exist_ok=True)
    (anat / 'sub-01_part-phase_MEGRE.nii').touch()
    (anat / 'sub-01_part-phase_MEGRE.json').write_text(json.dumps({'SeriesNumber':7}))
    sys.exit(int(os.environ.get('CONVERT_EXIT', '0')))
(root / 'args.json').write_text(json.dumps(sys.argv[2:]))
anat = bids / 'derivatives/qsmxt/sub-01/anat'; anat.mkdir(parents=True)
outputs = ['Chimap', 'part-mag_T2starw']
if '--do-swi' in sys.argv: outputs += ['swi', 'minIP']
if '--do-smwi' in sys.argv:
    outputs += ['desc-%s_%s' % (kind, suffix) for kind in ('paramagnetic', 'diamagnetic') for suffix in ('smwi', 'minIP')]
if '--do-r2primemap' in sys.argv: outputs += ['R2primemap']
if '--do-segmentation' in sys.argv or '--do-analysis' in sys.argv: outputs += ['dseg']
if '--do-analysis' in sys.argv: (anat / 'sub-01_desc-segmentation_qsmstats.tsv').write_text('index')
if '--two-pass' in sys.argv: outputs += ['desc-singlepass_Chimap']
work = bids / 'derivatives/qsmxt/workflow/sub-01/unwrap'; work.mkdir(parents=True)
(work / 'provenance.json').write_text('{}'); (work / 'sub-01_field-ppm.nii').touch()
if ('--do-t2starmap' in sys.argv or '--do-r2starmap' in sys.argv) and not os.environ.get('SINGLE_ECHO'):
    outputs += ['T2starmap', 'R2starmap']
for suffix in outputs:
    (anat / ('sub-01_' + suffix + '.nii.gz')).touch()
''')
        fake.chmod(0o755)
        # Rewrite only absolute container paths, not e.g. derivatives/qsmxt/workflow.
        self.script = re.sub(r'(?<![\w/])/(work|output)\b', lambda m: str(self.root / m.group(1)), SCRIPT)
        self.script = self.script.replace('qsmxt dicom-convert', shlex.quote(str(fake)) + ' dicom-convert').replace('qsmxt run', shlex.quote(str(fake)) + ' run')

    def run_command(self, **env):
        result = subprocess.run(['bash', '-c', self.script], env={**self.env, **env}, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads((self.root / 'args.json').read_text()), result

    def test_default_maps_and_source_metadata(self):
        args, _ = self.run_command(CONVERT_EXIT='1')
        for flag in ['--do-swi', '--do-t2starmap', '--do-r2starmap', '--do-smwi']:
            self.assertIn(flag, args)
        for flag in ['--do-r2primemap', '--two-pass', '--do-segmentation', '--do-analysis', '--clean-intermediates']:
            self.assertNotIn(flag, args)
        self.assertEqual(args[args.index('--masking-input') + 1], 'magnitude')
        self.assertEqual(args[args.index('--qsm-algorithm') + 1], 'hdqsm')
        for suffix in ['Chimap', 'swi', 'minIP', 'T2starmap', 'R2starmap']:
            meta = self.root / f'output/qsmxt/sub-01/anat/sub-01_{suffix}.json'
            self.assertEqual(json.loads(meta.read_text())['SeriesNumber'], 7)

    def test_custom_controls_and_disabled_maps(self):
        args, _ = self.run_command(QSMXT_ALGORITHM='tikhonov', QSMXT_UNWRAPPING='laplacian', QSMXT_BACKGROUND='resharp', QSMXT_DO_SWI='false', QSMXT_DO_T2STAR='false', QSMXT_DO_R2STAR='false', QSMXT_DO_SMWI='false')
        self.assertEqual(args[args.index('--qsm-algorithm') + 1], 'tikhonov')
        self.assertEqual(args[args.index('--unwrapping-algorithm') + 1], 'laplacian')
        self.assertEqual(args[args.index('--bf-algorithm') + 1], 'resharp')
        self.assertFalse(any(a.startswith('--do-') for a in args))

    def test_new_922_features(self):
        args, result = self.run_command(QSMXT_DO_R2PRIME='true', QSMXT_R2PRIME_STRATEGY='r2primenet', QSMXT_TWO_PASS='true',
                                        QSMXT_DO_ANALYSIS='true', QSMXT_ALGORITHM='heidi', QSMXT_MASK_PRESET='bet-and-phase')
        self.assertEqual(args[args.index('--r2prime-strategy') + 1], 'r2primenet')
        for flag in ['--do-r2primemap', '--two-pass', '--do-analysis']:
            self.assertIn(flag, args)
        self.assertEqual(args[args.index('--qsm-algorithm') + 1], 'heidi')
        self.assertEqual(args[args.index('--mask-preset') + 1], 'bet-and-phase')
        self.assertNotIn('--masking-input', args)  # would force one input onto both mask sections
        self.assertNotIn('was not produced', result.stderr)
        anat = self.root / 'output/qsmxt/sub-01/anat'
        for suffix in ['R2primemap', 'desc-paramagnetic_smwi', 'desc-diamagnetic_minIP', 'dseg', 'desc-singlepass_Chimap']:
            self.assertEqual(json.loads((anat / f'sub-01_{suffix}.json').read_text())['SeriesNumber'], 7)
        self.assertTrue((anat / 'sub-01_desc-segmentation_qsmstats.tsv').exists())
        workflow = self.root / 'output/qsmxt/workflow/sub-01/unwrap'
        self.assertEqual({p.name for p in workflow.iterdir()}, {'provenance.json'})

    def test_invalid_r2prime_strategy_rejected(self):
        result = subprocess.run(['bash', '-c', self.script], env={**self.env, 'QSMXT_R2PRIME_STRATEGY': 'guess'}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('Invalid r2prime-strategy', result.stderr)

    def test_preset_overrides_custom(self):
        args, _ = self.run_command(QSMXT_PREMADE='romeo-resharp-rts', QSMXT_ALGORITHM='tv')
        self.assertEqual(args[args.index('--qsm-algorithm') + 1], 'rts')
        self.assertEqual(args[args.index('--bf-algorithm') + 1], 'resharp')
        self.assertEqual(args.count('--qsm-algorithm'), 1)

    def test_full_pipeline_omits_external_stages(self):
        args, _ = self.run_command(QSMXT_PREMADE='iqsm-plus')
        self.assertNotIn('--unwrapping-algorithm', args)
        self.assertNotIn('--bf-algorithm', args)

    def test_legacy_preset(self):
        args, _ = self.run_command(QSMXT_PREMADE='epi')
        self.assertIn('--inhomogeneity-correction', args)
        self.assertEqual(args[args.index('--mask-preset') + 1], 'robust-threshold')

    def test_unavailable_maps_are_reported(self):
        _, result = self.run_command(SINGLE_ECHO='1')
        self.assertIn('requested T2starmap was not produced', result.stderr)
        self.assertIn('requested R2starmap was not produced', result.stderr)

    def test_invalid_input_rejected_before_conversion(self):
        result = subprocess.run(['bash', '-c', self.script], env={**self.env, 'QSMXT_ALGORITHM':'rts; touch /tmp/bad'}, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / 'work').exists())


if __name__ == '__main__':
    unittest.main()
