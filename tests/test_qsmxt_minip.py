"""minIP upload-guard tests; run inside the QSMxT image."""
import importlib.util
import json
from pathlib import Path
import shlex
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = shlex.split(json.loads((ROOT / 'container-service/commands/qsmxt-session.json').read_text())['command-line'])[2]
GUARD = SCRIPT.split("<<'PYMINIP'\n", 1)[1].split('\nPYMINIP\n', 1)[0]
AVAILABLE = importlib.util.find_spec('nibabel') is not None and importlib.util.find_spec('numpy') is not None
if AVAILABLE:
    import nibabel as nib
    import numpy as np
    namespace = {'__name__': 'minip_guard'}
    exec(compile(GUARD, '<minip-guard>', 'exec'), namespace)
    check_derivatives = namespace['check_derivatives']


@unittest.skipUnless(AVAILABLE, 'Run numerical tests inside the QSMxT image (nibabel/numpy)')
class MinipGuardTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.anat = self.root / 'sub-01/anat'
        self.anat.mkdir(parents=True)
        nib.save(nib.Nifti1Image(np.ones((4, 4, 14), dtype='float32'), np.eye(4)), self.anat / 'sub-01_swi.nii')

    def write_minip(self, depth, name='sub-01_minIP', xy=(4, 4)):
        path = self.anat / f'{name}.nii'
        nib.save(nib.Nifti1Image(np.ones((*xy, depth), dtype='float32'), np.eye(4)), path)
        (self.anat / f'{name}.json').write_text('{"SeriesNumber": 7}')
        return path

    def test_valid_projection_is_kept(self):
        minip = self.write_minip(8)
        self.assertEqual(check_derivatives(self.root), 0)
        self.assertTrue(minip.exists())

    def test_mismatched_grid_is_removed_with_sidecar(self):
        minip = self.write_minip(8, xy=(4, 5))
        self.assertEqual(check_derivatives(self.root), 1)
        self.assertFalse(minip.exists())
        self.assertFalse((self.anat / 'sub-01_minIP.json').exists())

    def test_smwi_minips_are_checked_against_smwi(self):
        # SMWI projects with its own (smaller) window; there is no desc-*_swi.
        for kind in ('paramagnetic', 'diamagnetic'):
            nib.save(nib.Nifti1Image(np.ones((4, 4, 14), dtype='float32'), np.eye(4)), self.anat / f'sub-01_desc-{kind}_smwi.nii')
        good = self.write_minip(11, name='sub-01_desc-paramagnetic_minIP')
        bad = self.write_minip(11, name='sub-01_desc-diamagnetic_minIP', xy=(5, 4))
        self.assertEqual(check_derivatives(self.root), 1)
        self.assertTrue(good.exists())
        self.assertFalse(bad.exists())

    def test_truncated_payload_is_removed(self):
        # QSMxT#211: header promises the SWI depth, payload holds nz-6 slices.
        minip = self.write_minip(8)
        header = nib.load(minip).header.copy()
        header.set_data_shape((4, 4, 14))
        minip.write_bytes(header.binaryblock + b'\0' * 4 + minip.read_bytes()[352:])
        self.assertEqual(check_derivatives(self.root), 1)
        self.assertFalse(minip.exists())

    def test_short_acquisition_accepts_single_projection(self):
        nib.save(nib.Nifti1Image(np.ones((4, 4, 3), dtype='float32'), np.eye(4)), self.anat / 'sub-01_swi.nii')
        minip = self.write_minip(1)
        self.assertEqual(check_derivatives(self.root), 0)
        self.assertTrue(minip.exists())


if __name__ == '__main__':
    unittest.main()
