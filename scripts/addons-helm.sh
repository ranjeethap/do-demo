#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# addons-helm.sh
# Installs/Upgrades:
#   - metrics-server (in kube-system)
#   - kube-prometheus-stack (Prometheus + Grafana) in monitoring
# Prints access endpoints for Grafana and Prometheus.
#
# Usage:
#   ./scripts/addons-helm.sh install
#   ./scripts/addons-helm.sh status
#
# Add to demo.sh (recommended):
#   - Call "addons-helm.sh install" from "up"
#   - Call "addons-helm.sh status" from "status"
# ------------------------------------------------------------------------------

log() { echo -e "\033[1;32m[addons] $*\033[0m"; }
err() { echo -e "\033[1;31m[addons][ERROR] $*\033[0m" >&2; }

ensure_helm_repos() {
  log "Adding/Updating Helm repos..."
  # metrics-server chart repo
  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
  # kube-prometheus-stack chart repo
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update
}

install_metrics_server() {
  log "Installing/Upgrading metrics-server..."
  # This args block avoids TLS issues and ensures kubelet uses InternalIP first.
  # Correct Helm syntax: comma-separated list (no trailing comma).
  helm upgrade --install metrics-server metrics-server/metrics-server \
    -n kube-system \
    --set args="{--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP}" \
    --wait --timeout 5m

  # Wait for API availability
  if ! kubectl top nodes >/dev/null 2>&1; then
    log "Waiting for Metrics API to become available..."
    sleep 10
    kubectl top nodes || log "Metrics may take ~1–2 minutes to show up."
  fi
}

install_kube_prometheus_stack() {
  log "Installing/Upgrading kube-prometheus-stack (Prometheus + Grafana)..."
  # Release name "kps" in namespace "monitoring".
  # Grafana LB enabled; Prometheus LB enabled.
  # Note: adminPassword is set here for consistency with older flows.
  # You can change it via --set grafana.adminPassword=xxxx if desired.
  helm upgrade --install kps prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    --set grafana.enabled=true \
    --set grafana.service.type=LoadBalancer \
    --set grafana.service.port=80 \
    --set grafana.adminPassword="prom-operator" \
    --set prometheus.service.type=LoadBalancer \
    --set prometheus.service.port=9090 \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --wait --timeout 10m

  # Hint: If you run ingress-nginx with ServiceMonitors enabled, KPS will
  # automatically discover them as long as label selectors match defaults.
}

# Return "EXTERNAL-IP" if present, else prints empty string.
get_svc_external_ip() {
  local ns="$1" name="$2"
  kubectl -n "$ns" get svc "$name" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
}

# Return "NODE-IP:NODEPORT" fallback (first node) if no external IP.
get_svc_nodeport_fallback() {
  local ns="$1" name="$2" port_field="$3" # e.g., "spec.ports[?(@.port==80)].nodePort"
  local nodeport
  nodeport=$(kubectl -n "$ns" get svc "$name" -o jsonpath="{.${port_field}}") || true
  if [[ -z "$nodeport" ]]; then
    echo ""
    return 0
  fi
  # Get first Ready node InternalIP
  local node_ip
  node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  if [[ -z "$node_ip" ]]; then
    node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}' 2>/dev/null || true)
  fi
  if [[ -n "$node_ip" ]]; then
    echo "${node_ip}:${nodeport}"
  else
    echo ""
  fi
}

print_endpoints() {
  log "Discovering Prometheus & Grafana endpoints..."

  # Prometheus
  local prom_svc="kps-kube-prometheus-stack-prometheus"
  local prom_ep
  prom_ep=$(get_svc_external_ip monitoring "$prom_svc")
  if [[ -n "$prom_ep" ]]; then
    echo "Prometheus: http://${prom_ep}:9090"
  else
    local prom_np
    prom_np=$(get_svc_nodeport_fallback monitoring "$prom_svc" 'spec.ports[?(@.port==9090)].nodePort')
    if [[ -n "$prom_np" ]]; then
      echo "Prometheus (NodePort fallback): http://${prom_np}"
    else
      echo "Prometheus service found but no EXTERNAL-IP or NodePort. Try:"
      echo "  kubectl -n monitoring port-forward svc/${prom_svc} 9090:9090"
    fi
  fi

  # Grafana - Release creates <release>-grafana (kps-grafana)
  local graf_svc="kps-grafana"
  local graf_ep
  graf_ep=$(get_svc_external_ip monitoring "$graf_svc")
  if [[ -n "$graf_ep" ]]; then
    echo "Grafana:    http://${graf_ep}"
  else
    local graf_np
    graf_np=$(get_svc_nodeport_fallback monitoring "$graf_svc" 'spec.ports[?(@.port==80)].nodePort')
    if [[ -n "$graf_np" ]]; then
      echo "Grafana (NodePort fallback): http://${graf_np}"
    else
      echo "Grafana service found but no EXTERNAL-IP or NodePort. Try:"
      echo "  kubectl -n monitoring port-forward svc/${graf_svc} 3000:80"
      echo "  Then open http://localhost:3000 (admin / prom-operator)"
    fi
  fi
}

install_all() {
  ensure_helm_repos
  install_metrics_server
  install_kube_prometheus_stack

  log "Verifying monitoring namespace content:"
  kubectl -n monitoring get pods -o wide || true
  kubectl -n monitoring get svc -o wide || true

  print_endpoints

  cat <<EOF

[addons] Done.

- If you need to re-run just this step: ./scripts/addons-helm.sh install
- To view endpoints later:           ./scripts/addons-helm.sh status

Tip:
- It may take 1–3 minutes for LoadBalancer external IPs to be provisioned.
- If no EXTERNAL-IP appears, use the port-forward commands printed above.
EOF
}

case "${1:-}" in
  install)
    install_all
    ;;
  status)
    print_endpoints
    ;;
  *)
    echo "Usage: $0 {install|status}"
    exit 1
    ;;
esac