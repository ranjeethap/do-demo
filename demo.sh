#!/usr/bin/env bash
# =============================================================================
# One-Command DOKS Demo Orchestrator
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="${ROOT_DIR}/scripts"
MAN="${SCRIPTS}/manifests"

NS_DEV="dev"
NS_PROD="prod"
NS_MON="monitoring"
REGISTRY_DEFAULT="${REGISTRY:-dokr-saas}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 2; }; }
header() { echo -e "\n=== $* ===\n"; }

ingress_ip() {
  kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}

ensure_ns() { kubectl get ns "$1" >/dev/null 2>&1 || kubectl create ns "$1"; }

ensure_docr_secret() {
  local ns="$1" registry_name="${2:-$REGISTRY_DEFAULT}"

  # For your doctl, the syntax is:
  # doctl registry kubernetes-manifest <registry-name> --namespace <ns> [--name <secretName>]
  # We'll keep the secret name consistent across namespaces.
  header "Creating DOCR imagePullSecret in namespace '${ns}' (registry: ${registry_name})"

  doctl registry kubernetes-manifest "${registry_name}" \
    --namespace "${ns}" \
    --name "do-docr-secret" \
  | kubectl apply -f -
}

preflight_cleanup() {
  header "Preflight: cleaning up conflicting Helm releases & stray RBAC"
  for ns in "$NS_DEV" "flagger"; do
    if helm -n "$ns" list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "flagger"; then
      echo "Uninstalling 'flagger' in namespace: $ns"
      helm uninstall flagger -n "$ns" || true
    fi
  done
  if ! helm -n kube-system list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "sealed-secrets"; then
    for ns in "$NS_DEV" "$NS_PROD" "default"; do
      if helm -n "$ns" list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "sealed-secrets"; then
        echo "Uninstalling 'sealed-secrets' in namespace: $ns"
        helm uninstall sealed-secrets -n "$ns" || true
      fi
    done
  fi
  for cr in flagger sealed-secrets-controller secrets-unsealer; do
    if kubectl get clusterrole "$cr" >/dev/null 2>&1; then
      echo "Deleting stray ClusterRole/$cr"; kubectl delete clusterrole "$cr" || true
    fi
  done
  for crb in sealed-secrets-controller sealed-secrets-service-proxier; do
    if kubectl get clusterrolebinding "$crb" >/dev/null 2>&1; then
      echo "Deleting stray ClusterRoleBinding/$crb"; kubectl delete clusterrolebinding "$crb" || true
    fi
  done
}

install_addons() {
  header "Installing/Upgrading cluster add-ons (Helm)"
  bash "${SCRIPTS}/addons-helm.sh"
}

deploy_dev() {
  header "Deploying app to DEV (svc, deploy, hpa, ingress)"
  ensure_ns "$NS_DEV"
  ensure_docr_secret "$NS_DEV" "$REGISTRY_DEFAULT"

  kubectl apply -f "${MAN}/dev-svc.yaml"
  kubectl apply -f "${MAN}/dev-deploy.yaml"
  kubectl -n "$NS_DEV" rollout status deploy/doks-flask-primary --timeout=300s || true

  local ip; ip="$(ingress_ip || true)"
  local DEV_TMP; DEV_TMP="$(mktemp)"
  sed "s|{{ING_IP}}|${ip:-0.0.0.0}|g" "${MAN}/dev-ingress.yaml" > "${DEV_TMP}"
  echo "[debug] rendered dev ingress -> ${DEV_TMP}"; sed -n '1,80p' "${DEV_TMP}"
  kubectl apply -f "${DEV_TMP}"

  kubectl apply -f "${MAN}/dev-hpa.yaml"
  kubectl -n "$NS_DEV" get deploy,svc,ingress,hpa,pods -o wide
  echo "DEV URL:  http://dev.${ip:-<pending>}.sslip.io"
}

promote() {
  header "Promoting current DEV image to PROD"
  ensure_ns "$NS_PROD"
  ensure_docr_secret "$NS_PROD" "$REGISTRY_DEFAULT"

  kubectl apply -f "${MAN}/prod-svc.yaml"

  local dev_image
  dev_image="$(kubectl -n "$NS_DEV" get deploy doks-flask-primary -o jsonpath='{.spec.template.spec.containers[0].image}')" || true
  if [[ -z "${dev_image:-}" ]]; then
    echo "Could not obtain image from dev. Run './demo.sh up' first."; exit 3
  fi

  if ! kubectl -n "$NS_PROD" get deploy doks-flask >/dev/null 2>&1; then
    sed "s|__APP_IMAGE__|${dev_image}|g" "${MAN}/prod-deploy.tmpl.yaml" | kubectl apply -f -
  else
    kubectl -n "$NS_PROD" set image deploy/doks-flask app="${dev_image}" --record
  fi

  if kubectl -n "$NS_PROD" get ingress doks-flask-ing >/dev/null 2>&1; then
    echo "[cleanup] deleting old prod ingress doks-flask-ing"
    kubectl -n "$NS_PROD" delete ingress doks-flask-ing || true
  fi

  local ip; ip="$(ingress_ip || true)"
  local PROD_TMP; PROD_TMP="$(mktemp)"
  sed "s|{{ING_IP}}|${ip:-0.0.0.0}|g" "${MAN}/prod-ingress.yaml" > "${PROD_TMP}"
  echo "[debug] rendered prod ingress -> ${PROD_TMP}"; sed -n '1,80p' "${PROD_TMP}"
  kubectl apply -f "${PROD_TMP}"

  kubectl -n "$NS_PROD" rollout status deploy/doks-flask --timeout=300s || true
  kubectl -n "$NS_PROD" get deploy,svc,ingress,pods -o wide
  echo "PROD URL: http://app.${ip:-<pending>}.sslip.io"
}

_grafana_secret_name() {
  for s in kube-prometheus-stack-grafana kps-grafana grafana; do
    if kubectl -n "$NS_MON" get secret "$s" >/dev/null 2>&1; then echo "$s"; return; fi
  done
  echo ""
}

print_grafana_creds() {
  local sec; sec="$(_grafana_secret_name)"
  if [[ -z "$sec" ]]; then
    echo "Grafana secret not found in namespace '$NS_MON'. Is kube-prometheus-stack installed?"
    return 0
  fi
  local user pass
  user="$(kubectl -n "$NS_MON" get secret "$sec" -o jsonpath='{.data.admin-user}' | base64 --decode 2>/dev/null || echo admin)"
  pass="$(kubectl -n "$NS_MON" get secret "$sec" -o jsonpath='{.data.admin-password}' | base64 --decode 2>/dev/null || true)"
  echo "Grafana admin user:     ${user}"
  echo "Grafana admin password: ${pass}"
}

status() {
  header "Status Snapshot"
  kubectl get ns
  kubectl -n ingress-nginx get svc ingress-nginx-controller || true
  kubectl -n "$NS_DEV"  get deploy,svc,ingress,hpa,pods -o wide || true
  kubectl -n "$NS_PROD" get deploy,svc,ingress,pods -o wide || true
  local ip; ip="$(ingress_ip || true)"
  echo "Ingress IP: ${ip:-<pending>}"
  echo "DEV URL:  http://dev.${ip:-<pending>}.sslip.io"
  echo "PROD URL: http://app.${ip:-<pending>}.sslip.io"
  echo
  echo "Grafana:    http://localhost:3000   (run: ./demo.sh grafana)"
  echo "Prometheus: http://localhost:9090   (run: ./demo.sh prometheus)"
  print_grafana_creds
}

grafana_pf() {
  header "Port-forwarding Grafana on :3000 (Ctrl+C to stop)"
  if kubectl -n "$NS_MON" get svc kps-grafana >/dev/null 2>&1; then
    kubectl -n "$NS_MON" port-forward svc/kps-grafana 3000:80
  elif kubectl -n "$NS_MON" get svc kube-prometheus-stack-grafana >/dev/null 2>&1; then
    kubectl -n "$NS_MON" port-forward svc/kube-prometheus-stack-grafana 3000:80
  else
    echo "Grafana service not found in namespace '$NS_MON'"
    exit 1
  fi
}

prometheus_pf() {
  header "Port-forwarding Prometheus on :9090 (Ctrl+C to stop)"
  if kubectl -n "$NS_MON" get svc kps-kube-prometheus-stack-prometheus >/dev/null 2>&1; then
    kubectl -n "$NS_MON" port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
  elif kubectl -n "$NS_MON" get svc kube-prometheus-stack-prometheus >/dev/null 2>&1; then
    kubectl -n "$NS_MON" port-forward svc/kube-prometheus-stack-prometheus 9090:9090
  else
    echo "Prometheus service not found in namespace '$NS_MON'"
    exit 1
  fi
}

hpa_demo() {
  header "HPA Demo (dev)"
  local dev_host
  dev_host="$(kubectl -n "$NS_DEV" get ingress doks-flask -o jsonpath='{.spec.rules[0].host}')" || true
  if [[ -z "${dev_host:-}" ]]; then echo "Dev ingress not ready"; exit 3; fi

  echo "Generating load against http://${dev_host} for ~90s and watching HPA..."
  kubectl -n "$NS_DEV" run loadgen --rm -it --image=busybox --restart=Never -- \
    /bin/sh -c "for i in \$(seq 1 900); do wget -q -O- http://${dev_host} >/dev/null; done" &

  kubectl -n "$NS_DEV" get hpa -w
}

tear_down() {
  header "Removing app resources (keeps cluster & add-ons)"
  local ip; ip="$(ingress_ip || true)"

  [[ -n "${ip:-}" ]] && sed "s|{{ING_IP}}|${ip}|g" "${MAN}/dev-ingress.yaml" | kubectl delete -f - --ignore-not-found
  kubectl -n "$NS_DEV" delete -f "${MAN}/dev-hpa.yaml" --ignore-not-found
  kubectl -n "$NS_DEV" delete -f "${MAN}/dev-deploy.yaml" --ignore-not-found
  kubectl -n "$NS_DEV" delete -f "${MAN}/dev-svc.yaml" --ignore-not-found

  [[ -n "${ip:-}" ]] && sed "s|{{ING_IP}}|${ip}|g" "${MAN}/prod-ingress.yaml" | kubectl delete -f - --ignore-not-found
  kubectl -n "$NS_PROD" delete deploy/doks-flask --ignore-not-found
  kubectl -n "$NS_PROD" delete -f "${MAN}/prod-svc.yaml" --ignore-not-found
}

destroy() {
  header "Destroy everything installed by the demo (safe defaults)"
  kubectl delete ns dev prod --ignore-not-found

  helm uninstall ingress-nginx -n ingress-nginx || true
  helm uninstall kps -n monitoring || true
  helm uninstall kube-prometheus-stack -n monitoring || true
  helm uninstall cert-manager -n cert-manager || true
  helm uninstall sealed-secrets -n kube-system || true
  helm uninstall flagger -n flagger || true
  helm uninstall metrics-server -n kube-system || true

  kubectl delete ns monitoring cert-manager ingress-nginx flagger --ignore-not-found

  echo "[info] Cluster & registry are left intact by default."
  if [[ "${DELETE_REGISTRY:-false}" == "true" ]]; then
    echo "[danger] Deleting DOCR registry (global for team!)"
    doctl registry delete --force || true
  fi
  if [[ -n "${CLUSTER_NAME:-}" && "${DELETE_CLUSTER:-false}" == "true" ]]; then
    echo "[danger] Deleting cluster ${CLUSTER_NAME}"
    doctl kubernetes cluster delete "${CLUSTER_NAME}" --force
  fi
  echo "[done] destroy complete"
}

need kubectl; need helm; need doctl; need sed

ACTION="${1:-help}"
case "$ACTION" in
  up)
    preflight_cleanup
    install_addons

    # --- BEGIN: optional clean reset of app namespaces ---
    if [[ "${SKIP_NS_RESET:-false}" != "true" ]]; then
      header "Resetting app namespaces (dev/prod) to avoid immutable selector conflicts"
      kubectl delete ns dev prod --ignore-not-found
      kubectl create ns dev
      kubectl create ns prod
    else
      header "Skipping namespace reset (SKIP_NS_RESET=true)"
      kubectl get ns dev prod || true
    fi
    # --- END: optional clean reset ---

    # If you have wait-ready.sh, keep this just before deploying the app
    bash "${SCRIPTS}/wait-ready.sh" || true

    deploy_dev
    ;;
  wait-ready) bash "${SCRIPTS}/wait-ready.sh" ;;
  promote)     promote ;;
  status)      status ;;
  grafana)     grafana_pf ;;
  prometheus)  prometheus_pf ;;
  hpa-demo)    hpa_demo ;;
  down)        tear_down ;;
  destroy)     destroy ;;
  *) echo "Usage: $0 {up|promote|status|grafana|prometheus|hpa-demo|down|destroy|wait-ready}"; exit 1 ;;
esac
