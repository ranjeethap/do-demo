#!/usr/bin/env bash
set -euo pipefail

echo "[repos] add/update"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add flagger https://flagger.app >/dev/null 2>&1 || true
helm repo add bitnami-labs https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "[metrics-server] install/upgrade"
helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system \
  --set-json 'args=["--kubelet-insecure-tls","--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP"]'

echo "[ingress-nginx] install/upgrade"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace

echo "[cert-manager] install/upgrade"
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set installCRDs=true

echo "[kube-prometheus-stack] install/upgrade"
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set grafana.enabled=true \
  --set alertmanager.enabled=false

# Flagger controller (cluster-wide)
kubectl create ns flagger --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install flagger flagger/flagger \
  -n flagger \
  --set meshProvider=kubernetes \
  --set metricsServer=http://kps-kube-prometheus-stack-prometheus.monitoring:9090

# Loadtester in dev
kubectl create ns dev --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install flagger-loadtester flagger/loadtester -n dev

echo "[sealed-secrets] install/upgrade"
helm upgrade --install sealed-secrets bitnami-labs/sealed-secrets -n kube-system

# Sealed Secrets (Helm-managed)
helm repo add bitnami-labs https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install sealed-secrets bitnami-labs/sealed-secrets -n kube-system --create-namespace

echo "[done] addons installed/updated"

