#!/usr/bin/env bash
set -euo pipefail
NS="${NS:-dev}"
DEPLOY="${DEPLOY:-doks-flask-primary}"
APP_IMAGE="${APP_IMAGE:-registry.digitalocean.com/dokr-saas/doks-flask}"
TAG="${TAG:-roll1}"

usage(){ echo "Usage: $0 {build|push|update|status|undo}  (env: NS, DEPLOY, APP_IMAGE, TAG)"; exit 1; }
cmd="${1:-}"; [[ -z "$cmd" ]] && usage

build(){
  echo "== Build image for rolling update =="
  docker build --build-arg APP_VERSION=${TAG} -t "${APP_IMAGE}:${TAG}" app/
}

push(){
  echo "== Push image =="
  doctl registry login
  docker push "${APP_IMAGE}:${TAG}"
}

update(){
  echo "== Rolling update ${DEPLOY} to ${APP_IMAGE}:${TAG} =="
  kubectl -n "$NS" set image deploy/${DEPLOY} app="${APP_IMAGE}:${TAG}" --record
  kubectl -n "$NS" rollout status deploy/${DEPLOY} --timeout=300s
}

status(){
  kubectl -n "$NS" get deploy/${DEPLOY} || true
  kubectl -n "$NS" rollout status deploy/${DEPLOY} || true
  kubectl -n "$NS" describe deploy/${DEPLOY} | sed -n '1,120p' || true
}

undo(){
  echo "== Rollback to previous ReplicaSet =="
  kubectl -n "$NS" rollout undo deploy/${DEPLOY}
  kubectl -n "$NS" rollout status deploy/${DEPLOY} --timeout=300s
}

case "$cmd" in
  build) build ;; push) push ;; update) update ;; status) status ;; undo) undo ;;
  *) usage ;;
esac
