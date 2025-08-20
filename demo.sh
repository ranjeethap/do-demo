#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Config (override via .env or environment variables)
# ------------------------------------------------------------
DEV_NS="${DEV_NS:-dev}"
PROD_NS="${PROD_NS:-prod}"
APP_NAME="${APP_NAME:-doks-flask}"          # The Kubernetes deployment/service/labels expect this
PULL_SECRET_NAME="${PULL_SECRET_NAME:-do-docr-secret}"
REGISTRY_NAME="${REGISTRY_NAME:-dokr-saas}" # DOCR registry name (Settings > Container Registry)
APP_IMAGE="${APP_IMAGE:-}"                  # Optional: set for DEV replacement image during "./demo.sh up"

# Load optional .env next to this script
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

# ------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------
log()  { printf "\n\033[1;32m=== %s ===\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[WARN] %s\033[0m\n" "$*"; }
err()  { printf "\n\033[1;31m[ERROR] %s\033[0m\n" "$*" >&2; }

# ------------------------------------------------------------
# Generic helpers
# ------------------------------------------------------------
wait_for() {
  local sec="${1:-60}"; shift || true
  local start ts
  start=$(date +%s)
  while true; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    ts=$(( $(date +%s) - start ))
    if (( ts >= sec )); then return 1; fi
    sleep 2
  done
}

# ------------------------------------------------------------
# Addons: ingress-nginx, metrics-server, monitoring (kube-prometheus-stack)
# ------------------------------------------------------------
ensure_addons() {
  if [[ -x scripts/addons-helm.sh ]]; then
    log "Installing/Validating cluster addons (ingress, metrics-server, monitoring)"
    scripts/addons-helm.sh
  else
    warn "scripts/addons-helm.sh missing or not executable. Skipping addon setup."
  fi
}

# ------------------------------------------------------------
# Ingress bootstrap + IP discovery
# ------------------------------------------------------------
ensure_ingress() {
  if ! kubectl get ns ingress-nginx >/dev/null 2>&1; then
    log "Installing ingress-nginx (namespace not found)"
    if command -v helm >/dev/null 2>&1; then
      helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
      helm repo update >/dev/null
      helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        -n ingress-nginx --create-namespace \
        --set controller.publishService.enabled=true \
        --wait --timeout 10m
    else
      warn "Helm not available; using upstream manifest"
      kubectl create ns ingress-nginx >/dev/null 2>&1 || true
      kubectl apply -n ingress-nginx -f \
        https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
      log "Waiting for ingress-nginx controller to be ready..."
      kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=10m
    fi
  fi

  log "Ensuring ingress-nginx has an external IP"
  if ! kubectl -n ingress-nginx get svc ingress-nginx-controller >/dev/null 2>&1; then
    err "ingress-nginx service missing; check controller install"
    exit 1
  fi

  if ! wait_for 600 kubectl -n ingress-nginx get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; then
    err "Timed out waiting for ingress-nginx external IP"
    exit 1
  fi
}

get_ingress_addr() {
  ensure_ingress
  local ip
  ip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  if [[ -z "${ip}" ]]; then
    err "No external IP on ingress-nginx/ingress-nginx-controller yet."
    exit 1
  fi
  export ING_ADDR="$ip"
  printf 'ING_ADDR=%s\n' "$ING_ADDR" > ./.ingress_addr
  echo "Saved to ./.ingress_addr"
  echo "To use in your shell:  source ./.ingress_addr"
}

# ------------------------------------------------------------
# Render manifests (replace __ING_ADDR__ with current LB IP)
# ------------------------------------------------------------
render_manifests() {
  if [[ -f ./.ingress_addr ]]; then
    # shellcheck disable=SC1091
    source ./.ingress_addr
  fi
  if [[ -z "${ING_ADDR:-}" ]]; then
    get_ingress_addr
  fi

  mkdir -p rendered
  sed "s/__ING_ADDR__/${ING_ADDR}/g" scripts/manifests/dev-ingress.yaml  > rendered/dev-ingress.yaml
  sed "s/__ING_ADDR__/${ING_ADDR}/g" scripts/manifests/prod-ingress.yaml > rendered/prod-ingress.yaml
  cp scripts/manifests/dev-deploy.yaml          rendered/dev-deploy.yaml
  cp scripts/manifests/dev-svc.yaml             rendered/dev-svc.yaml
  cp scripts/manifests/dev-hpa.yaml             rendered/dev-hpa.yaml
  cp scripts/manifests/prod-deploy.tmpl.yaml    rendered/prod-deploy.tmpl.yaml
  cp scripts/manifests/prod-svc.yaml            rendered/prod-svc.yaml

  log "Rendered manifests written to rendered/:"
  ls -la rendered
}

# ------------------------------------------------------------
# Create namespace + DOCR imagePullSecret
# ------------------------------------------------------------
ensure_namespace_and_pullsecret() {
  local ns="$1"
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns" >/dev/null

  log "Creating DOCR imagePullSecret in namespace '$ns' (registry: ${REGISTRY_NAME})"
  if command -v doctl >/dev/null 2>&1; then
    local tmp_docker_cfg
    tmp_docker_cfg="$(mktemp)"
    doctl registry docker-config --read-write --expiry-seconds 1800 > "$tmp_docker_cfg"
    kubectl -n "$ns" delete secret "${PULL_SECRET_NAME}" >/dev/null 2>&1 || true
    kubectl -n "$ns" create secret generic "${PULL_SECRET_NAME}" \
      --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson="$tmp_docker_cfg" >/dev/null
    rm -f "$tmp_docker_cfg"
  else
    if [[ -f "$HOME/.docker/config.json" ]]; then
      kubectl -n "$ns" delete secret "${PULL_SECRET_NAME}" >/dev/null 2>&1 || true
      kubectl -n "$ns" create secret generic "${PULL_SECRET_NAME}" \
        --type=kubernetes.io/dockerconfigjson \
        --from-file=.dockerconfigjson="$HOME/.docker/config.json" >/dev/null
    else
      err "Neither doctl nor a local docker config found to create image pull secret."
      exit 1
    fi
  fi

  # Patch default service account to use imagePullSecret by default
  kubectl -n "$ns" patch serviceaccount default \
    -p "{\"imagePullSecrets\":[{\"name\":\"${PULL_SECRET_NAME}\"}]}" >/dev/null || true
}

# ------------------------------------------------------------
# Useful printers
# ------------------------------------------------------------
urls() {
  if [[ -f ./.ingress_addr ]]; then
    # shellcheck disable=SC1091
    source ./.ingress_addr || true
  fi
  if [[ -z "${ING_ADDR:-}" ]]; then
    get_ingress_addr
  fi
  echo "Dev URL : http://dev.${ING_ADDR}.sslip.io/"
  echo "Prod URL: http://app.${ING_ADDR}.sslip.io/"
}

print_monitoring_endpoints() {
  local MON_NS="monitoring"
  echo
  echo "=== Monitoring Endpoints ==="
  if kubectl get ns "${MON_NS}" >/dev/null 2>&1; then
    local GRAFANA_IP PROM_IP
    GRAFANA_IP=$(kubectl -n "${MON_NS}" get svc grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    PROM_IP=$(kubectl -n "${MON_NS}" get svc kps-kube-prometheus-stack-prometheus -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

    if [[ -n "${GRAFANA_IP:-}" ]]; then
      echo "Grafana:    http://${GRAFANA_IP}/  (admin / admin or your custom)"
    else
      echo "Grafana:    pending (ensure kube-prometheus-stack installed)"
    fi

    if [[ -n "${PROM_IP:-}" ]]; then
      echo "Prometheus: http://${PROM_IP}/"
    else
      echo "Prometheus: pending (ensure kube-prometheus-stack installed)"
    fi

    echo "Local port-forward options (if no LB IP assigned):"
    echo "  kubectl -n ${MON_NS} port-forward svc/grafana 3000:80"
    echo "  kubectl -n ${MON_NS} port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090"
  else
    echo "Monitoring namespace not found. Install kube-prometheus-stack first."
  fi
}

show_status() {
  log "Demo Status"
  local ingress_ip
  ingress_ip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -z "${ingress_ip:-}" && -f ./.ingress_addr ]]; then
    # shellcheck disable=SC1091
    source ./.ingress_addr || true
    ingress_ip="${ING_ADDR:-}"
  fi

  echo "Ingress IP: ${ingress_ip:-pending}"
  [[ -n "${ingress_ip:-}" ]] && {
    echo "Dev URL : http://dev.${ingress_ip}.sslip.io/"
    echo "Prod URL: http://app.${ingress_ip}.sslip.io/"
  }

  print_monitoring_endpoints

  echo
  echo "--- Metrics snapshot (if ready) ---"
  kubectl top nodes || echo "Metrics not ready yet (expected shortly)"

  echo
  echo "[DEV]"
  kubectl -n "$DEV_NS" get deploy,svc,ingress -l app="$APP_NAME" -o wide || true
  echo
  echo "[PROD]"
  kubectl -n "$PROD_NS" get deploy,svc,ingress -l app="$APP_NAME" -o wide || true
}

# ------------------------------------------------------------
# Actions
# ------------------------------------------------------------
case "${1:-}" in
  up)
    log "Bringing up demo stack"
    ensure_addons
    get_ingress_addr
    render_manifests
    ensure_namespace_and_pullsecret "$DEV_NS"

    kubectl -n "$DEV_NS" apply -f rendered/dev-deploy.yaml
    kubectl -n "$DEV_NS" apply -f rendered/dev-svc.yaml
    kubectl -n "$DEV_NS" apply -f rendered/dev-hpa.yaml || true
    kubectl -n "$DEV_NS" apply -f rendered/dev-ingress.yaml

    # If you pass APP_IMAGE, force the dev deployment to that image
    if [[ -n "${APP_IMAGE}" ]]; then
      log "Overriding DEV image to ${APP_IMAGE}"
      kubectl -n "$DEV_NS" set image deploy/"$APP_NAME" app="${APP_IMAGE}"
    fi

    kubectl -n "$DEV_NS" rollout status deploy/"$APP_NAME" --timeout=300s
    urls
    ;;

  promote)
    log "Promoting current DEV image to PROD"

    # Ingress IP (for URLs)
    if [[ -f ./.ingress_addr ]]; then source ./.ingress_addr || true; fi
    if [[ -z "${ING_ADDR:-}" ]]; then get_ingress_addr; fi

    render_manifests
    ensure_namespace_and_pullsecret "$PROD_NS"

    # Resolve the exact DEV image (container must be 'app')
    DEV_IMAGE=$(kubectl -n "$DEV_NS" get deploy/"$APP_NAME" \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="app")].image}')
    if [[ -z "$DEV_IMAGE" ]]; then
      err "Could not resolve image from dev deployment '$APP_NAME'. Aborting."
      exit 1
    fi
    log "Promoting image: ${DEV_IMAGE}"

    # Create prod deploy from template if missing
    if ! kubectl -n "$PROD_NS" get deploy "$APP_NAME" >/dev/null 2>&1; then
      log "Prod deployment '$APP_NAME' not found - creating from template"
      kubectl -n "$PROD_NS" apply -f rendered/prod-deploy.tmpl.yaml
      # Add DOCR pull secret to pod spec
      kubectl -n "$PROD_NS" patch deployment "$APP_NAME" --type='json' -p="[
        {\"op\":\"add\",\"path\":\"/spec/template/spec/imagePullSecrets\",\"value\":[{\"name\":\"$PULL_SECRET_NAME\"}]}
      ]" || true
    fi

    kubectl -n "$PROD_NS" set image deployment/"$APP_NAME" app="$DEV_IMAGE"
    kubectl -n "$PROD_NS" rollout status deployment/"$APP_NAME" --timeout=300s

    kubectl apply -f rendered/prod-ingress.yaml
    urls
    ;;

  status)
    show_status
    ;;

  down)
    log "Tearing down app resources (keeps cluster)"
    kubectl -n "$DEV_NS"  delete deploy,svc,ingress,hpa -l app="$APP_NAME" --ignore-not-found
    kubectl -n "$PROD_NS" delete deploy,svc,ingress,hpa -l app="$APP_NAME" --ignore-not-found
    echo "Namespaces, ingress controller, and cluster remain intact."
    ;;

  *)
    cat <<EOF
Usage: $0 {up|promote|status|down}

up       - Install addons, render ingress with live IP, create DOCR pull-secrets, deploy dev (deploy/svc/hpa/ingress).
promote  - Copy the exact image from dev deployment and roll it out to prod. Re-renders prod Ingress and prints URLs.
status   - Show dev/prod deployments/services/ingress, monitoring endpoints, and a metrics snapshot.
down     - Delete dev/prod app resources (keeps namespaces, ingress controller, and cluster).

Environment (override via .env or inline):
  DEV_NS            (default: dev)
  PROD_NS           (default: prod)
  APP_NAME          (default: doks-flask)
  APP_IMAGE         (optional; CI/local build sets this for dev deploys)
  REGISTRY_NAME     (default: dokr-saas)  # DOCR registry name used to mint pull secrets
  PULL_SECRET_NAME  (default: do-docr-secret)
EOF
    exit 1
    ;;
esac