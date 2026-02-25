#!/bin/bash

# === Input Validation ===
if [ -z "$1" ]; then
  echo "❌ Usage: $0 <env-prefix> (e.g., qa, dev, prod, internal)"
  exit 1
fi

# === Dynamic Prefix ===
ENV_PREFIX=$1

# === Namespace and Release Name ===
NAMESPACE="${ENV_PREFIX}"
REDIS_RELEASE_NAME="lt-${ENV_PREFIX}-redis-ha"

# === Local Custom Chart ===
CHART_PATH="./redis-ha"

# === Optional Overrides ===
REDIS_REPLICAS="${REDIS_REPLICAS:-2}"
EXPECTED_PODS="${EXPECTED_PODS:-$REDIS_REPLICAS}"
REDIS_PORT="${REDIS_PORT:-6379}"
HAPROXY_REPLICAS="${HAPROXY_REPLICAS:-1}"
HAPROXY_SERVICE_TYPE="${HAPROXY_SERVICE_TYPE:-LoadBalancer}"
HAPROXY_SERVICE_LB_IP="${HAPROXY_SERVICE_LB_IP:-}"
REDIS_INGRESS_HOST="mylocal.com"

REDIS_IMAGE_REPOSITORY="${REDIS_IMAGE_REPOSITORY:-public.ecr.aws/docker/library/redis}"
REDIS_IMAGE_TAG="${REDIS_IMAGE_TAG:-8.2.4-alpine}"
EXPORTER_IMAGE="${EXPORTER_IMAGE:-quay.io/oliver006/redis_exporter}"
EXPORTER_TAG="${EXPORTER_TAG:-v1.80.2}"

# === Redis-HA Helm Install Command from Local Chart ===
HELM_ARGS=(
  --set replicas="$REDIS_REPLICAS"
  --set auth=false
  --set sentinel.auth=false
  --set exporter.enabled=true
  --set haproxy.enabled=true
  --set haproxy.replicas="$HAPROXY_REPLICAS"
  --set haproxy.service.type="$HAPROXY_SERVICE_TYPE"
  --set haproxy.servicePort="$REDIS_PORT"
  --set image.repository="$REDIS_IMAGE_REPOSITORY"
  --set image.tag="$REDIS_IMAGE_TAG"
  --set exporter.image="$EXPORTER_IMAGE"
  --set exporter.tag="$EXPORTER_TAG"
  --set redis.resources.requests.cpu=100m
  --set redis.resources.requests.memory=256Mi
  --set redis.resources.limits.cpu=500m
  --set redis.resources.limits.memory=512Mi
  --set persistentVolume.size=3Gi
  --set hardAntiAffinity=false
  --set haproxy.hardAntiAffinity=false
  --set tolerations[0].key=node-role.kubernetes.io/control-plane
  --set tolerations[0].operator=Exists
  --set tolerations[0].effect=NoSchedule
  --set tolerations[1].key=node-role.kubernetes.io/master
  --set tolerations[1].operator=Exists
  --set tolerations[1].effect=NoSchedule
)

if [ -n "$HAPROXY_SERVICE_LB_IP" ]; then
  HELM_ARGS+=(--set "haproxy.service.loadBalancerIP=$HAPROXY_SERVICE_LB_IP")
fi

if [ -n "$REDIS_INGRESS_HOST" ]; then
  HELM_ARGS+=(--set-string "haproxy.service.annotations.external-dns\\.alpha\\.kubernetes\\.io/hostname=$REDIS_INGRESS_HOST")
fi

helm upgrade --install "$REDIS_RELEASE_NAME" "$CHART_PATH" \
  -n "$NAMESPACE" --create-namespace \
  "${HELM_ARGS[@]}"

  # --set exporter.serviceMonitor.enabled=true \
  # --set exporter.serviceMonitor.namespace="monitoring" \
  # --set exporter.serviceMonitor.interval="30s" \
  # --set exporter.serviceMonitor.timeout="10s" \
  # --set exporter.serviceMonitor.labels.release="prometheus" \

# === Wait for Redis-HA Pods to be Fully Ready (All Containers) ===
echo "⏳ Waiting for all Redis-HA pods to be fully 'Ready (all containers)'..."

TIMEOUT=300
INTERVAL=10
ELAPSED=0

while true; do
  READY_FULL_COUNT=0

  for pod in $(kubectl get pods -n "$NAMESPACE" -l "release=$REDIS_RELEASE_NAME,app=redis-ha" -o jsonpath='{.items[*].metadata.name}'); do
    READY_CONTAINERS=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[*].ready}' | tr ' ' '\n' | grep -c true)
    TOTAL_CONTAINERS=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[*].name}' | wc -w)

    if [[ "$READY_CONTAINERS" -eq "$TOTAL_CONTAINERS" && "$READY_CONTAINERS" -gt 0 ]]; then
      READY_FULL_COUNT=$((READY_FULL_COUNT + 1))
    fi
  done

  if [[ "$READY_FULL_COUNT" -eq "$EXPECTED_PODS" ]]; then
    echo "✅ All Redis-HA pods are fully READY:"
    echo
    kubectl get pods -n "$NAMESPACE" -l "release=$REDIS_RELEASE_NAME,app=redis-ha"
    break
  fi

  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "❌ Timeout: Not all Redis-HA pods became fully ready within $TIMEOUT seconds."
    kubectl get pods -n "$NAMESPACE" -l "release=$REDIS_RELEASE_NAME,app=redis-ha"
    exit 1
  fi

  echo "⌛ [$ELAPSED/$TIMEOUT] Ready pods (fully): $READY_FULL_COUNT/$EXPECTED_PODS. Waiting..."
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

# === Discover Central Endpoint (HAProxy LoadBalancer) ===
HAPROXY_SERVICE_NAME=$(kubectl get svc -n "$NAMESPACE" -l "release=$REDIS_RELEASE_NAME,app=redis-ha-haproxy" -o jsonpath='{.items[0].metadata.name}')
if [ -z "$HAPROXY_SERVICE_NAME" ]; then
  HAPROXY_SERVICE_NAME="${REDIS_RELEASE_NAME}-haproxy"
fi

echo "⏳ Waiting for HAProxy LoadBalancer endpoint..."
ELAPSED=0
LB_IP=""
LB_HOSTNAME=""
while true; do
  LB_IP=$(kubectl get svc "$HAPROXY_SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  LB_HOSTNAME=$(kubectl get svc "$HAPROXY_SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

  if [[ -n "$LB_IP" || -n "$LB_HOSTNAME" ]]; then
    break
  fi

  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "⚠️ LoadBalancer endpoint is still pending. Service details:"
    kubectl get svc "$HAPROXY_SERVICE_NAME" -n "$NAMESPACE" -o wide || true
    break
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

REDIS_ENDPOINT="$LB_HOSTNAME"
if [ -z "$REDIS_ENDPOINT" ]; then
  REDIS_ENDPOINT="$LB_IP"
fi
if [ -z "$REDIS_ENDPOINT" ]; then
  REDIS_ENDPOINT="$HAPROXY_SERVICE_NAME.$NAMESPACE.svc.cluster.local"
fi

echo
echo "✅ Central Redis endpoint is ready:"
echo "Service: $HAPROXY_SERVICE_NAME"
echo "LB IP: ${LB_IP:-pending}"
echo "LB Hostname: ${LB_HOSTNAME:-pending}"
echo "Connect: redis://$REDIS_ENDPOINT:$REDIS_PORT"

if [ -n "$REDIS_INGRESS_HOST" ]; then
  echo "Ingress URL (DNS): redis://$REDIS_INGRESS_HOST:$REDIS_PORT"
fi
