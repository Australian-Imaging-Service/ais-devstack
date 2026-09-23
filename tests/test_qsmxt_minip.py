"""Numerical minIP regression tests; run inside the QSMxT image."""
import importlib.util
import json
from pathlib import Path
import shlex
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = shlex.split(json.loads((ROOT / 'container-service/commands/qsmxt-session.json').read_text())['command-line'])[2]
FIX = SCRIPT.split("<<'PYMINIP'\n", 1)[1].split('\nPYMINIP\n', 1)[0]
AVAILABLE = importlib.util.find_spec('nibabel') is not None and importlib.util.find_spec('numpy') is not None
if AVAILABLE:
    import nibabel as nib
    import numpy as np
    namespace = {'__name__': 'minip_fix'}
    exec(compile(FIX, '<minip-fix>', 'exec'), namespace)
    write_minip = namespace['write_minip']
    repair_derivatives = namespace['repair_derivatives']


@unittest.skipUnless(AVAILABLE, 'Run numerical tests inside the QSMxT image (nibabel/numpy)')
class MinipTests(unittest.TestCase):
    def test_projection_shape_values_and_oblique_geometry(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp)/'swi.nii', Path(tmp)/'minIP.nii'
            data = np.random.default_rng(12).uniform(1, 100, (5, 6, 14)).astype('float32')
            affine = np.array([[1,0,0.5,10],[0,2,0,-2],[0,0,2,3],[0,0,0,1.]])
            nib.save(nib.Nifti1Image(data, affine), source)
            write_minip(source, output)
            result = nib.load(output)
            self.assertEqual(result.shape, (5,6,8))
            expected = np.stack([data[:,:,k:k+7].min(axis=2) for k in range(8)], axis=2)
            np.testing.assert_array_equal(result.get_fdata(), expected)
            np.testing.assert_allclose(result.affine[:3,3], (affine @ [0,0,3,1])[:3])
            self.assertEqual(output.stat().st_size, 352 + expected.size * 4)

    def test_short_acquisition_and_zero_minimum(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp)/'swi.nii.gz', Path(tmp)/'minIP.nii.gz'
            data = np.ones((4,4,3), dtype='float32'); data[1,1,1] = 0
            nib.save(nib.Nifti1Image(data, np.eye(4)), source)
            self.assertEqual(write_minip(source, output), 3)
            result=nib.load(output)
            self.assertEqual(result.shape, (4,4,1))
            np.testing.assert_array_equal(result.get_fdata()[:,:,0], data.min(axis=2))

    def test_repair_derivatives_and_preserve_source_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            anat=Path(tmp)/'sub-01/anat'; anat.mkdir(parents=True)
            nib.save(nib.Nifti1Image(np.ones((4,4,10),dtype='float32'),np.eye(4)),anat/'sub-01_swi.nii')
            sidecar=anat/'sub-01_minIP.json'; sidecar.write_text('{"SeriesNumber":7}')
            repair_derivatives(tmp)
            metadata=json.loads(sidecar.read_text())
            self.assertEqual(metadata['SeriesNumber'],7)
            self.assertEqual(metadata['ProjectionWindowSlices'],7)
            self.assertEqual(nib.load(anat/'sub-01_minIP.nii').get_fdata().shape,(4,4,4))


if __name__ == '__main__':
    unittest.main()
