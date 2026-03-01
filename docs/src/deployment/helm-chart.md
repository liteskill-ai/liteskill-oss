# Helm Chart

Liteskill publishes a Helm chart for deploying to Kubernetes. The chart handles the application deployment, database migrations, ingress, and optional autoscaling.

## Add the Helm Repository

```bash
helm repo add liteskill https://docs.liteskill.ai/helm
helm repo update
```

## Prerequisites

Before installing, you need:

- A running Kubernetes cluster
- A PostgreSQL database accessible from the cluster
- The following secrets ready:
  - `DATABASE_URL` — Ecto connection string (`ecto://USER:PASS@HOST/DATABASE`)
  - `SECRET_KEY_BASE` — generate with `mix phx.gen.secret` or `openssl rand -base64 64`
  - `ENCRYPTION_KEY` — generate with `openssl rand -base64 32`
  - `AWS_BEARER_TOKEN_BEDROCK` — your AWS Bedrock bearer token (if using Bedrock)
  - `AWS_REGION` — e.g. `us-east-1`

## Quick Install

```bash
helm install liteskill liteskill/liteskill \
  --namespace liteskill --create-namespace \
  --set config.phxHost=liteskill.example.com \
  --set secrets.databaseUrl="ecto://user:pass@db-host/liteskill" \
  --set secrets.secretKeyBase="$(openssl rand -base64 64)" \
  --set secrets.encryptionKey="$(openssl rand -base64 32)" \
  --set secrets.awsBearerToken="your-token" \
  --set secrets.awsRegion="us-east-1"
```

## Using a Values File

For production deployments, use a values file instead of inline `--set` flags.

```yaml
# values-production.yaml

config:
  phxHost: liteskill.example.com
  port: "4000"
  poolSize: "10"

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: liteskill.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: liteskill-tls
      hosts:
        - liteskill.example.com

secrets:
  existingSecret: liteskill-secrets

resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    memory: 1Gi
```

```bash
helm install liteskill liteskill/liteskill \
  --namespace liteskill --create-namespace \
  -f values-production.yaml
```

## Using an Existing Secret

Rather than passing secrets through Helm values (which end up in Helm release metadata), you can reference a pre-created Kubernetes Secret:

```bash
kubectl create secret generic liteskill-secrets \
  --namespace liteskill \
  --from-literal=DATABASE_URL="ecto://user:pass@db-host/liteskill" \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 64)" \
  --from-literal=ENCRYPTION_KEY="$(openssl rand -base64 32)" \
  --from-literal=AWS_BEARER_TOKEN_BEDROCK="your-token" \
  --from-literal=AWS_REGION="us-east-1"
```

Then reference it in your values:

```yaml
secrets:
  existingSecret: liteskill-secrets
```

The chart maps secret keys using `existingSecretKeys`, which defaults to:

```yaml
existingSecretKeys:
  databaseUrl: DATABASE_URL
  secretKeyBase: SECRET_KEY_BASE
  encryptionKey: ENCRYPTION_KEY
  awsBearerToken: AWS_BEARER_TOKEN_BEDROCK
  awsRegion: AWS_REGION
  oidcClientSecret: OIDC_CLIENT_SECRET
```

## Database Migrations

The chart includes a migration Job that runs as a Helm `pre-install` and `pre-upgrade` hook. It executes `bin/liteskill eval Liteskill.Release.migrate()` before the application starts.

Migrations are enabled by default. To configure:

```yaml
migration:
  enabled: true
  backoffLimit: 3              # retry attempts on failure
  activeDeadlineSeconds: 600   # timeout in seconds (default: 10 minutes)
```

## Ingress

Enable ingress to expose the application externally:

```yaml
ingress:
  enabled: true
  className: nginx    # or your ingress controller class
  annotations: {}
  hosts:
    - host: liteskill.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: liteskill-tls
      hosts:
        - liteskill.example.com
```

## Autoscaling

Horizontal Pod Autoscaling is available but disabled by default:

```yaml
replicaCount: 2

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
```

When using multiple replicas, set `dnsClusterQuery` to enable Erlang node clustering:

```yaml
config:
  dnsClusterQuery: "liteskill-headless.liteskill.svc.cluster.local"
```

## Pod Disruption Budget

Enable a PodDisruptionBudget to ensure availability during voluntary disruptions (node drains, cluster upgrades):

```yaml
podDisruptionBudget:
  enabled: true
  minAvailable: 1
```

## OIDC Authentication

To enable OpenID Connect authentication:

```yaml
oidc:
  enabled: true
  issuer: "https://your-idp.example.com"
  clientId: "liteskill"
  clientSecret: "your-client-secret"
```

Or with an existing secret that includes the `OIDC_CLIENT_SECRET` key:

```yaml
oidc:
  enabled: true
  issuer: "https://your-idp.example.com"
  clientId: "liteskill"

secrets:
  existingSecret: liteskill-secrets
```

## SAML Authentication

To enable SAML authentication, set `saml.enabled: true` and provide the IdP metadata file via a volume mount:

```yaml
saml:
  enabled: true
  idpMetadataFile: "/saml/metadata.xml"
  spId: "liteskill"
  spEntityId: "urn:liteskill:sp"
  spCertfile: "/saml/sp.crt"
  spKeyfile: "/saml/sp.key"
  idpId: "saml"
  baseUrl: "https://liteskill.example.com/sso"

extraVolumes:
  - name: saml-config
    secret:
      secretName: liteskill-saml

extraVolumeMounts:
  - name: saml-config
    mountPath: /saml
    readOnly: true
```

Create the Kubernetes secret containing the SAML files:

```bash
kubectl create secret generic liteskill-saml \
  --namespace liteskill \
  --from-file=metadata.xml=./idp-metadata.xml \
  --from-file=sp.crt=./sp-certificate.pem \
  --from-file=sp.key=./sp-private-key.pem
```

## Session Configuration

Configure session timeouts:

```yaml
config:
  sessionMaxAgeSeconds: "86400"         # max session age (default: 14 days)
  sessionIdleTimeoutSeconds: "3600"     # idle timeout (default: none)
```

## Single User Mode

Enable single user mode to skip authentication entirely (useful for personal/local deployments):

```yaml
config:
  singleUserMode: true
```

## Security Context

The chart sets pod and container security contexts by default for hardened deployments:

```yaml
# Pod-level (default)
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  fsGroup: 65534

# Container-level (default)
containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

To disable or customize, override the values:

```yaml
securityContext: {}
containerSecurityContext: {}
```

## Startup Probe

The chart includes a startup probe to handle slow-starting containers. This allows the application up to 60 seconds (30 failures x 2s period) to start before the liveness probe kicks in:

```yaml
startupProbe:
  httpGet:
    path: /login
    port: http
  failureThreshold: 30
  periodSeconds: 2
```

## Extra Volumes

Mount additional volumes into the application and migration containers (e.g. for SAML certificates, CA bundles, or database TLS certificates):

```yaml
extraVolumes:
  - name: db-certs
    secret:
      secretName: db-tls-certs

extraVolumeMounts:
  - name: db-certs
    mountPath: /certs
    readOnly: true
```

## Topology Spread Constraints

Spread pods across failure domains for high availability:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: liteskill
```

## Upgrading

```bash
helm repo update
helm upgrade liteskill liteskill/liteskill \
  --namespace liteskill \
  -f values-production.yaml
```

The migration hook runs automatically before each upgrade.

## ArgoCD

An example ArgoCD `Application` manifest is included in the repository at `deploy/argocd/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: liteskill
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://docs.liteskill.ai/helm
    chart: liteskill
    targetRevision: 0.2.51
    helm:
      releaseName: liteskill
      valuesObject:
        config:
          phxHost: liteskill.example.com
        ingress:
          enabled: true
          className: nginx
          hosts:
            - host: liteskill.example.com
              paths:
                - path: /
                  pathType: Prefix
          tls:
            - secretName: liteskill-tls
              hosts:
                - liteskill.example.com
        secrets:
          existingSecret: liteskill-secrets
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          limits:
            memory: 1Gi
  destination:
    server: https://kubernetes.default.svc
    namespace: liteskill
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

## All Values

For a full reference of available values, see the chart's [`values.yaml`](https://github.com/liteskill-ai/liteskill-oss/blob/main/helm/liteskill/values.yaml) or run:

```bash
helm show values liteskill/liteskill
```
