#!/bin/bash
# ci-local.sh - Simulate GitHub Actions locally for DOCR build/push/deploy

set -e

APP_IMAGE="registry.digitalocean.com/dokr-saas/doks-flask"
TAG=$(cat VERSION)

echo "=== Building Docker image ==="
docker build -t $APP_IMAGE:$TAG .

echo "=== Pushing to DOCR ==="
docker push $APP_IMAGE:$TAG

echo "=== Deploying to dev namespace ==="
kubectl -n dev set image deploy/doks-flask app=$APP_IMAGE:$TAG
kubectl -n dev rollout status deploy/doks-flask
