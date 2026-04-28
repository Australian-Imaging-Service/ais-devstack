# Squid Caching Proxy for CVMFS on Kubernetes

A single Squid pod in front of your CVMFS clients gives you a **cluster-wide
shared HTTP cache**: first pod to fetch a file pays the WAN round-trip,
every other pod on any node gets it over the LAN. Falls back to direct WAN
fetches if Squid is unavailable, so it's optimization-only — not a SPOF.

## Files in this directory

| File | Purpose |
|---|---|
| [squid-configmap.yaml](squid-configmap.yaml) | `squid.conf` + `storeid.conf`. Refresh patterns and store-id rewriter for CVMFS. |
| [squid-pvc.yaml](squid-pvc.yaml) | 60Gi RWO cache volume. |
| [squid-deployment.yaml](squid-deployment.yaml) | Single-replica Deployment with init-cache + log-tail sidecar, pinned via node label. |
| [squid-service.yaml](squid-service.yaml) | ClusterIP on port 3128. |

Manifests use `__NS__`, `__SC__`, `__POD_CIDR__`, `__SVC_CIDR__` placeholders. The install script substitutes them at apply time.

## Quick start

```bash
../scripts/install-squid.sh        # detects k3s/microk8s, CIDRs, SC; renders + applies
# then edit jupyterhub/cvmfs_mount/values.yaml line ~68:
#   CVMFS_HTTP_PROXY="http://cvmfs-squid.mounts.svc.cluster.local:3128|DIRECT"
../jupyterhub/6-cvmfs-mounts.sh    # re-run to pick up the new proxy
```

Override defaults via env vars: `SQUID_NS`, `SQUID_SC`, `SQUID_NODE`, `SQUID_POD_CIDR`, `SQUID_SVC_CIDR`.

To remove: [`../scripts/uninstall-squid.sh`](../scripts/uninstall-squid.sh).

The rest of this document is the underlying reference — the manual steps the install script automates, plus gotchas, verification, and troubleshooting.

---

## Adapting for AWS / EKS + Karpenter

> Starting recommendations only — not yet validated end-to-end on EKS. Update this section once devops has tested.

The manifests in this directory are environment-agnostic; only the install script bakes in devstack defaults. For an EKS cluster with Karpenter, plan on:

**Override these env vars** when running [`install-squid.sh`](../scripts/install-squid.sh):

| Var | Why |
|---|---|
| `SQUID_SC=gp3` (or your EBS SC) | `local-path` is k3s-only; you need EBS-backed RWO. |
| `SQUID_POD_CIDR=<VPC CIDR>` | AWS VPC CNI uses VPC subnet CIDRs; `node.spec.podCIDR` is empty so detection falls back to the wrong default. |
| `SQUID_SVC_CIDR=172.20.0.0/16` | EKS apiserver isn't a pod, so detection fails; 172.20.0.0/16 is the EKS default. Confirm with `aws eks describe-cluster`. |
| `SQUID_NODE=<infra node name>` | Pin to a node in a **non-ephemeral** node group, not a Karpenter spot/consolidating node — otherwise Squid + cache get evicted on consolidation. |

**Structural decisions to make first:**

1. **A static infra node group** for the Squid host. Karpenter NodePools with `do-not-disrupt` work too, but a dedicated on-demand group is simpler.
2. **EBS volumes are zone-locked.** With `strategy: Recreate` + RWO, the replacement pod must come up in the same AZ to reattach. Either pin the infra node group to one AZ, or accept cache loss on AZ failover.
3. **Add a topology constraint** to [squid-deployment.yaml](squid-deployment.yaml) so the pod can only schedule in the EBS volume's AZ:
   ```yaml
   topologySpreadConstraints: []  # or a nodeAffinity on topology.kubernetes.io/zone
   ```

**Everything else carries over unchanged** — the ConfigMap, PVC schema, Service, refresh patterns, storeid rewrite, and the `CVMFS_HTTP_PROXY` line in cvmfs values.yaml all work identically.

---

## Prerequisites

- A working `cvmfs-csi` driver (`kubectl get pods -A | grep cvmfs`).
- A `ReadWriteOnce` StorageClass.
- Outbound HTTP from the cluster to your CVMFS Stratum-1 mirrors.

## What you need to customize

Everything below splits into two buckets: **required** (must change or the
manifests won't fit your cluster) and **optional** (sensible defaults, tune
only if you have a reason).

### Required — placeholders in the YAML

These are the `<…>` tokens you'll find scattered across the manifests.

| Placeholder | What it is | How to find it |
|---|---|---|
| `<NS>` | Namespace for Squid. Put it in the same NS as your `cvmfs-csi` pods. | `kubectl get pods -A \| grep cvmfs` |
| `<SC>` | `ReadWriteOnce` StorageClass name (for the cache PVC). | `kubectl get storageclass` |
| `<NODE>` | Worker node to pin Squid to (≥ 80 GiB free disk, good outbound bandwidth). | `kubectl get nodes -o wide` |
| `<POD_CIDR>` | Cluster pod network (for Squid's ACL). | `kubectl cluster-info dump \| grep cluster-cidr` |
| `<SVC_CIDR>` | Cluster service network (for Squid's ACL). | `kubectl cluster-info dump \| grep service-cluster-ip-range` |

### Required — existing cvmfs-csi config to edit

You are adding **one line** to the `default.local` ConfigMap your
`cvmfs-csi` install already uses:

```
CVMFS_HTTP_PROXY="http://cvmfs-squid.<NS>.svc.cluster.local:3128|DIRECT"
```

Full details and where exactly to put this (chart values vs raw ConfigMap)
are in Steps 6 and 7.

### Optional — knobs with sensible defaults

Change these only if you have a specific reason. They appear in the
manifests with the default value pre-filled.

| Knob | Default | When to change |
|---|---|---|
| Cache disk size (`cache_dir` in squid.conf + PVC `storage`) | 50000 MB / 60 Gi PVC | If you have lots of unique CVMFS objects and see the cache saturate. Keep PVC ≥ cache_dir + 10 Gi. |
| RAM cache (`cache_mem`) | 256 MB | Bump if the squid container has idle RAM and you want faster hot-object serving. |
| Max cacheable object size (`maximum_object_size`) | 1024 MB | Rarely needs changing for CVMFS. |
| Squid image | `ubuntu/squid:edge` | Pin to a specific tag (e.g. `ubuntu/squid:6.6-24.04_edge`) for reproducibility. |
| Squid resources (requests/limits) | 200m/512Mi → 1/1Gi | Bump if you see OOMKill or CPU throttling in heavy use. |
| Pod label key (`workload.cache/cvmfs-squid`) | as-is | Change only if it collides with another labeling scheme. Must match between `kubectl label node` in Step 1 and `nodeSelector` in Step 4. |
| Service name (`cvmfs-squid`) | as-is | Change only if you already have a service with that name. Must match the hostname in `CVMFS_HTTP_PROXY`. |
| Squid port (`3128`) | as-is | Change only if blocked by a NetworkPolicy. Must match between `squid.conf` `http_port`, the containerPort, the Service, and `CVMFS_HTTP_PROXY`. |
| `cvmfs-csi-nodeplugin` label in NetworkPolicy (Step 8) | as-is | Replace with whatever label your CSI chart actually sets on its nodeplugin pods — inspect with `kubectl get pods --show-labels`. |

---

## Step 1 — Pin via node label

```bash
kubectl label node <NODE> workload.cache/cvmfs-squid=true
```

We use a custom label (not `kubernetes.io/hostname`) so relocation is a
`kubectl label` away. Pick a node with ≥ 80 GiB free disk and decent
outbound bandwidth — Squid is the cluster's WAN gateway for CVMFS.

> Automated by [install-squid.sh](../scripts/install-squid.sh): single-node clusters get the only node; multi-node clusters use the first node unless `SQUID_NODE` is set.

---

## Step 2 — ConfigMap

See [squid-configmap.yaml](squid-configmap.yaml). The interesting bits are
the three CVMFS-specific `refresh_pattern` rules (content-addressed data vs
mutable manifests) and the `storeid` rewrite (cross-mirror dedup).

> One deviation from a hand-written ConfigMap: this repo encodes
> `storeid.conf` as a YAML double-quoted scalar with `\t` rather than a
> literal TAB byte, so copy-paste through editors can't silently break it.
> Same byte on disk after YAML parsing.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cvmfs-squid-config
  namespace: <NS>
  labels: { app: cvmfs-squid }
data:
  squid.conf: |
    http_port 3128

    acl Clients src <POD_CIDR> <SVC_CIDR>
    acl CONNECT method CONNECT
    http_access allow Clients
    http_access deny CONNECT
    http_access deny all

    cache_mem 256 MB
    maximum_object_size 1024 MB
    maximum_object_size_in_memory 128 KB
    cache_dir aufs /var/spool/squid 50000 16 256
    cache_replacement_policy heap LFUDA
    memory_replacement_policy heap GDSF

    # CVMFS /data/ objects are content-addressed -> cache hard (~21 days).
    refresh_pattern -i /data/ 30000 100% 30000 override-expire override-lastmod ignore-no-store ignore-private
    # Manifest pointers MUST revalidate every time or clients see stale state.
    refresh_pattern -i \.cvmfspublished$ 0 0% 0 ignore-no-store ignore-private
    refresh_pattern -i \.cvmfswhitelist$ 0 0% 0 ignore-no-store ignore-private
    refresh_pattern -i \.cvmfschecksum$ 0 0% 0 ignore-no-store ignore-private
    refresh_pattern . 30 20% 4320

    # Collapse all mirror hostnames into one cache key so an object fetched
    # via mirror A also serves requests routed through mirror B.
    store_id_program /usr/lib/squid/storeid_file_rewrite /etc/squid/storeid.conf
    store_id_children 20 startup=10 idle=5 concurrency=0

    access_log /var/log/squid/access.log squid
    cache_log  /var/log/squid/cache.log
    cache_store_log none
    pid_filename /var/run/squid.pid
    coredump_dir /var/spool/squid

    forwarded_for delete
    via off

  storeid.conf: |
    ^https?://[^/]+/cvmfs/(.*)$	http://cvmfs-canonical.local/cvmfs/$1
```

> ⚠️ **`storeid.conf` separator must be a literal TAB.** `storeid_file_rewrite`
> silently ignores lines that use spaces. Verify with:
>
> ```bash
> kubectl -n <NS> get cm cvmfs-squid-config -o jsonpath='{.data.storeid\.conf}' | cat -A
> ```
>
> Expect `^I` between the regex and the URL. If you see spaces, hit rate
> will flatline at zero.

---

## Step 3 — PVC

See [squid-pvc.yaml](squid-pvc.yaml).

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cvmfs-squid-cache
  namespace: <NS>
  labels: { app: cvmfs-squid }
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 60Gi           # ~10Gi headroom over cache_dir (50000 MB)
  storageClassName: <SC>
```

Size ~10 GiB above `cache_dir`; Squid corrupts if the FS hits 100%.

---

## Step 4 — Deployment

See [squid-deployment.yaml](squid-deployment.yaml). Three non-obvious bits:

- **`strategy: Recreate`** — the cache PVC is RWO; rolling updates deadlock.
- **`init-cache` init container** — `squid -z` has to build the
  256×16 dir layout on a fresh PVC.
- **`log-tail` sidecar** — the `ubuntu/squid` image can't log to
  `/dev/stdout` (proxy user is forbidden under `/dev/`), so we write to an
  emptyDir and tail it out of a busybox.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cvmfs-squid
  namespace: <NS>
  labels: { app: cvmfs-squid }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector:
    matchLabels: { app: cvmfs-squid }
  template:
    metadata:
      labels: { app: cvmfs-squid }
    spec:
      nodeSelector:
        workload.cache/cvmfs-squid: "true"
      securityContext:
        fsGroup: 13                       # "proxy" group in ubuntu/squid
      initContainers:
        - name: init-cache
          image: ubuntu/squid:edge
          command: ["sh", "-c"]
          args:
            - |
              set -e
              if [ ! -d /var/spool/squid/00 ]; then
                squid -N -z -f /etc/squid/squid.conf
              fi
          volumeMounts:
            - { name: config, mountPath: /etc/squid/squid.conf,   subPath: squid.conf }
            - { name: config, mountPath: /etc/squid/storeid.conf, subPath: storeid.conf }
            - { name: cache,  mountPath: /var/spool/squid }
      containers:
        - name: squid
          image: ubuntu/squid:edge
          command: ["squid", "-N", "-f", "/etc/squid/squid.conf"]
          ports: [{ name: proxy, containerPort: 3128 }]
          resources:
            requests: { cpu: 200m, memory: 512Mi }
            limits:   { cpu: "1",  memory: 1Gi }
          readinessProbe:
            tcpSocket: { port: 3128 }
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket: { port: 3128 }
            initialDelaySeconds: 30
            periodSeconds: 30
          volumeMounts:
            - { name: config, mountPath: /etc/squid/squid.conf,   subPath: squid.conf }
            - { name: config, mountPath: /etc/squid/storeid.conf, subPath: storeid.conf }
            - { name: cache,  mountPath: /var/spool/squid }
            - { name: run,    mountPath: /var/run }
            - { name: logs,   mountPath: /var/log/squid }
        - name: log-tail
          image: busybox:1.37
          command: ["sh", "-c"]
          args:
            - |
              while ! [ -f /var/log/squid/access.log ]; do sleep 1; done
              exec tail -F /var/log/squid/access.log /var/log/squid/cache.log
          resources:
            requests: { cpu: 10m,  memory: 16Mi }
            limits:   { cpu: 100m, memory: 64Mi }
          volumeMounts:
            - { name: logs, mountPath: /var/log/squid, readOnly: true }
      volumes:
        - { name: config, configMap: { name: cvmfs-squid-config } }
        - { name: cache,  persistentVolumeClaim: { claimName: cvmfs-squid-cache } }
        - { name: run,    emptyDir: {} }
        - { name: logs,   emptyDir: {} }
```

---

## Step 5 — Service

See [squid-service.yaml](squid-service.yaml). ClusterIP only — an externally exposed Squid is an open HTTP proxy.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cvmfs-squid
  namespace: <NS>
  labels: { app: cvmfs-squid }
spec:
  type: ClusterIP
  selector: { app: cvmfs-squid }
  ports:
    - { name: proxy, port: 3128, targetPort: 3128, protocol: TCP }
```

---

## Step 6 — Point CVMFS clients at Squid

**In this devstack:** the cvmfs-csi chart is driven by
[../jupyterhub/cvmfs_mount/values.yaml](../jupyterhub/cvmfs_mount/values.yaml).
That file holds the rendered `default.local` under
`extraConfigMaps.cvmfs-csi-default-local.default.local`. Change the
`CVMFS_HTTP_PROXY` line (currently `"DIRECT"`) to:

```
CVMFS_HTTP_PROXY="http://cvmfs-squid.mounts.svc.cluster.local:3128|DIRECT"
```

Then re-run [`../jupyterhub/6-cvmfs-mounts.sh`](../jupyterhub/6-cvmfs-mounts.sh) to roll the cvmfs-csi nodeplugin DaemonSet with the new proxy.

**Why not in install-squid.sh?** Toggling between DIRECT and Squid is a
deliberate decision (single-node devstack vs Karpenter) — the install script
deliberately stays out of the cvmfs values file and just prints the line to change.

**Notes on the proxy string:**
- `|` separates proxy *groups*; `DIRECT` = CVMFS keyword for "no proxy".
- Clients try Squid first; fall through to direct WAN fetches after repeated
  failures — so Squid is optimization-only.
- If the file already has `CVMFS_HTTP_PROXY` set to another proxy, chain
  instead of replacing: `"http://other-proxy:port;http://cvmfs-squid...:3128|DIRECT"`
  (`;` = load-balance within a group, `|` = failover between groups).

---

## Step 7 — Chart values (the part people forget)

> **In this devstack:** Step 7a is what you want — the cvmfs-csi `default.local`
> already lives in [../jupyterhub/cvmfs_mount/values.yaml](../jupyterhub/cvmfs_mount/values.yaml)
> under `extraConfigMaps.cvmfs-csi-default-local`. Steps 7b/7c (umbrella chart
> pattern, templated nodeSelector) are reference material for a future Helm-packaged
> form of this stack — the raw manifests in this directory don't use them.

If `cvmfs-csi` is Helm-managed, editing the generated ConfigMap directly is
temporary — next `helm upgrade` clobbers it. Update values instead.

**What you will need to change here:**

| Field | Replace with |
|---|---|
| `extraConfigMaps.cvmfs-csi-default-local` key name | Whatever key your chart version actually uses for default.local (see 7a). |
| `<NS>` inside `CVMFS_HTTP_PROXY` | Your chosen namespace. |
| `CVMFS_QUOTA_LIMIT` / `CVMFS_CACHE_BASE` | Match the chart's `cache.local.*` values so the client quota and cache path line up. |
| `squid.storageClassName` (umbrella chart, 7b) | Your `<SC>`. |
| `squid.clientCidrs` (umbrella chart, 7b) | Your `<POD_CIDR>` and `<SVC_CIDR>`. |
| `squid.nodeSelector` key (umbrella chart, 7b) | Match whatever label key you used in Step 1. |

### 7a. The `cvmfs-csi` chart

Depending on version, the default.local content is either in
`config.default`, `defaultLocal`, or `extraConfigMaps.<cm-name>`. Run
`helm show values cvmfs-csi/cvmfs-csi` to find the right key. Typical form:

```yaml
cache:
  local:
    cvmfsQuotaLimit: 40000
    location: /cvmfs-localcache

extraConfigMaps:
  cvmfs-csi-default-local:
    default.local: |
      CVMFS_USE_GEOAPI=no
      CVMFS_HTTP_PROXY="http://cvmfs-squid.<NS>.svc.cluster.local:3128|DIRECT"
      CVMFS_QUOTA_LIMIT=40000
      CVMFS_CACHE_BASE=/cvmfs-localcache
      CVMFS_MAX_RETRIES=2
      CVMFS_TIMEOUT=30
      CVMFS_TIMEOUT_DIRECT=30
      CVMFS_HOST_RESET_AFTER=1800
      CVMFS_MAX_PARALLEL_DOWNLOADS=6
      CVMFS_LOW_SPEED_LIMIT=1024
      CVMFS_SHARED_CACHE=no
      CVMFS_RELOAD_SOCKETS=/var/run/cvmfs
      CVMFS_NFILES=130560
      CVMFS_MAX_TTL=120
      CVMFS_KCACHE_TIMEOUT=60
      CVMFS_TELEMETRY_SEND=OFF
      CVMFS_TRACEBUFFER=0
```

### 7b. Umbrella chart pattern

If you wrap `cvmfs-csi` in a platform chart, the common pattern is a
top-level toggle that templates both the proxy URL and whether Squid itself
deploys:

```yaml
# values.yaml
squid:
  enabled: true
  image: ubuntu/squid:edge
  storageClassName: <SC>
  cacheSize: 60Gi
  cacheDirSizeMB: 50000
  cacheMemMB: 256
  maxObjectSizeMB: 1024
  clientCidrs: [<POD_CIDR>, <SVC_CIDR>]
  nodeSelector:
    workload.cache/cvmfs-squid: "true"
  tolerations: []
  affinity: {}
  resources:
    requests: { memory: 512Mi, cpu: 200m }
    limits:   { memory: 1Gi,   cpu: "1" }
```

With the `default.local` template switching on the toggle:

```
CVMFS_HTTP_PROXY="{{- if .Values.squid.enabled -}}http://cvmfs-squid.<NS>.svc.cluster.local:3128|DIRECT{{- else -}}DIRECT{{- end -}}"
```

### 7c. Adding `nodeSelector` if the chart lacks it

Many `squid-deployment` templates don't expose `nodeSelector` /
`tolerations` / `affinity`. Patch them in:

```yaml
spec:
  template:
    spec:
      {{- with .Values.squid.nodeSelector }}
      nodeSelector: {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.squid.tolerations }}
      tolerations: {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.squid.affinity }}
      affinity: {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        fsGroup: 13
      # ...
```

### 7d. Validate before committing

```bash
helm template r ./chart -n <NS> -f values.yaml | grep -A 120 "name: cvmfs-squid"
```

Confirm: `nodeSelector` is populated, the Service is `ClusterIP`, and
`CVMFS_HTTP_PROXY` in the default.local ConfigMap points at Squid.

---

## Step 8 — (Optional) NetworkPolicy

If your CNI enforces NetworkPolicies:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cvmfs-squid
  namespace: <NS>
spec:
  podSelector: { matchLabels: { app: cvmfs-squid } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector:
            matchLabels: { app: cvmfs-csi-nodeplugin }  # adjust to your label
      ports: [{ protocol: TCP, port: 3128 }]
  egress:
    - to: [{ namespaceSelector: {} }]
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to: []
      ports:
        - { protocol: TCP, port: 80 }
        - { protocol: TCP, port: 8000 }
        - { protocol: TCP, port: 443 }
```

---

## Step 9 — (Optional) Prometheus metrics

Squid has no native `/metrics` endpoint. Add a `squid-exporter` sidecar:

```yaml
- name: exporter
  image: boynux/squid-exporter:v1.11
  env:
    - { name: SQUID_HOSTNAME, value: "localhost" }
    - { name: SQUID_PORT,     value: "3128" }
    - { name: SQUID_EXPORTER_LISTEN, value: ":9301" }
  ports: [{ name: metrics, containerPort: 9301 }]
```

And expose a `metrics` port on the Service. Scrape for cache hit ratio,
bytes served from cache, request rate by status.

---

## Verification

(Replace `<NS>` with your namespace — `mounts` if you used the install script defaults.)

```bash
# Pod on the right node
kubectl -n <NS> get pod -l app=cvmfs-squid -o wide

# Live log stream
kubectl -n <NS> logs deploy/cvmfs-squid -c log-tail -f --tail=100

# Hit/miss ratio over the last 500 lines
kubectl -n <NS> logs deploy/cvmfs-squid -c log-tail --tail=500 \
  | awk '{print $4}' | sort | uniq -c | sort -rn
```

Status codes:

| Code | Meaning |
|---|---|
| `TCP_HIT/200` | Served from cache — the win. |
| `TCP_MISS/200` | Cold fetch, Squid went upstream. Normal on first request. |
| `TCP_REFRESH_UNMODIFIED/304` | Revalidation for a manifest file. Cheap. |
| `TCP_DENIED/403` | Client IP not in `acl Clients` — your CIDRs are wrong. |
| `NONE_NONE/000` | TCP health probe, ignore. |

**Cross-node cache test** — the definitive proof that Squid is actually
sharing across nodes. Pick two pods on different nodes, read the same
CVMFS path from each. Pod A's reads should produce `TCP_MISS`, pod B's
should produce `TCP_HIT` for the same URLs. If B is still MISS, it's
almost always the `storeid.conf` TAB issue.

---

## Troubleshooting

- **Pod Pending** — missing node label, or PVC can't bind. `kubectl
  describe pod` / `describe pvc`.
- **Crashloop** — `kubectl logs --previous -c squid`. Usually a config
  typo or full PVC.
- **Near-zero hit rate after warm-up** — `storeid.conf` TAB got converted
  to spaces. Re-verify with `cat -A`.
- **`TCP_DENIED/403`** — the client source IP in the log isn't covered
  by your `<POD_CIDR>` / `<SVC_CIDR>`.
- **Client still shows `DIRECT`** — nodeplugin DaemonSet didn't pick up
  the config change. Force a rollout.

---



```bash
# Restart to pick up ConfigMap edits
kubectl -n <NS> rollout restart deploy/cvmfs-squid

# Move Squid to another node
kubectl label node <OLD> workload.cache/cvmfs-squid-
kubectl label node <NEW> workload.cache/cvmfs-squid=true
kubectl -n <NS> rollout restart deploy/cvmfs-squid

# Cold-start cache (nuclear)
kubectl -n <NS> scale deploy/cvmfs-squid --replicas=0
# delete PVC contents, or delete+recreate the PVC
kubectl -n <NS> scale deploy/cvmfs-squid --replicas=1
```

**Moving Squid with a node-local StorageClass** (`local-path`, `hostPath`)
requires recreating the PVC on the new node — the cache is lost and warms
back up. Use a network-attached SC if you need the volume to follow the pod.
