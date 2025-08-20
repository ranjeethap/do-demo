
---

### `docs/41-demos-canary.md`
```markdown
# Canary Demo

- Uses `doks-flask` service as stable
- Optional: Install Flagger and loadtester via `scripts/addons-helm.sh`

## Trigger
```bash
./scripts/demo-canary.sh

Observability

Grafana dashboards: HPA, Nginx, and request success rate
Confirm incrementally increasing traffic to canary