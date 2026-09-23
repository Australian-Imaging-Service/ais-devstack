"""Run inside the QSMxT image; uses a synthetic five-echo phantom only.

The small sphere uses threshold masking; BET expects human-brain geometry.
"""
import tempfile

with tempfile.TemporaryDirectory() as tmp:
    from pathlib import Path
    import json,numpy as np,nibabel as nib
    root=Path(tmp) / "bids"; anat=root/'sub-01'/'anat';anat.mkdir(parents=True,exist_ok=True)
    (root/'dataset_description.json').write_text(json.dumps({'Name':'Synthetic QSM regression phantom','BIDSVersion':'1.9.0'}))
    x,y,z=np.mgrid[-16:16,-16:16,-16:16];r=x*x+y*y+z*z; mask=r<144
    rate=np.where(x<0,20.,40.)
    for e,te in enumerate([.005,.010,.015,.020,.025],1):
     mag=np.where(mask,1000*np.exp(-te*rate),0).astype('float32')
     phase=np.where(mask,te*(40*np.exp(-r/40)-10+0.2*z),0).astype('float32')
     for part,data in [('mag',mag),('phase',phase)]:
      base=anat/f'sub-01_echo-{e}_part-{part}_MEGRE'
      nib.save(nib.Nifti1Image(data,np.diag([1.,1.,1.,1.])),str(base)+'.nii.gz')
      Path(str(base)+'.json').write_text(json.dumps({'EchoTime':te,'MagneticFieldStrength':3.,'SeriesNumber':2 if part=='phase' else 1,'Units':'rad' if part=='phase' else 'arbitrary'}))
    
    import subprocess
    subprocess.run(['qsmxt','run',str(root),'--qsm-algorithm','hdqsm','--unwrapping-algorithm','romeo','--bf-algorithm','ismv','--mask','magnitude,threshold:otsu','--no-inhomogeneity-correction','--do-swi','--do-t2starmap','--do-r2starmap','--n-procs','4','--clean-intermediates'],check=True)
    import numpy as np,nibabel as nib
    from pathlib import Path
    from test_qsmxt_minip import repair_derivatives
    repair_derivatives(root / 'derivatives/qsmxt')
    p=root / 'derivatives/qsmxt/sub-01/anat'
    def read(s):return nib.load(p/f'sub-01_{s}.nii').get_fdata()
    r=read('R2starmap');t=read('T2starmap');s=read('swi');m=read('part-mag_T2starw');mask=read('mask')>0
    x,y,z=np.mgrid[-16:16,-16:16,-16:16];interior=(x*x+y*y+z*z<64)&mask
    for side,expected in [(x<0,20.),(x>=0,40.)]:
     region=interior&side
     assert region.sum()>100
     actual=float(np.median(r[region])); print('Expected R2*:',expected,'Measured:',actual)
     assert abs(actual-expected)/expected<.01
     assert np.allclose(t[region]*r[region],1,rtol=1e-5)
    assert np.isfinite(s).all() and s.max()>0
    assert not np.allclose(s,m)
    print('T2* median seconds:', np.median(t[interior&(x<0)]),np.median(t[interior&(x>=0)]))
    print('SWI finite and nonzero; differs from combined magnitude; all quantitative checks passed.')

    mip_image = nib.load(p / 'sub-01_minIP.nii')
    mip = mip_image.get_fdata()
    assert mip.shape == (s.shape[0], s.shape[1], s.shape[2] - 6)
    expected = np.stack([s[:, :, k:k+7].min(axis=2) for k in range(s.shape[2]-6)], axis=2)
    np.testing.assert_array_equal(mip, expected)
    print('minIP payload, dimensions, and projection values verified.')
