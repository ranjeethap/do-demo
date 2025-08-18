#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Config (override via .env or environment variables)
# ------------------------------------------------------------
DEV_NS="${DEV_NS:-dev}"
PROD_NS="${PROD_NS:-prod}"
APP_NAME="${APP_NAME:-doks-flask}"
APP_IMAGE="${APP_IMAGE:-}"        # optional; CI will set it, local builds can set too
REGISTRY_NAME="${REGISTRY_NAME:-dokr-saas}"  # DOCR registry name (for secrets)
PULL_SECRET_NAME="${PULL_SECRET_NAME:-do-docr-secret}"

# Load optional .env sitting next to this script
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
log() { printf "\n=== %s ===\n" "$*"; }
err() { printf "\n[ERROR] %s\n" "$*" >&2; }
here() { cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1; pwd; }

# Get current NGINX Ingress Controller external IP and persist it to ./.ingress_addr
get_ingress_addr() {
  local ip
  ip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  if [[ -z "${ip}" ]]; then
    err "No external IP on ingress-nginx/ingress-nginx-controller yet. Wait until it is provisioned."
    exit 1
  fi
  export ING_ADDR="$ip"
  printf 'ING_ADDR=%s\n' "$ING_ADDR" > ./.ingress_addr
  echo "Saved to ./.ingress_addr"
  echo "To use in your shell:  source ./.ingress_addr"
}

# Render manifests by substituting __ING_ADDR__ with current ingress IP
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

# Create namespace and ensure a DOCR imagePullSecret exists (requires you to be logged in with doctl)
ensure_namespace_and_pullsecret() {
  local ns="$1"
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns" >/dev/null

  log "Creating DOCR imagePullSecret in namespace '$ns' (registry: ${REGISTRY_NAME})"
  # Prefer doctl to produce a fresh dockerconfig (short-lived)
  if command -v doctl >/dev/null 2>&1; then
    tmp_docker_cfg="$(mktemp)"
    doctl registry docker-config --read-write --expiry-seconds 1800 > "$tmp_docker_cfg"
    kubectl -n "$ns" delete secret "${PULL_SECRET_NAME}" >/dev/null 2>&1 || true
    kubectl -n "$ns" create secret generic "${PULL_SECRET_NAME}" \
      --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson="$tmp_docker_cfg" >/dev/null
    rm -f "$tmp_docker_cfg"
  else
    # Fallback: if user logged in with docker already, reuse local docker config
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

urls() {
  if [[ -f ./.ingress_addr ]]; then
    # shellcheck disable=SC1091
    source ./.ingress_addr
  fi
  if [[ -z "${ING_ADDR:-}" ]]; then
    get_ingress_addr
  fi
  echo "Dev URL : http://dev.${ING_ADDR}.sslip.io/"
  echo "Prod URL: http://app.${ING_ADDR}.sslip.io/"
}

# ------------------------------------------------------------
# Actions
# ------------------------------------------------------------
case "${1:-}" in
  up)
    log "Bringing up demo stack"

    # 1) Render manifests with live ingress IP
    get_ingress_addr
    render_manifests

    # 2) Ensure DOCR pull secret in dev/prod
    ensure_namespace_and_pullsecret "$DEV_NS"
    ensure_namespace_and_pullsecret "$PROD_NS"

    # 3) Deploy Dev (Deployment/Service/HPA/Ingress)
    kubectl apply -f rendered/dev-deploy.yaml
    kubectl apply -f rendered/dev-svc.yaml
    kubectl apply -f rendered/dev-hpa.yaml
    kubectl apply -f rendered/dev-ingress.yaml

    # 4) Deploy Prod (Deployment template gets created by CI or by promote,
    #    but we put Service + Ingress to be ready)
    # If you already maintain a prod deployment, skip templated apply here.
    kubectl apply -f rendered/prod-svc.yaml
    kubectl apply -f rendered/prod-ingress.yaml || true

    urls
    ;;

  promote)
    log "Promoting current DEV image to PROD"

    # Make sure we have ingress IP (for printing URLs; not required for set image)
    if [[ -f ./.ingress_addr ]]; then
      # shellcheck disable=SC1091
      source ./.ingress_addr
    fi
    if [[ -z "${ING_ADDR:-}" ]]; then
      get_ingress_addr
    fi

    # Re-render prod ingress (in case IP changed)
    render_manifests
    ensure_namespace_and_pullsecret "$PROD_NS"

    # Read the exact image used in dev (container name: app)
    DEV_IMAGE=$(kubectl -n "$DEV_NS" get deploy/"$APP_NAME" \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="app")].image}')

    if [[ -z "$DEV_IMAGE" ]]; then
      err "Could not resolve image from dev deployment '$APP_NAME'. Aborting."
      exit 1
    fi
    log "Promoting image: $DEV_IMAGE"

    # Update prod deployment to use same image and wait for rollout
    kubectl -n "$PROD_NS" set image deployment/"$APP_NAME" app="$DEV_IMAGE" --record
    kubectl -n "$PROD_NS" rollout status deployment/"$APP_NAME" --timeout=300s

    # Re-apply prod ingress (just in case)
    kubectl apply -f rendered/prod-ingress.yaml

    urls
    ;;

  status)
    log "Status: images and endpoints"
    echo "[DEV]"
    kubectl -n "$DEV_NS" get deploy,svc,ingress -l app="$APP_NAME" -o wide
    echo
    echo "[PROD]"
    kubectl -n "$PROD_NS" get deploy,svc,ingress -l app="$APP_NAME" -o wide
    urls
    ;;

  down)
    log "Tearing down app resources (not deleting cluster)"
    kubectl -n "$DEV_NS" delete deploy,svc,ingress,hpa -l app="$APP_NAME" --ignore-not-found
    kubectl -n "$PROD_NS" delete deploy,svc,ingress,hpa -l app="$APP_NAME" --ignore-not-found
    echo "Note: namespaces, ingress controller, and cluster remain."
    ;;

  *)
    cat <<EOF
Usage: $0 {up|promote|status|down}

  up       - Render Ingress from live IP, ensure DOCR pull-secrets, deploy dev (deploy/svc/hpa/ingress) and prod (svc/ingress).
  promote  - Copy the exact image from dev deployment and roll it out to prod. Re-renders prod Ingress and prints URLs.
  status   - Show dev/prod deployments, services, ingress and print access URLs.
  down     - Delete dev/prod app resources (keeps namespaces and cluster).

Environment (override via .env or inline):
  DEV_NS            (default: dev)
  PROD_NS           (default: prod)
  APP_NAME          (default: doks-flask)
  APP_IMAGE         (optional; CI/local build sets this for dev deploys)
  REGISTRY_NAME     (default: dokr-saas) - DOCR registry name used to mint pull secrets
  PULL_SECRET_NAME  (default: do-docr-secret)
EOF
    exit 1
    ;;
esac