# NKP Day-2 Operations

Day-2 configuration for a Nutanix Kubernetes Platform (NKP) management cluster, using **Nutanix Objects** (S3-compatible) as the storage backend for logging and backups.

| Item | Value |
|------|-------|
| Cluster | `nkp-mgmt-shiv` |
| Namespace | `kommander` |
| Object store endpoint | `https://<OBJECTS_IP>:443` (self-signed TLS) |
| Region | `us-east-1` (placeholder; Nutanix Objects ignores it) |

## Contents

1. [Repository layout](#repository-layout)
2. [Prerequisites](#prerequisites)
3. [Secrets handling](#secrets-handling)
4. [Kommander app licensing overrides](#1-kommander-app-licensing-overrides)
5. [Grafana Loki on Nutanix Objects](#2-grafana-loki-on-nutanix-objects)
6. [Velero backups on Nutanix Objects](#3-velero-backups-on-nutanix-objects)
7. [Verification](#verification)
8. [Cleanup / rollback](#cleanup--rollback)
9. [Troubleshooting](#troubleshooting)

---

## Repository layout

```
.
├── README.md
├── .gitignore
├── kommander/
│   └── kommander-override.yaml
├── loki/
│   ├── loki-override.yml
│   ├── loki-secret.sh          # reads creds from env, no hardcoded keys
│   └── delete-loki.sh
└── velero/
    ├── velero-secret.yaml.tpl  # template only, real file is git-ignored
    └── no-certificate.sh
```

## Prerequisites

- `kubectl` access to the NKP management cluster (kubeconfig set)
- Nutanix Objects reachable from the cluster nodes on port 443
- Buckets already created in Nutanix Objects:
  - `shivang-bucket` (Loki)
  - `test-bucket` (Velero)
- An Objects access key/secret key with read/write on those buckets

## Secrets handling

**Never commit access keys.** Export them in your shell only:

```bash
export AWS_ID='<ACCESS_KEY>'
export AWS_SECRET='<SECRET_KEY>'
```

Recommended `.gitignore`:

```gitignore
*.secret.yaml
velero-secret.yaml
*.env
```

If keys were ever pasted into chat, tickets or git history, rotate them in Nutanix Objects.

---

## 1. Kommander app licensing overrides

Controls which applications are enabled by default per license tier.

`kommander/kommander-override.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kommander-overrides
  namespace: kommander
data:
  values.yaml: |
    kommander-licensing:
      defaultEnterpriseApps:
        - "centralized-grafana"
        - "karma"
        - "karma-traefik"
        - "prometheus-thanos-traefik"
        - "thanos"
        - "nkp-insights-management"
      defaultProApps:
        - "kubernetes-dashboard"
        - "kubetunnel"
        - "grafana-logging"
        - "grafana-loki-v3"
        - "kube-prometheus-stack"
        - "logging-operator"
        - "prometheus-adapter"
        - "velero"
        - "cilium-hubble-relay-traefik"
        - "cloudnative-pg"
```

Apply:

```bash
kubectl apply -f kommander/kommander-override.yaml
```

> Make sure Kommander is configured to consume this ConfigMap (via the Kommander installer config / `kommander-overrides`), then let the Kommander HelmRelease reconcile.

---

## 2. Grafana Loki on Nutanix Objects

### 2.1 Create the credentials secret

`loki/loki-secret.sh`

```bash
#!/bin/bash
set -euo pipefail

export CLUSTER_NAME=nkp-mgmt-shiv
export NAMESPACE=kommander
: "${AWS_ID:?export AWS_ID first}"
: "${AWS_SECRET:?export AWS_SECRET first}"

kubectl create secret generic ${CLUSTER_NAME}-loki-obj-creds \
  -n ${NAMESPACE} \
  --from-literal=AWS_ACCESS_KEY_ID=${AWS_ID} \
  --from-literal=AWS_SECRET_ACCESS_KEY=${AWS_SECRET}
```

### 2.2 Loki override values

`loki/loki-override.yml`

```yaml
loki:
  storage:
    type: s3
    bucketNames:
      chunks: shivang-bucket
      ruler: shivang-bucket
      admin: shivang-bucket
    s3:
      endpoint: https://<OBJECTS_IP>:443
      region: us-east-1
      s3ForcePathStyle: true
      insecure: false
      http_config:
        insecure_skip_verify: true   # self-signed cert

  structuredConfig:
    storage_config:
      aws:
        s3: https://<OBJECTS_IP>:443/shivang-bucket
        region: us-east-1
        s3forcepathstyle: true
        insecure: false
        http_config:
          insecure_skip_verify: true

# Inject S3 credentials into every Loki component
ingester:       { extraEnvFrom: [{ secretRef: { name: nkp-mgmt-shiv-loki-obj-creds } }] }
distributor:    { extraEnvFrom: [{ secretRef: { name: nkp-mgmt-shiv-loki-obj-creds } }] }
querier:        { extraEnvFrom: [{ secretRef: { name: nkp-mgmt-shiv-loki-obj-creds } }] }
queryFrontend:  { extraEnvFrom: [{ secretRef: { name: nkp-mgmt-shiv-loki-obj-creds } }] }
queryScheduler: { extraEnvFrom: [{ secretRef: { name: nkp-mgmt-shiv-loki-obj-creds } }] }
indexGateway:   { extraEnvFrom: [{ secretRef: { name: nkp-mgmt-shiv-loki-obj-creds } }] }
compactor:      { extraEnvFrom: [{ secretRef: { name: nkp-mgmt-shiv-loki-obj-creds } }] }
ruler:          { extraEnvFrom: [{ secretRef: { name: nkp-mgmt-shiv-loki-obj-creds } }] }
```

### 2.3 Apply to the `grafana-loki-v3` AppDeployment

```bash
# 1. Secret
bash loki/loki-secret.sh

# 2. Override ConfigMap
kubectl create configmap loki-overrides -n kommander \
  --from-file=values.yaml=loki/loki-override.yml

# 3. Reference it from the AppDeployment
kubectl patch appdeployment grafana-loki-v3 -n kommander --type merge \
  -p '{"spec":{"configOverrides":{"name":"loki-overrides"}}}'
```

> Verify the AppDeployment name with `kubectl get appdeployments -n kommander`. If your override ConfigMap name differs, adjust accordingly.

---

## 3. Velero backups on Nutanix Objects

### 3.1 Credentials secret

`velero/velero-secret.yaml.tpl` (copy to `velero-secret.yaml`, fill in, **do not commit**):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: dkp-velero
  namespace: kommander
type: Opaque
stringData:
  aws: |
    [test-bucket]
    aws_access_key_id=<ACCESS_KEY>
    aws_secret_access_key=<SECRET_KEY>
```

```bash
kubectl apply -f velero/velero-secret.yaml
```

The profile name (`[test-bucket]`) must match `AWS_PROFILE_VELERO` below.

### 3.2 Velero config override (skip TLS verification)

`velero/no-certificate.sh`

```bash
export BSL_NAME=test
export VELERO_BUCKET=test-bucket
export OBJECT_FQDN=<OBJECTS_IP>
export AWS_PROFILE_VELERO=test-bucket
export WORKSPACE_NAMESPACE=kommander

kubectl -n "${WORKSPACE_NAMESPACE}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: velero-config-overrides
  namespace: ${WORKSPACE_NAMESPACE}
data:
  values.yaml: |
    credentials:
      extraSecretRef: ""
    configuration:
      features: EnableCSI
      backupStorageLocation:
        - name: ${BSL_NAME}
          bucket: ${VELERO_BUCKET}
          provider: "aws"
          default: true
          config:
            region: us-east-1
            s3ForcePathStyle: "true"
            insecureSkipTLSVerify: "true"
            s3Url: "https://${OBJECT_FQDN}"
            profile: ${AWS_PROFILE_VELERO}
          credential:
            key: aws
            name: dkp-velero
      deployNodeAgent: true
      nodeAgent:
        podVolumePath: /var/lib/kubelet/pods
        tolerations:
          - operator: Exists
EOF
```

Reference it from the Velero AppDeployment:

```bash
kubectl patch appdeployment velero -n kommander --type merge \
  -p '{"spec":{"configOverrides":{"name":"velero-config-overrides"}}}'
```

> `insecureSkipTLSVerify` is for self-signed certs in lab setups. For production, import the Objects CA certificate instead.

---

## Verification

```bash
# AppDeployments / HelmReleases healthy
kubectl get appdeployments -n kommander
kubectl get helmreleases -n kommander | grep -E 'loki|velero'

# Loki pods running and using the secret
kubectl get pods -n kommander | grep loki
kubectl logs -n kommander -l app.kubernetes.io/component=ingester --tail=50

# Velero backup storage location should be Available
kubectl get backupstoragelocation -n kommander
velero backup-location get -n kommander

# Test backup
velero backup create test-backup --include-namespaces default -n kommander
velero backup describe test-backup -n kommander
```

Expected: BSL phase `Available`, Loki ingester/compactor logs show no S3 errors, and objects appear in the buckets.

## Cleanup / rollback

`loki/delete-loki.sh` removes the Loki deployment and related resources. Review it before running, and take a backup first. Rollback of the overrides:

```bash
kubectl patch appdeployment grafana-loki-v3 -n kommander --type json \
  -p '[{"op":"remove","path":"/spec/configOverrides"}]'
kubectl delete configmap loki-overrides velero-config-overrides -n kommander
kubectl delete secret nkp-mgmt-shiv-loki-obj-creds dkp-velero -n kommander
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `x509: certificate signed by unknown authority` | Self-signed Objects cert | Keep `insecure_skip_verify` / `insecureSkipTLSVerify`, or import the CA |
| `SignatureDoesNotMatch` / `403` | Wrong keys or path-style disabled | Recheck secret values; ensure `s3ForcePathStyle: true` |
| `NoSuchBucket` | Bucket not created / typo | Create bucket in Objects and match the name |
| BSL stuck `Unavailable` | Profile name mismatch | Make secret profile = `AWS_PROFILE_VELERO` |
| Loki pods `CrashLoopBackOff` | Secret missing in namespace | Re-run `loki-secret.sh` in `kommander` |
| Changes not applied | HelmRelease not reconciled | `flux reconcile hr <name> -n kommander` |

---

**Maintainer:** Shivang Bhardwaj
