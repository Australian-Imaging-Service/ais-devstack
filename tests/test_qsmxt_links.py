import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEXT = (ROOT / 'manifests/qsmxt-scan-link-sync.yaml').read_text()
SCRIPT = '\n'.join(line[4:] for line in TEXT.split('  qsmxt-scan-link-sync.py: |\n', 1)[1].split('\n---', 1)[0].splitlines())
OUTPUT_RESOURCES = eval(SCRIPT.split('OUTPUT_RESOURCES = ', 1)[1].split('\nDRY_RUN', 1)[0], {'TARGET_RESOURCE': 'QSM'})
DISCOVERY = SCRIPT[SCRIPT.index('# Support compressed/'):SCRIPT.index('\nprint(\n    f"Done.')]


class LinkTests(unittest.TestCase):
    def test_map_resources_compression_sessions_and_idempotence(self):
        import json
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for session, anat, extension in [('a', 'sub-01/anat', '.nii.gz'), ('b', 'sub-01/ses-01/anat', '.nii')]:
                p = root / f'project/arc/{session}/RESOURCES/QSMXT/qsmxt/{anat}'
                p.mkdir(parents=True)
                for suffix in ['Chimap', 'desc-singlepass_Chimap', 'swi', 'minIP', 'desc-paramagnetic_smwi', 'desc-diamagnetic_minIP', 'desc-reliable_mask', 'T2starmap', 'R2starmap', 'R2primemap', 'dseg', 'part-mag_T2starw']:
                    (p / ('sub-01_' + suffix + extension)).write_bytes(b'fixture')
                    (p / ('sub-01_' + suffix + '.json')).write_text(json.dumps({'SeriesNumber': 7}))
                (p / 'sub-01_dseg.tsv').write_text('index\tname\n')
            calls = []
            def state(exp, scan, resource):
                path = root / f'project/arc/{exp}/SCANS/{scan}/{resource}'
                return path.exists(), {p.name for p in path.glob('*')}
            ns = dict(ARCHIVE_ROOT=root, SOURCE_RESOURCE='QSMXT', OUTPUT_RESOURCES=OUTPUT_RESOURCES, json=json, errors=[], DRY_RUN=False, created=0, skipped=0, linked_files=0,
                      experiment_id=lambda project, label: label, scan_present=lambda exp, scan: (True, 'phase'), target_resource_state=state,
                      q=str, rest=lambda *args: (calls.append(args) or (200,b'')), attach_link=lambda src,dst: (os.link(src,dst) or 'hardlink'))
            exec(compile(DISCOVERY, '<linker>', 'exec'), ns)
            self.assertEqual(ns['errors'], [])
            self.assertEqual(ns['linked_files'], 42)
            self.assertEqual(ns['created'], 14)
            for session, ext in [('a', '.nii.gz'), ('b', '.nii')]:
                scans = root / f'project/arc/{session}/SCANS/7'
                self.assertEqual({p.name for p in scans.iterdir()}, {'QSM','SWI','SMWI','T2STAR','R2STAR','R2PRIME','SEG'})
                self.assertEqual({p.name for p in (scans / 'SMWI').iterdir()}, {'sub-01_desc-paramagnetic_smwi' + e for e in ('.json', ext)} | {'sub-01_desc-diamagnetic_minIP' + e for e in ('.json', ext)})
                self.assertIn('sub-01_dseg.tsv', {p.name for p in (scans / 'SEG').iterdir()})
                self.assertIn('sub-01_desc-singlepass_Chimap.json', {p.name for p in (scans / 'QSM').iterdir()})
            exec(compile(DISCOVERY, '<linker>', 'exec'), ns)
            self.assertEqual(ns['skipped'], 14)
            self.assertEqual(ns['linked_files'], 42)


if __name__ == '__main__':
    unittest.main()
