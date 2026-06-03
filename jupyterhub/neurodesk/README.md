# JupyterHub layer — now a single `neurodesk` Helm chart

This directory replaces the old multi-step, multi-chart way of installing the
JupyterHub application layer with **one** chart:
[`neurodesk/helm-chart`](https://github.com/neurodesk/helm-chart).

## What the chart now owns (was: separate scripts)

| Old (removed) | Now |
|---|---|
| `5-jupyterhub-values.yaml` + `9-install-jupyterhub.sh` | JupyterHub (z2jh subchart) |
| `6-cvmfs-mounts.sh` + `cvmfs_mount/` | CVMFS CSI + smarter-device-manager + `cvmfs` PVC |
| `8-security-setup.sh` + `security/` | Security Profiles Operator + AppArmor profile |
| `10-xnat-upload-extension.yaml` | XNAT notebook upload-extension ConfigMap (`xnat.enabled`) |
| `../../squid/` | optional CVMFS squid cache (`global.cvmfs.squidEnabled`) |

## What is still installed the same (infrastructure — consumed by name)

Longhorn (`2-install-longhorn.sh`), NFS (`3`/`4` + `../../nfs-server/`),
ingress-nginx + cert-manager + XNAT server (`../../scripts/install.sh`),
the Prometheus stack (`5-monitoring.sh`), and the XNAT **server-side** plugins
(`7-xnat-jupyter-plugin.sh` + the `.jar`). The chart references these; it does
not install them.

## Use

```bash
# 1. one-time: create your values from the template and fill in the secrets
cp values-devstack.yaml.template values-devstack.yaml
$EDITOR values-devstack.yaml      # OIDC client_id/secret, xnat-service apiToken, JUPYTERHUB_CRYPT_KEY_HEX

# 2. install (clones the chart, resolves deps, helm upgrade --install into `jupyter`)
./install.sh

# uninstall (keeps infrastructure)
./uninstall.sh
```

Overrides via env: `NAMESPACE`, `RELEASE`, `CHART_REPO`, `CHART_REF`,
`CHART_PATH` (point at a local chart checkout to skip cloning), `VALUES`.

`values-devstack.yaml` is **gitignored** (it holds the AAF OIDC secret, the XNAT
service token and the JupyterHub crypt key). `values-devstack.yaml.template`
is the committed, secrets-blanked copy.

## How `values-devstack.yaml` maps to the chart

- `global.cvmfs.server` — the Stratum-1 URLs (geoproximity + jetstream + fnal).
- `cvmfs.enabled: true` — chart manages CVMFS. (To run CVMFS yourself instead:
  `cvmfs.enabled=false` + `cvmfs.external=true`; see the chart's
  `docs/disabling-components.md`.)
- `security.enabled/installOperator: true` — bundles SPO + the `notebook`
  AppArmor profile.
- `xnat.enabled: true` + `xnat.server.{host,namespace}` — ships the notebook
  upload extension and the egress NetworkPolicy to the XNAT namespace.
- `jupyterhub:` — the full z2jh config (AAF OIDC, `/jupyter` base URL, the XNAT
  `extraConfig` username-mapping + pre-spawn hook, the `xnat-service` token).
