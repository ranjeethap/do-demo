# Security & Secrets

## Image Pull Secrets
- Create `do-docr-secret` in namespaces:
```bash
kubectl -n dev create secret docker-registry do-docr-secret \
  --docker-server=registry.digitalocean.com \
  --docker-username="$(doctl auth list | awk 'NR==2 {print $1}')" \
  --docker-password="$(doctl auth token)"
kubectl -n dev patch serviceaccount default -p '{"imagePullSecrets":[{"name":"do-docr-secret"}]}'


Sealed Secrets (Optional)

Install controller:
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml

Create secret and seal via kubeseal

---

### `docs/90-faq.md`
```markdown
# FAQ

**Q: Can we migrate this to another cloud?**  
A: Yes. The app + K8s manifests are cloud-agnostic. Replace DO-specific pieces (e.g., DOCR auth, DO LoadBalancer) with equivalents (ECR/GCR/ACR, LBs). Ingress and HPA remain standard.

**Q: Why does CI/CD fail with 403?**  
A: The `DO_TOKEN` must belong to the Team that owns the target cluster/registry. Confirm with `doctl account get` in Actions logs.
