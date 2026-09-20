# Arc on Kubernetes

Plain manifests for a highly available Arc: three nodes clustered over DNS, behind an
Ingress that forwards WebSockets, with readiness that follows Postgres and a drain
window on every rollout. Apply in order:

```bash
kubectl apply -f namespace.yaml
kubectl create secret generic arc-secrets -n arc \
  --from-literal=DATABASE_URL='postgres://arc:...@postgres:5432/arc' \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')" \
  --from-literal=ARC_ENCRYPTION_KEY="$(openssl rand -base64 32)" \
  --from-literal=RELEASE_COOKIE="$(openssl rand -hex 32)" \
  --from-literal=ARC_METRICS_AUTH_TOKEN="$(openssl rand -hex 32)" \
  --from-literal=ARC_OIDC_CLIENT_SECRET='...'
kubectl apply -f configmap.yaml -f service.yaml -f deployment.yaml -f pdb.yaml -f ingress.yaml
kubectl -n arc rollout status deploy/arc
```

Back up `ARC_ENCRYPTION_KEY` before the first app is created. Postgres is assumed to be
managed (RDS, Cloud SQL, or an operator) and reachable at `DATABASE_URL`.

Edit `configmap.yaml` for your hostname, admin emails, identity provider, and the
CIDR of your ingress controller (`ARC_TRUSTED_PROXIES`). The Ingress annotations are
for ingress-nginx; other controllers need their own WebSocket and timeout settings.

See the [high availability runbook](../../website/content/docs/operations/high-availability.mdx)
for what to verify before an event and what to do when something breaks.
