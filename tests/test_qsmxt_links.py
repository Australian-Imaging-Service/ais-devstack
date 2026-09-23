import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEXT = (ROOT / 'manifests/qsmxt-scan-link-sync.yaml').read_text()
SCRIPT = '\n'.join(line[4:] for line in TEXT.split('  qsmxt-scan-link-sync.py: |\n', 1)[1].split('\n---', 1)[0].splitlines())
DISCOVERY = SCRIPT[SCRIPT.index('# Support compressed/'):SCRIPT.index('\nprint(\n    f"Done.')]


class LinkTests(unittest.TestCase):
    def test_map_resources_compression_sessions_and_idempotence(self):
        import json
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for session, anat, extension in [('a', 'sub-01/anat', '.nii.gz'), ('b', 'sub-01/ses-01/anat', '.nii')]:
                p = root / f'project/arc/{session}/RESOURCES/QSMXT/qsmxt/{anat}'
                p.mkdir(parents=True)
                for suffix in ['Chimap', 'swi', 'minIP', 'T2starmap', 'R2starmap', 'part-mag_T2starw']:
                    (p / ('sub-01_' + suffix + extension)).write_bytes(b'fixture')
                    (p / ('sub-01_' + suffix + '.json')).write_text(json.dumps({'SeriesNumber': 7}))
            calls = []
            def state(exp, scan, resource):
                path = root / f'project/arc/{exp}/SCANS/{scan}/{resource}'
                return path.exists(), {p.name for p in path.glob('*')}
            ns = dict(ARCHIVE_ROOT=root, SOURCE_RESOURCE='QSMXT', OUTPUT_RESOURCES={'Chimap':'QSM','swi':'SWI','minIP':'SWI','T2starmap':'T2STAR','R2starmap':'R2STAR'}, json=json, errors=[], DRY_RUN=False, created=0, skipped=0, linked_files=0,
                      experiment_id=lambda project, label: label, scan_present=lambda exp, scan: (True, 'phase'), target_resource_state=state,
                      q=str, rest=lambda *args: (calls.append(args) or (200,b'')), attach_link=lambda src,dst: (os.link(src,dst) or 'hardlink'))
            exec(compile(DISCOVERY, '<linker>', 'exec'), ns)
            self.assertEqual(ns['errors'], [])
            self.assertEqual(ns['linked_files'], 20)
            self.assertEqual(ns['created'], 8)
            for session in ['a','b']:
                scans = root / f'project/arc/{session}/SCANS/7'
                self.assertEqual({p.name for p in scans.iterdir()}, {'QSM','SWI','T2STAR','R2STAR'})
            exec(compile(DISCOVERY, '<linker>', 'exec'), ns)
            self.assertEqual(ns['skipped'], 8)
            self.assertEqual(ns['linked_files'], 20)


if __name__ == '__main__':
    unittest.main()
