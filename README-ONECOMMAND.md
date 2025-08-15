# One-command Demo Pack

Generated: 2025-08-14 19:44

## Usage
```bash
chmod +x demo.sh
./demo.sh up         # addons + deploy to dev
./demo.sh status
./demo.sh promote    # promote dev image to prod
./demo.sh hpa-demo   # generate load + watch HPA
./demo.sh down       # remove app resources (keeps cluster)
```
Requirements: kubectl, helm, doctl, jq, curl; kube context pointing at your DOKS cluster.
Optional `.env` to override:
- REGISTRY (default: dokr-saas)
- APP_IMAGE (default: registry.digitalocean.com/$REGISTRY/doks-flask)
