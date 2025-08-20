# DigitalOcean DOKS Demo Automation

This repository provides a **one-command automation toolkit** for deploying a sample Flask app into **DigitalOcean Kubernetes (DOKS)** with a CI/CD style workflow.  
It includes scripts to provision, deploy, promote, and test deployments across `dev` and `prod` namespaces.

---

## 🚀 Features
- Automated **Docker image build & push** to DigitalOcean Container Registry.
- Kubernetes manifests templated with **envsubst** and rendered into `rendered/`.
- One-command lifecycle via `demo.sh`:
  - `up` → Deploy dev environment
  - `promote` → Promote dev image to prod
  - `down` → Cleanup
- Examples of advanced rollout strategies:
  - [Canary Deployment](docs/canary.md)
  - [Rolling Deployment](docs/rolling.md)
  - [Horizontal Pod Autoscaler](docs/hpa.md)
- Ingress with **sslip.io** for zero-config DNS.
- Helper scripts for cluster bootstrap, helm addons, git automation.

---

## 📂 Repository Structure
```
.
├── app/ # Sample Flask app
│ ├── app.py # Application entrypoint
│ ├── Dockerfile # Dockerfile for the Flask app
│ └── requirements.txt # Python dependencies
├── demo.sh # Main automation script
├── demo.sh.org # Backup copy of demo.sh
├── Dockerfile # (Optional root Dockerfile)
├── dokr-saas/ # Registry placeholder
├── doks-flask/ # Deployment placeholder
├── README-ONECOMMAND.md # Initial readme for one-command setup
├── rendered/ # Rendered manifests after demo.sh up
│ ├── dev-deploy.yaml
│ ├── dev-hpa.yaml
│ ├── dev-ingress.yaml
│ ├── dev-svc.yaml
│ ├── prod-deploy.tmpl.yaml
│ ├── prod-ingress.yaml
│ └── prod-svc.yaml
├── scripts/ # Supporting scripts (addons, git, cluster ops, HPA, etc.)
│ ├── addons-helm.sh
│ ├── ci-local.sh
│ ├── cluster.sh
│ ├── demo-canary.sh
│ ├── demo-rolling.sh
│ ├── git.sh
│ ├── hpa-demo.sh
│ ├── manifests/ # Kubernetes manifest templates
│ │ ├── dev-deploy.yaml
│ │ ├── dev-hpa.yaml
│ │ ├── dev-ingress.yaml
│ │ ├── dev-svc.yaml
│ │ ├── prod-deploy.tmpl.yaml
│ │ ├── prod-ingress.yaml
│ │ └── prod-svc.yaml
│ ├── VERSION
│ └── wait-ready.sh
├── docs/ # Extended documentation and guides
│ ├── demo-canary.md
│ ├── demo-rolling.md
│ ├── demo-hpa.md
│ └── demo-hpatroubleshooting.md
└── VERSION # Version file

```

---

## 🔧 Prerequisites
- [doctl](https://docs.digitalocean.com/reference/doctl/) (logged in with `doctl auth init`)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/)
- Docker (authenticated to DOCR via `doctl registry login`)

---
## Architecture

---

## ⚡ Quick Start

```bash
# 1. Deploy app to DEV
./demo.sh up

# 2. Promote the DEV image to PROD
./demo.sh promote

# 3. Cleanup all resources
./demo.sh down

Access URLs (auto-printed):

DEV → http://dev.<ING_ADDR>.sslip.io/
PROD → http://prod.<ING_ADDR>.sslip.io/
```

---
### 📖 Extended Documentation

See the docs/
 folder for detailed walkthroughs:

Cluster Setup
CI/CD Workflow
Canary Deployment Demo
Rolling Deployment Demo
HPA Scaling Demo


---

## 📂 `/docs` folder

### `docs/cluster.md`
```markdown
# Cluster Setup Guide
```
### 1. Create Kubernetes Cluster
```bash
./scripts/cluster.sh create

2. Install NGINX Ingress Controller
./scripts/addons-helm.sh ingress

3. Verify
kubectl get svc -n ingress-nginx

The external IP is used for sslip.io DNS.
```

---

### 🧰 CI/CD (GitHub Actions)
```
Workflow builds image → pushes to DOCR → deploys to dev → promotes to prod upon manual approval or tag.
```
---
### Secrets required:
```
DO_TOKEN: DigitalOcean PAT (read/write to registry & cluster)
DOCR_REGISTRY: e.g., dokr-saas
DOCR_REPO: e.g., doks-flask
DO_CLUSTER_NAME: your DOKS cluster name (e.g., doks-saas-cluster)
Optionally: KUBECONFIG_B64 (if not fetching via doctl)
```

---
### `docs/cicd.md`
```markdown
# CI/CD Workflow

This repository simulates a CI/CD pipeline with **dev → prod promotion**.
```
---

## Workflow

```
1. Developer pushes code → Docker image built & pushed to DOCR.
2. `demo.sh up` deploys to DEV namespace.
3. Once validated, `demo.sh promote` promotes the same image to PROD.
4. Ingress exposes `dev.*` and `prod.*` URLs.
```

---

## Benefits
```
- Deterministic promotion (same image tested in dev is promoted to prod).
- Fast rollback via `kubectl rollout undo`.
- Separate namespaces ensure isolation.
```
---

## 🧹 Cleanup
./demo.sh down

---

## Optional: delete cluster (if you created one via scripts/cluster.sh)
./scripts/cluster.sh delete
