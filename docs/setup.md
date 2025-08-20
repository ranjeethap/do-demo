
---

### `docs/20-setup.md`
```markdown
# Setup & Prerequisites

## Tools
- `doctl`, `kubectl`, `helm`, `docker`

## Authenticate
```bash
doctl auth init
doctl kubernetes cluster kubeconfig save <your-cluster>
doctl registry login

Registry

Ensure dokr-saas exists
Ensure repository doks-flask does not have typos
Ensure your token has read/write scope

Bring Up
./demo.sh up
source ./.ingress_addr
curl "http://dev.${ING_ADDR}.sslip.io/"
