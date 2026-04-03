# AIS-XNAT Deployment for k3s

XNAT deployment on k3s with NFS-backed storage for the Australian Imaging Service.

### Important guidelines:

Never write credentials directly into the codebase and never commit them to github. Always use SOPS to encrypt secrets.

### Deployment Notes

- `kubectl` requires `sudo` on this machine (k3s kubeconfig at `/etc/rancher/k3s/k3s.yaml` is root-only)
- XNAT runs as a StatefulSet (`xnat-web-0`), rollouts take a few minutes for the pod to terminate and restart
- Always use `--post-renderer ./manifests/kustomize.sh` with helm commands — it applies NFS volume mount patches
- After helm upgrade, verify with: `sudo kubectl -n ais-xnat rollout status statefulset/xnat-web`

### Verify Installation

```bash
# Watch pods start up
sudo kubectl -n ais-xnat get pods -w

# Port forward to access locally
sudo kubectl -n ais-xnat port-forward svc/xnat-web 8080:80
```


## Configuration

### Ingress Host

Edit `manifests/values.yaml` to change the ingress hostname:

```yaml
xnat-web:
  ingress:
    hosts:
      - host: your-domain.example.com
```


#### Apply Configuration Changes

After updating the configuration files:

```bash
# Upgrade XNAT
helm upgrade xnat-web ais/xnat \
  --namespace ais-xnat \
  --values manifests/values.yaml \
  --post-renderer ./manifests/kustomize.sh

# Upgrade JupyterHub
helm upgrade jupyterhub jupyterhub/jupyterhub -n jupyter \
  --values jupyterhub/5-jupyterhub-values.yaml
```


## Stanford OIDC Authentication

XNAT uses the `openid-auth-plugin` with Stanford's Shibboleth-based OIDC provider (`login.stanford.edu`).

### Key OIDC endpoints (Stanford)

- Authorization: `https://login.stanford.edu/idp/profile/oidc/authorize`
- Token: `https://login.stanford.edu/idp/profile/oidc/token`
- UserInfo: `https://login.stanford.edu/idp/profile/oidc/userinfo`

### Critical: `userInfoUri` is required

Stanford's Shibboleth IdP puts minimal claims in the ID token (typically just `sub`). The `userInfoUri` must be configured so the XNAT plugin fetches the full profile (name, email, SUNet ID) from the UserInfo endpoint. Without it, user attributes won't be populated even though the consent screen asks for permission to share them.

### Claim mapping

The XNAT plugin maps OIDC claims to user fields via these properties in `values.yaml`:
- `usernamePattern` — which claim becomes the XNAT username (use `[preferred_username]` for SUNet ID, not `[sub]` which is an opaque ID)
- `emailProperty` — claim name for email (standard: `email`)
- `givenNameProperty` — claim name for first name (standard: `given_name`)
- `familyNameProperty` — claim name for last name (standard: `family_name`)

If user attributes still don't arrive after adding `userInfoUri`, debug by calling the UserInfo endpoint directly with an access token to see the exact claim names Stanford returns — Shibboleth IdPs sometimes use non-standard names.

### Stanford RP configuration

The Stanford relying party is managed at Stanford's RP Manager. Key settings:
- Client ID: configured in `values.yaml` under `openid.stanford.clientId`
- Scopes must include: `openid`, `profile`, `email`
- Subject Type: `public`
- PKCE: enabled (matches `pkceEnabled: true` in values.yaml)
- Redirect URIs must include: `https://<domain>/openid-login`

## Troubleshooting

### XNAT pod stuck in Init

```bash
kubectl -n ais-xnat describe pod xnat-web-0
kubectl -n ais-xnat logs xnat-web-0 -c home-init
```

### NFS connection issues

```bash
# Check NFS server is running
kubectl -n storage get pods
kubectl -n storage logs deploy/nfs-server

# Check PV/PVC binding
kubectl get pv
kubectl -n ais-xnat get pvc
```

### OIDC login issues

```bash
# Check XNAT logs for OIDC errors
sudo kubectl -n ais-xnat logs xnat-web-0 -c xnat-web | grep -i openid

# Debug claims returned by Stanford's UserInfo endpoint
curl -H "Authorization: Bearer <ACCESS_TOKEN>" \
  https://login.stanford.edu/idp/profile/oidc/userinfo
```

### Database issues

```bash
kubectl -n ais-xnat logs xnat-web-0-postgresql-0
```

## Plugins

Plugins in the `plugins/` directory are automatically copied to the NFS server during installation.

**Pre-installed plugins:**
- `container-service-3.7.2-uq-fat.jar` - Container service plugin

**To add more plugins:**

1. Place JAR files in `plugins/` before running install, OR
2. Copy manually after installation:

```bash
# Copy plugin jar to NFS server
kubectl -n storage cp my-plugin.jar \
  $(kubectl -n storage get pods -l app=nfs-server -o name | cut -d/ -f2):/exports/xnat/plugins/

# Restart XNAT to load new plugins
kubectl -n ais-xnat rollout restart statefulset xnat-web
```

## JupyterHub Integration

JupyterHub provides interactive Jupyter notebooks integrated with XNAT. The `jupyterhub/` directory contains the JupyterHub deployment as a git subtree from [ais-jupyterhub](https://github.com/Australian-Imaging-Service/ais-jupyterhub).

### Install JupyterHub

**Option 1:** During XNAT installation, answer "y" when prompted:
```
Install JupyterHub? (y/N): y
```

**Option 2:** Install separately after XNAT is running:
```bash
./scripts/install-jupyterhub.sh
```

The install script automatically reads the domain from `manifests/values.yaml` and configures JupyterHub to use the same domain.



### Update JupyterHub from Upstream

The `jupyterhub/` directory is a git subtree. To pull updates from the upstream ais-jupyterhub repository:

```bash
git subtree pull --prefix=jupyterhub \
  https://github.com/Australian-Imaging-Service/ais-jupyterhub.git \
  Development_AB --squash
```

To push local changes back to upstream (if you have write access):

```bash
git subtree push --prefix=jupyterhub \
  https://github.com/Australian-Imaging-Service/ais-jupyterhub.git \
  Development_AB
```

### JupyterHub Documentation

See the following files in `jupyterhub/` for more details:
- `README.md` - Architecture overview
- `XNAT-CONFIGURATION.md` - XNAT plugin setup
- `TROUBLESHOOTING.md` - Common issues and solutions
