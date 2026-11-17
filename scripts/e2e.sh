#!/usr/bin/env bash
# End-to-end test on a local Kubernetes cluster (kind). Deploys both gateways with the Helm chart,
# then proves the real paths work:
#   1. a signed Stripe webhook is accepted, de-duplicated, and lands in Kafka;
#   2. an LLM call goes through llm-gateway to a provider that never sees the national ID.
#
# Usage: scripts/e2e.sh <llm-gateway image> <integration-gateway image>
set -euo pipefail

LLM_IMAGE=${1:?llm-gateway image}
IG_IMAGE=${2:?integration-gateway image}
NS=gateways
STRIPE_SECRET=whsec_e2e_secret
ROOT=$(cd "$(dirname "$0")/.." && pwd)

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }

dump() {
  step "Diagnostics"
  kubectl -n "$NS" get pods -o wide || true
  for d in llm-gateway integration-gateway kafka mock-llm postgres mongo; do
    echo "--- logs: $d"; kubectl -n "$NS" logs "deploy/$d" --tail=80 || true
  done
}
trap 'dump' ERR

step "Namespace, secrets, datastores"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create secret generic llm-gateway-secrets \
  --from-literal=DATABASE_PASSWORD=e2e-db-password \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create secret generic integration-gateway-secrets \
  --from-literal=STRIPE_WEBHOOK_SECRET=$STRIPE_SECRET \
  --from-literal=META_APP_SECRET=e2e-meta-secret \
  --from-literal=META_VERIFY_TOKEN=e2e-verify \
  --from-literal=GATEWAY_ADMIN_TOKEN=e2e-admin \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create configmap mock-llm --from-file=server.py="$ROOT/mock-llm/server.py" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" apply -f "$ROOT/deploy/dev-deps/"
kubectl -n "$NS" rollout status deploy/postgres deploy/redis deploy/mongo deploy/kafka deploy/mock-llm --timeout=180s

step "Helm install"
install() { # name image valuesfile [extra args]
  local name=$1 image=$2 values=$3; shift 3
  helm upgrade --install "$name" "$ROOT/charts/spring-service" -n "$NS" \
    -f "$values" -f "$ROOT/deploy/values/dev.yaml" \
    --set image.repository="${image%:*}" --set image.tag="${image##*:}" --set image.pullPolicy=Never \
    --wait --timeout 6m "$@"
}
install llm-gateway "$LLM_IMAGE" "$ROOT/deploy/values/llm-gateway.yaml" --set env.SPRING_PROFILES_ACTIVE=demo
install integration-gateway "$IG_IMAGE" "$ROOT/deploy/values/integration-gateway.yaml"
kubectl -n "$NS" get pods

kubectl -n "$NS" port-forward svc/llm-gateway 18080:80 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/integration-gateway 18081:80 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward svc/ollama 18082:11434 >/dev/null 2>&1 &
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
for url in localhost:18080/actuator/health/liveness localhost:18081/actuator/health/liveness localhost:18082/; do
  for _ in $(seq 1 30); do curl -fs "$url" >/dev/null 2>&1 && break; sleep 1; done
done

step "integration-gateway: signed Stripe webhook -> MongoDB -> Kafka"
BODY='{"id":"evt_e2e_1","type":"payment_intent.succeeded","data":{"object":{"amount":5000}}}'
T=$(date +%s)
SIG=$(printf '%s' "$T.$BODY" | openssl dgst -sha256 -hmac "$STRIPE_SECRET" -hex | sed 's/^.* //')
code=$(curl -s -o /dev/null -w '%{http_code}' localhost:18081/webhooks/stripe \
  -H "Stripe-Signature: t=$T,v1=$SIG" -H 'Content-Type: application/json' -d "$BODY")
[ "$code" = 202 ] || fail "signed webhook returned $code, want 202"
echo "signed webhook: 202 accepted"
code=$(curl -s -o /dev/null -w '%{http_code}' localhost:18081/webhooks/stripe \
  -H "Stripe-Signature: t=$T,v1=$SIG" -H 'Content-Type: application/json' -d "$BODY")
[ "$code" = 200 ] || fail "duplicate webhook returned $code, want 200"
echo "same event again: 200 duplicate"
code=$(curl -s -o /dev/null -w '%{http_code}' localhost:18081/webhooks/stripe \
  -H "Stripe-Signature: t=$T,v1=deadbeef" -H 'Content-Type: application/json' -d "$BODY")
[ "$code" = 401 ] || fail "forged webhook returned $code, want 401"
echo "forged signature: 401"
kubectl -n "$NS" exec deploy/kafka -- /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic integration.events.v1 --from-beginning \
  --max-messages 1 --timeout-ms 60000 | tee /tmp/kafka.out
grep -q evt_e2e_1 /tmp/kafka.out || fail "event not found in Kafka"
echo "event delivered to Kafka topic integration.events.v1"

step "llm-gateway: auth, PII masking, usage"
code=$(curl -s -o /dev/null -w '%{http_code}' localhost:18080/v1/usage)
[ "$code" = 401 ] || fail "no API key returned $code, want 401"
echo "no API key: 401"
reply=$(curl -fs localhost:18080/v1/chat/completions \
  -H 'Authorization: Bearer local-demo-key' -H 'Content-Type: application/json' \
  -d '{"model":"chat-local","messages":[{"role":"user","content":"My ID is 1012345678, what documents do I need?"}]}')
echo "gateway answer: $reply"
echo "$reply" | grep -q 1012345678 || fail "answer should contain the restored ID"
seen=$(curl -fs localhost:18082/last)
echo "provider received: $seen"
echo "$seen" | grep -q 1012345678 && fail "provider saw the raw national ID"
echo "$seen" | grep -q 'NATIONAL_ID' || fail "provider should see a placeholder"
echo "provider saw only a placeholder; the answer had the real value restored"
curl -fs localhost:18080/v1/usage -H 'Authorization: Bearer local-demo-key' | tee /dev/stderr | grep -q . \
  || fail "usage endpoint"

step "Metrics"
curl -fs localhost:18080/actuator/prometheus | grep -c '^gateway_' | xargs echo "llm-gateway gateway_* series:"
curl -fs localhost:18081/actuator/prometheus | grep -q '^http_server_requests' || fail "integration-gateway metrics"

step "Rolling restart keeps serving"
kubectl -n "$NS" rollout restart deploy/integration-gateway
kubectl -n "$NS" rollout status deploy/integration-gateway --timeout=180s

trap - ERR
step "All end-to-end checks passed"
