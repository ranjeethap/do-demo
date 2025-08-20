# Architecture

## High-Level
```mermaid
flowchart TD
  Dev -->|commit| GitHub
  GitHub -->|Build| DOCR[(DigitalOcean Container Registry)]
  GitHub -->|Deploy| DOKS[(DOKS Cluster)]
  DOKS --> Ingress[Nginx Ingress Controller]
  Ingress --> SVC[Service (dev/prod)]
  SVC --> Deploy[Deployments]
  Deploy --> Pods[Pods]
  HPA[HPA] --> Deploy

Networking

DigitalOcean Load Balancer in front of nginx
sslip.io generates wildcard hostnames from your ingress IP

Scaling

HPA configured for CPU thresholds
Metrics Server required (see scripts/addons-helm.sh)

Secrets

Either use DOCR integration or imagePullSecrets
Optional: Bitnami Sealed Secrets / External Secrets