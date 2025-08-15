#!/usr/bin/env bash
set -euo pipefail
NS="${NS:-dev}"
APP_IMAGE="${APP_IMAGE:-registry.digitalocean.com/dokr-saas/doks-flask}"
TAG="${TAG:-v2}"
LOAD_SECONDS="${LOAD_SECONDS:-90}"

usage(){ echo "Usage: $0 {build|push|rollout|status|abort}  (env: NS, APP_IMAGE, TAG, LOAD_SECONDS)"; exit 1; }
cmd="${1:-}"; [[ -z "$cmd" ]] && usage

build() {
  echo "== Build V2 image =="
  docker build --build-arg APP_VERSION=v2 -t "${APP_IMAGE}:${TAG}" -t "${APP_IMAGE}:latest" app/
}

push() {
  echo "== Push V2 image =="
  doctl registry login
  docker push "${APP_IMAGE}:${TAG}"
  docker push "${APP_IMAGE}:latest"
}

rollout() {
  echo "== Start Canary (Flagger) =="
  kubectl -n "$NS" set image deploy/doks-flask app="${APP_IMAGE}:${TAG}"
  HOST="$(kubectl -n "$NS" get ingress doks-flask -o jsonpath='{.spec.rules[0].host}')"
  echo "Generating load against http://${HOST} for ~${LOAD_SECONDS}s ..."
  kubectl -n "$NS" run loadgen --rm -it --image=busybox --restart=Never -- \
    /bin/sh -c "for i in \$(seq 1 ${LOAD_SECONDS}); do wget -q -O- http://${HOST} >/dev/null; done"
}

status() {
  kubectl -n "$NS" describe canary/doks-flask | sed -n '1,150p' || true
  kubectl -n "$NS" get deploy,rs,svc | grep doks-flask || true
}

abort() {
  echo "== Abort Canary (rollback to primary) =="
  kubectl -n "$NS" annotate canary/doks-flask flagger.app/skip-analysis=true --overwrite || true
}

case "$cmd" in
  build) build ;; push) push ;; rollout) rollout ;; status) status ;; abort) abort ;;
  *) usage ;;
esac
