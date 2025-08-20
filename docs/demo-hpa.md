
---

### `docs/42-demos-hpa.md`
```markdown
# HPA Demo

## Setup
- Metrics Server installed
- HPA manifest in `scripts/manifests/dev-hpa.yaml`

## Steps
```bash
./scripts/hpa-demo.sh
kubectl -n dev get hpa

Watch Scaling

kubectl top pods -n dev
Grafana CPU/HPA dashboard