#!/usr/bin/env bash
# Wait until DOKS demo dependencies are healthy before continuing.
# - Verifies pods in key namespaces become Ready
# - Waits for Ingress external IP
# - Confirms cert-manager, sealed-secrets, Prometheus, Grafana are up

set -euo pipefail

info(){ echo -e "[wait] $*"; }
die(){ echo -e "[wait][error] $*" >&2; exit 1; }

# Only wait for namespaces that actually exist to avoid immediate failures
maybe_wait_ns() {
  local ns="$1"
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    info "Waiting for pods in namespace: ${ns}"
    # If there are 0 pods, skip the wait to avoid hanging
    local count
    count="$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${count:-0}" -gt 0 ]]; then
      kubectl -n "$ns" wait --for=condition=Ready pods --all --timeout=600s || \
        die "Timeout waiting for pods in ${ns}"
    else
      info "No pods found in ${ns}, skipping pod wait"
    fi
  else
    info "Namespace ${ns} not present; skipping"
  fi
}

# 1) Core addon namespaces
for ns in ingress-nginx cert-manager kube-system monitoring flagger dev prod; do
  maybe_wait_ns "$ns"
done

# 2) Ingress external IP
if kubectl -n ingress-nginx get svc ingress-nginx-controller >/dev/null 2>&1; then
  info "Waiting for ingress-nginx LoadBalancer IP"
  for i in {1..120}; do
    ip="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "${ip:-}" ]] && { info "Ingress IP: ${ip}"; break; }
    sleep 5
  done
  [[ -z "${ip:-}" ]] && die "Ingress IP not assigned"
fi

# 3) cert-manager webhook ready
if kubectl -n cert-manager get deploy cert-manager-webhook >/dev/null 2>&1; then
  info "Waiting for cert-manager webhook rollout"
  kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s || \
    die "cert-manager webhook not ready"
fi

# 4) sealed-secrets controller ready
if kubectl -n kube-system get deploy sealed-secrets-controller >/dev/null 2>&1; then
  info "Waiting for sealed-secrets controller rollout"
  kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=300s || \
    die "sealed-secrets controller not ready"
fi

# 5) Prometheus & Grafana (kube-prometheus-stack common names)
if kubectl -n monitoring get deploy kps-grafana >/dev/null 2>&1; then
  info "Waiting for Grafana rollout (kps-grafana)"
  kubectl -n monitoring rollout status deploy/kps-grafana --timeout=600s || \
    die "Grafana not ready (kps-grafana)"
elif kubectl -n monitoring get deploy kube-prometheus-stack-grafana >/dev/null 2>&1; then
  info "Waiting for Grafana rollout (kube-prometheus-stack-grafana)"
  kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=600s || \
    die "Grafana not ready (kube-prometheus-stack-grafana)"
fi

if kubectl -n monitoring get statefulset kps-kube-prometheus-stack-prometheus >/dev/null 2>&1; then
  info "Waiting for Prometheus (kps-kube-prometheus-stack-prometheus)"
  kubectl -n monitoring rollout status statefulset/kps-kube-prometheus-stack-prometheus --timeout=600s || \
    die "Prometheus not ready (kps-...)"
elif kubectl -n monitoring get statefulset kube-prometheus-stack-prometheus >/dev/null 2>&1; then
  info "Waiting for Prometheus (kube-prometheus-stack-prometheus)"
  kubectl -n monitoring rollout status statefulset/kube-prometheus-stack-prometheus --timeout=600s || \
    die "Prometheus not ready (kube-prometheus-stack-...)"
fi

info "All critical components are Ready."
