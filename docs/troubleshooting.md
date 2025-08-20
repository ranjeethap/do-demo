
---

### `docs/50-troubleshooting.md`
```markdown
# Troubleshooting

## DOCR 401 or 403
- Ensure `DO_TOKEN` belongs to the correct Team
- Confirm `doctl account get` succeeds
- Make sure DOCR repo path is correct: `registry.digitalocean.com/<registry>/<repo>`

## ImagePullBackOff
- Confirm `imagePullSecrets` present:
```bash
kubectl -n dev get sa default -o yaml | grep imagePullSecrets -A2

Confirm image exists in DOCR and tag is exact

Ingress 502/503
Ensure service endpoints are populated:
kubectl -n dev get endpoints doks-flask

Check container port (8080) matches service targetPort

Immutable Selector

If you change labels, recreate deployment or use a new name