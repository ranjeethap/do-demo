
---

### `docs/30-ci-cd.md`
```markdown
# CI/CD

## Secrets Needed
- `DO_TOKEN`
- `DOCR_REGISTRY`
- `DOCR_REPO`
- `DO_CLUSTER_NAME`

## Workflow Summary
1. Checkout
2. Install doctl, auth via `DO_TOKEN`
3. Docker build & push to `registry.digitalocean.com/${DOCR_REGISTRY}/${DOCR_REPO}:${SHA}`
4. Fetch kubeconfig via doctl
5. Deploy to `dev` (apply manifests or set image)
6. Optionally approve → promote to prod

## Validation & Troubleshooting
- Ensure the `DO_TOKEN` is **created under the same Team** as the cluster/registry
- `doctl account get` must NOT be 403 inside actions
- Use short-lived kubeconfig via `doctl kubernetes cluster kubeconfig save`
