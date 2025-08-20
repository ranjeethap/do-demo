# Rolling Update Demo

## Flow
1. Edit `app/app.py`
2. Build/push via GitHub Actions (or `scripts/ci-local.sh`)
3. Update dev deployment image:
```bash
kubectl -n dev set image deploy/doks-flask app=registry.digitalocean.com/dokr-saas/doks-flask:<TAG>
kubectl -n dev rollout status deploy/doks-flask --timeout=300s
