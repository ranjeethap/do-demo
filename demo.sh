#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Demo driver for DOKS + DOCR + Ingress + HPA + Promote to Prod
# ------------------------------------------------------------

# Optional .env (e.g. APP_IMAGE=registry.digitalocean.com/<registry>/<repo>)
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
  # Render __ING_ADDR__ into dev/prod ingress manifests
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
    sed -e "s/__ING_ADDR__/${ING_ADDR}/g" -e "s/{{ING_IP}}/${ING_ADDR}/g" \
        "$f" > "$out_dir/$base"
  done

  # copy prod-deploy template as-is (image replaced at promote time)
  if [[ -f scripts/manifests/prod-deploy.tmpl.yaml ]]; then
    cp scripts/manifests/prod-deploy.tmpl.yaml "$out_dir/prod-deploy.tmpl.yaml"
  fi

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

  # Make default SA use the pull secret implicitly
  kubectl -n "$ns" patch serviceaccount default \
    --type merge \
    -p '{"imagePullSecrets":[{"name":"do-docr-secret"}]}' >/dev/null 2>&1 || true
}

wait_ready_if_script() {
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

  # Detect the actual deployment name (label-based)
  local deploy
  deploy="$(kubectl -n "$ns" get deploy -l app=doks-flask -o jsonpath='{.items[0].metadata.name}')"
  if [[ -z "$deploy" ]]; then
    echo "ERROR: No deployment with label app=doks-flask in ns=$ns" >&2
    kubectl -n "$ns" get deploy -o wide
    exit 1
  fi

  # Deploy the requested image; do not set APP_VERSION env (let app.py decide)
  kubectl -n "$ns" set image "deployment/$deploy" app="$APP_IMAGE:${TAG:-latest}"
  # Ensure no stray APP_VERSION forced at the deployment level
  kubectl -n "$ns" set env "deployment/$deploy" APP_VERSION- || true

  kubectl -n "$ns" rollout status "deployment/$deploy" --timeout=300s
}

deploy_prod_basics() {
  local ns="$PROD_NS"
  log "Deploying base services/ingress to namespace '$ns'"

  ensure_namespace_and_pullsecret "$ns"
  kubectl apply -f rendered/prod-svc.yaml
  kubectl apply -f rendered/prod-ingress.yaml
}

create_prod_deploy_if_missing() {
  local ns="$PROD_NS" image="$1"
  if ! kubectl -n "$ns" get deploy doks-flask >/dev/null 2>&1; then
    log "Prod deployment not found; creating from template with image: $image"
    if [[ -f rendered/prod-deploy.tmpl.yaml ]]; then
      sed "s#__APP_IMAGE__#${image}#g" rendered/prod-deploy.tmpl.yaml | kubectl apply -f -
    else
      # Minimal fallback (if template missing)
      cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: doks-flask
  namespace: ${ns}
  labels: { app: doks-flask }
spec:
  replicas: 3
  selector: { matchLabels: { app: doks-flask } }
  template:
    metadata: { labels: { app: doks-flask } }
    spec:
      imagePullSecrets:
      - name: do-docr-secret
      containers:
      - name: app
        image: ${image}
        imagePullPolicy: Always
        ports: [{ containerPort: 8080, name: http }]
        resources:
          requests: { cpu: "150m", memory: "192Mi" }
          limits:   { cpu: "600m", memory: "384Mi" }
EOF
    fi
  fi
}

urls() {
  echo "Dev URL : http://dev.${ING_ADDR}.sslip.io/"
  echo "Prod URL: http://app.${ING_ADDR}.sslip.io/"
}

case "${1:-}" in
  up)
    log "Bringing up demo stack"
    if [[ -x scripts/addons-helm.sh ]]; then
      scripts/addons-helm.sh
    fi
    get_ingress_addr
    render_manifests
    deploy_dev
    deploy_prod_basics
    wait_ready_if_script
    urls
    ;;

  promote)
    log "Promoting current DEV image to PROD"
    [[ -f ./.ingress_addr ]] && source ./.ingress_addr
    [[ -z "${ING_ADDR:-}" ]] && get_ingress_addr
    render_manifests
    ensure_namespace_and_pullsecret "$PROD_NS"

    # Read EXACT image from dev and promote it
    DEV_DEPLOY=$(kubectl -n "$DEV_NS" get deploy -l app=doks-flask -o jsonpath='{.items[0].metadata.name}')
    DEV_IMAGE=$(kubectl -n "$DEV_NS" get deploy "$DEV_DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}')
    echo "Promoting image from dev: $DEV_IMAGE"

    create_prod_deploy_if_missing "$DEV_IMAGE"
    kubectl -n "$PROD_NS" set image deployment/doks-flask app="$DEV_IMAGE"
    # Ensure no forced APP_VERSION in prod either
    kubectl -n "$PROD_NS" set env deployment/doks-flask APP_VERSION- || true

    kubectl -n "$PROD_NS" rollout status deployment/doks-flask --timeout=300s
    kubectl apply -f rendered/prod-ingress.yaml
    urls
    ;;

  status)
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
    kubectl -n "$DEV_NS" delete deploy,svc,ing,hpa -l app=doks-flask --ignore-not-found
    kubectl -n "$PROD_NS" delete deploy,svc,ing -l app=doks-flask --ignore-not-found
    echo "Done. Run './demo.sh up' to recreate."
    ;;

  *)
    cat <<'USAGE'
Usage: ./demo.sh {up|promote|status|down}

Tip:
- Edit app/app.py message locally, build&push image to DOCR, then:
    ./demo.sh up        # deploy/update dev and base prod
    ./demo.sh promote   # roll the exact dev image to prod
USAGE
    exit 1
    ;;
esac