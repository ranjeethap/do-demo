#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Demo driver for DOKS + DOCR + Ingress + HPA + Promote to Prod
# ------------------------------------------------------------

# Optional .env
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a; source ./.env; set +a
fi

# --- Defaults (override via env or .env) ---
: "${APP_IMAGE:=registry.digitalocean.com/dokr-saas/doks-flask}"   # DOCR image
: "${DEV_NS:=dev}"
: "${PROD_NS:=prod}"
: "${ING_NS:=ingress-nginx}"
: "${ING_SVC:=ingress-nginx-controller}"

# Derive DOCR_REGISTRY (e.g., registry.digitalocean.com/dokr-saas) from APP_IMAGE if not set
if [[ -z "${DOCR_REGISTRY:-}" ]]; then
  DOCR_REGISTRY="$(echo "$APP_IMAGE" | awk -F/ '{print $1"/"$2}')"
fi

# --- Utilities ---
log() { printf "\n=== %s ===\n" "$*" >&2; }

get_ingress_addr() {
  # Find external IP/hostname; write to ./.ingress_addr and export ING_ADDR
  log "Waiting for external address of ${ING_NS}/${ING_SVC} ..."
  for i in {1..60}; do
    local addr
    addr="$(kubectl -n "$ING_NS" get svc "$ING_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' | tr -d ' ')"
    if [[ -n "$addr" ]]; then
      export ING_ADDR="$addr"
      printf 'export ING_ADDR=%s\n' "$addr" > ./.ingress_addr
      log "Found ingress address: $ING_ADDR"
      return 0
    fi
    sleep 5
  done
  echo "ERROR: Ingress external address not ready." >&2
  exit 1
}

render_manifests() {
  # Renders __ING_ADDR__ into dev/prod ingress manifests
  local out_dir="rendered"
  mkdir -p "$out_dir"

  if [[ -z "${ING_ADDR:-}" ]]; then
    echo "ING_ADDR not set; call get_ingress_addr first." >&2
    exit 1
  fi

  rm -f "$out_dir"/dev-*.yaml "$out_dir"/prod-*.yaml 2>/dev/null || true

  for f in scripts/manifests/dev-*.yaml scripts/manifests/prod-*.yaml; do
    [[ -f "$f" ]] || continue
    local base; base="$(basename "$f")"
    # Replace __ING_ADDR__ (and accept old {{ING_IP}} just in case)
    sed -e "s/__ING_ADDR__/${ING_ADDR}/g" -e "s/{{ING_IP}}/${ING_ADDR}/g" \
        "$f" > "$out_dir/$base"
  done

    if [[ "${VERBOSE:-0}" == "1" ]]; then
    echo "Rendered manifests written to $out_dir/:"
    ls -la "$out_dir"
  fi

}

ensure_namespace_and_pullsecret() {
  local ns="$1"
  local reg_name
  reg_name="$(basename "$DOCR_REGISTRY")"

  kubectl create ns "$ns" --dry-run=client -o yaml | kubectl apply -f -
  doctl registry kubernetes-manifest "$reg_name" --namespace "$ns" --name do-docr-secret | kubectl apply -f -
}

wait_ready_if_script() {
  # Optional helper: scripts/wait-ready.sh
  if [[ -x scripts/wait-ready.sh ]]; then
    ./scripts/wait-ready.sh "$@"
  fi
}

deploy_dev() {
  local ns="$DEV_NS"
  log "Deploying to namespace '$ns'"

  ensure_namespace_and_pullsecret "$ns"

  kubectl apply -f rendered/dev-deploy.yaml
  kubectl apply -f rendered/dev-svc.yaml
  kubectl apply -f rendered/dev-hpa.yaml || true
  kubectl apply -f rendered/dev-ingress.yaml

  # Set image on the actual deployment that serves traffic
  local deploy
  deploy="$(kubectl -n "$ns" get deploy -l app=doks-flask -o jsonpath='{.items[0].metadata.name}')"
  if [[ -z "$deploy" ]]; then
    echo "ERROR: No deployment with label app=doks-flask in ns=$ns" >&2
    kubectl -n "$ns" get deploy -o wide
    exit 1
  fi
  kubectl -n "$ns" set image "deployment/$deploy" app="$APP_IMAGE:${TAG:-latest}"
  kubectl -n "$ns" rollout status "deployment/$deploy" --timeout=300s
}

deploy_prod_basics() {
  local ns="$PROD_NS"
  log "Deploying base services/ingress to namespace '$ns'"

  ensure_namespace_and_pullsecret "$ns"

  # prod service & ingress (deploy may be a template managed differently)
  kubectl apply -f rendered/prod-svc.yaml
  kubectl apply -f rendered/prod-ingress.yaml
}

stamp_env_version() {
  local ns="$1"
  local value="$2" # e.g., commit SHA or friendly string
  local deploy
  deploy="$(kubectl -n "$ns" get deploy -l app=doks-flask -o jsonpath='{.items[0].metadata.name}')"
  if [[ -n "$deploy" ]]; then
    kubectl -n "$ns" set env "deploy/$deploy" APP_VERSION="$value"
    kubectl -n "$ns" rollout status "deploy/$deploy" --timeout=180s
  fi
}

urls() {
  echo "Dev URL : http://dev.${ING_ADDR}.sslip.io/"
  echo "Prod URL: http://app.${ING_ADDR}.sslip.io/"
}

# ------------------------------------------------------------
# Actions
#   up       : render + deploy dev + prod svc/ing; set image
#   promote  : update prod image + render/apply prod ingress + stamp version
#   status   : show URLs and images
#   down     : remove demo resources (keeps cluster/addons)
# ------------------------------------------------------------

case "${1:-}" in
  up)
    log "Bringing up demo stack"
    # Optional: install addons first if you have a script
    if [[ -x scripts/addons-helm.sh ]]; then
      scripts/addons-helm.sh
    fi

    # Ensure ingress address and render manifests
    get_ingress_addr
    render_manifests

    # Deploy dev and prod base (svc/ingress)
    deploy_dev
    deploy_prod_basics

    # Optionally wait for readiness (Prometheus/Grafana/etc.)
    wait_ready_if_script

    urls
    ;;

    promote)
    log "Promoting current DEV image to PROD"

    # Ensure we have ingress address for rendering
    if [[ -f ./.ingress_addr ]]; then
      # shellcheck disable=SC1091
      source ./.ingress_addr
    fi
    if [[ -z "${ING_ADDR:-}" ]]; then
      get_ingress_addr
    fi

    # Re-render manifests with current ingress address (quiet by default)
    render_manifests

    # Ensure prod namespace + DOCR pull secret
    ensure_namespace_and_pullsecret "$PROD_NS"

    # 1) Read the EXACT image currently running in dev
    DEV_DEPLOY=$(kubectl -n "$DEV_NS" get deploy -l app=doks-flask -o jsonpath='{.items[0].metadata.name}')
    if [[ -z "$DEV_DEPLOY" ]]; then
      echo "ERROR: No dev deployment found with label app=doks-flask" >&2
      exit 1
    fi
    DEV_IMAGE=$(kubectl -n "$DEV_NS" get deploy "$DEV_DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}')
    echo "Promoting image from dev: $DEV_IMAGE"

    # 2) Set prod to that exact image, no env stamping
    kubectl -n "$PROD_NS" set image deployment/doks-flask app="$DEV_IMAGE"
    kubectl -n "$PROD_NS" rollout status deployment/doks-flask --timeout=300s

    # 3) Apply rendered prod ingress (already has resolved host)
    kubectl apply -f rendered/prod-ingress.yaml

    urls
    ;;
  status)
    # Load cached ingress addr (if present); otherwise try to fetch quickly
    if [[ -f ./.ingress_addr ]]; then
      # shellcheck disable=SC1091
      source ./.ingress_addr
    else
      get_ingress_addr
    fi

    log "Dev status"
    kubectl -n "$DEV_NS" get deploy,svc,ing
    echo
    log "Prod status"
    kubectl -n "$PROD_NS" get deploy,svc,ing
    echo
    log "Live images (dev)"
    kubectl -n "$DEV_NS" get pods -l app=doks-flask -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.containers[0].image}{"\n"}{end}' || true
    echo
    log "Live images (prod)"
    kubectl -n "$PROD_NS" get pods -l app=doks-flask -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.containers[0].image}{"\n"}{end}' || true
    echo
    urls
    ;;

  down)
    log "Tearing down demo resources (namespaces: $DEV_NS, $PROD_NS)"
    # Keep ingress controller/addons; remove only app namespaces resources
    kubectl -n "$DEV_NS" delete deploy,svc,ing,hpa -l app=doks-flask --ignore-not-found
    kubectl -n "$PROD_NS" delete deploy,svc,ing -l app=doks-flask --ignore-not-found

    # (Optional) delete namespaces if you want a clean slate)
    # kubectl delete ns "$DEV_NS" --ignore-not-found
    # kubectl delete ns "$PROD_NS" --ignore-not-found

    echo "Done. You can run './demo.sh up' to recreate."
    ;;

  *)
    cat <<'USAGE'
Usage: ./demo.sh {up|promote|status|down}

Commands:
  up       - Install/upgrade addons (if scripts/addons-helm.sh exists), resolve ingress address,
             render manifests, deploy dev (deploy/svc/hpa/ingress) and prod (svc/ingress), set image, wait.
  promote  - Update prod deployment image to current APP_IMAGE:TAG (or :latest), render/apply prod ingress,
             and stamp APP_VERSION (commit SHA or datetime).
  status   - Show current objects and live image tags; print URLs.
  down     - Remove app resources from dev/prod (does not uninstall cluster-wide addons).
Notes:
  - Configure APP_IMAGE (and optionally DOCR_REGISTRY) via .env or environment variables.
  - Ingress hosts in ingress YAMLs must contain '__ING_ADDR__' (e.g., dev.__ING_ADDR__.sslip.io).
USAGE
    exit 1
    ;;
esac
