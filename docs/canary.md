# Canary Deployment Demo

## Objective
Deploy a new version to a small subset of users before full rollout.

## Steps
```bash
./scripts/demo-canary.sh

This script:

Creates a canary deployment with limited replicas.

Splits traffic between stable and canary versions.

Gradually shifts traffic to canary if stable.

Verification

Curl the ingress multiple times to observe traffic distribution.

---

### `docs/rolling.md`
```markdown
# Rolling Deployment Demo

## Objective
Perform a zero-downtime rolling upgrade of the app.

## Steps
```bash
./scripts/demo-rolling.sh
This triggers a deployment update with rolling strategy.

Verification

Pods are updated incrementally, ensuring continuous availability.

---

### `docs/hpa.md`
```markdown
# Horizontal Pod Autoscaler (HPA) Demo

## Objective
Scale pods automatically based on CPU usage.

## Steps
```bash
./scripts/hpa-demo.sh

This script:

Deploys HPA targeting the dev deployment.
Generates load via a test client.
Observes scaling up/down of replicas.

Verification
kubectl -n dev get hpa

Shows real-time scaling metrics.
W3
