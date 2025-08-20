
---

### `docs/60-runbook.md`
```markdown
# Ops Runbook

## Daily Checks
- `kubectl get nodes -o wide`
- `kubectl -n dev get deploy,svc,ingress`
- `kubectl -n prod get deploy,svc,ingress`

## Rollback
```bash
kubectl -n dev rollout undo deploy/doks-flask
kubectl -n prod rollout undo deploy/doks-flask

Promotion
./demo.sh promote

Monitoring
Prometheus/Grafana: confirm CPU, memory, HTTP latencies