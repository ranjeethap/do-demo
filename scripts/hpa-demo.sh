#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-dev}"
DEPLOY="${DEPLOY:-doks-flask}"
SVC="${SVC:-doks-flask}"
HPA_NAME="${HPA_NAME:-doks-flask-hpa}"
LOAD_SECONDS="${LOAD_SECONDS:-90}"

log() { echo -e "\033[1;32m[hpa-demo]\033[0m $*"; }
err() { echo -e "\033[1;31m[hpa-demo][ERROR]\033[0m $*" >&2; }

get_ingress_ip() {
  # Use cached addr from demo.sh if present
  if [[ -f ./.ingress_addr ]]; then
    # shellcheck disable=SC1091
    source ./.ingress_addr || true
  fi
  if [[ -z "${ING_ADDR:-}" ]]; then
    local ip
    ip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "$ip" ]]; then
      export ING_ADDR="$ip"
    fi
  fi
}

check_prereqs() {
  log "Checking prerequisites in namespace: ${NS}"

  # Deployment
  if ! kubectl -n "${NS}" get deploy "${DEPLOY}" >/dev/null 2>&1; then
    err "Deployment '${DEPLOY}' not found in namespace '${NS}'."
    exit 1
  fi

  # HPA
  if ! kubectl -n "${NS}" get hpa "${HPA_NAME}" >/dev/null 2>&1; then
    log "HPA '${HPA_NAME}' not found. Applying scripts/manifests/dev-hpa.yaml..."
    if [[ -f scripts/manifests/dev-hpa.yaml ]]; then
      kubectl -n "${NS}" apply -f scripts/manifests/dev-hpa.yaml
    else
      err "Missing scripts/manifests/dev-hpa.yaml – cannot continue."
      exit 1
    fi
  fi

  # Metrics availability
  if ! kubectl top nodes >/dev/null 2>&1; then
    err "Metrics API not available. Ensure metrics-server is installed and ready."
    exit 1
  fi

  # CPU requests
  local req_cpu
  req_cpu=$(kubectl -n "${NS}" get deploy "${DEPLOY}" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || true)
  if [[ -z "${req_cpu:-}" ]]; then
    log "WARNING: Container in '${DEPLOY}' has no CPU request set. HPA on CPU won't scale."
    log "Consider patching the deployment to include CPU requests (e.g., 100m)."
  fi
}

loadgen_local_or_cluster() {
  # Prefer local 'hey' if available and ingress is reachable
  get_ingress_ip
  local dev_url
  dev_url="http://dev.${ING_ADDR:-}.sslip.io/"

  if command -v hey >/dev/null 2>&1 && [[ -n "${ING_ADDR:-}" ]]; then
    log "Starting local load with hey => ${dev_url}"
    log "(Duration: ${LOAD_SECONDS}s, QPS=20)"
    hey -z "${LOAD_SECONDS}s" -q 20 "${dev_url}" || true
    return
  fi

  # Fallback: create in-cluster load generator targeting the service
  log "Local 'hey' not available or ingress IP unknown."
  log "Starting in-cluster load generator against service '${SVC}' in namespace '${NS}'"

  # This creates a small burst of traffic for LOAD_SECONDS using curl in a busy loop
  kubectl -n "${NS}" delete deploy hpa-loadgen >/dev/null 2>&1 || true
  kubectl -n "${NS}" create deployment hpa-loadgen \
    --image=curlimages/curl:8.7.1 \
    -- /bin/sh -c "while true; do curl -s http://${SVC}.${NS}.svc.cluster.local/ > /dev/null; done"

  # Scale up load pods to intensify traffic
  kubectl -n "${NS}" scale deploy hpa-loadgen --replicas=3
  log "Loadgen running for ${LOAD_SECONDS}s ..."
  sleep "${LOAD_SECONDS}"

  # Tear down loadgen
  log "Removing loadgen ..."
  kubectl -n "${NS}" delete deploy hpa-loadgen --timeout=30s || true
}

watch_hpa() {
  log "Watching HPA '${HPA_NAME}' for scaling..."
  # Show current HPA state and then stream updates
  kubectl -n "${NS}" get hpa "${HPA_NAME}" -o wide || true
  # brief watch for the next 2 minutes
  timeout 120 kubectl -n "${NS}" watch get hpa "${HPA_NAME}" -o wide || true
}

main() {
  check_prereqs

  log "Current deployment status:"
  kubectl -n "${NS}" get deploy "${DEPLOY}" -o wide

  log "Generating load..."
  loadgen_local_or_cluster

  log "Post-load HPA state:"
  watch_hpa

  log "You can also run these manual checks:"
  echo "  kubectl -n ${NS} get hpa ${HPA_NAME} -o wide"
  echo "  kubectl -n ${NS} get deploy ${DEPLOY} -o wide"
  echo "  kubectl -n ${NS} top pods"
}

main "$@"