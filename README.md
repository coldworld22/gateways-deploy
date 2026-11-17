# gateways-deploy

[![CI](https://github.com/coldworld22/gateways-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/coldworld22/gateways-deploy/actions/workflows/ci.yml)
![Helm](https://img.shields.io/badge/Helm-3-0F1689?logo=helm&logoColor=white)
![Kubernetes 1.31](https://img.shields.io/badge/Kubernetes-1.31-326CE5?logo=kubernetes&logoColor=white)
![Docker Compose](https://img.shields.io/badge/Docker%20Compose-2496ED?logo=docker&logoColor=white)

How I ship [llm-gateway](https://github.com/coldworld22/llm-gateway) and
[integration-gateway](https://github.com/coldworld22/integration-gateway) into a customer's
environment: one Helm chart for both, a Compose stack with Prometheus and Grafana for a single
VM or a laptop, and an end-to-end test that deploys everything to a real Kubernetes cluster on
every push.

## What CI proves on every push

The `e2e` job builds both services from their repositories, starts a
[kind](https://kind.sigs.k8s.io) cluster (Kubernetes 1.31), installs them with the chart, and
checks the paths that matter:

| Check | Why it matters |
|---|---|
| A **signed Stripe webhook** returns `202`, the same event again returns `200 duplicate`, a forged signature returns `401` | Webhooks are verified and de-duplicated in the deployed configuration, not just in unit tests |
| The event **arrives in Kafka** (`integration.events.v1`) | MongoDB, the outbox and Kafka are wired correctly inside the cluster |
| An LLM request without a key gets `401`; with the demo key it gets an answer | Auth works end to end |
| The **provider never sees the national ID**: a mock provider records what it received and the test asserts it saw only `[NATIONAL_ID_1]`, while the client's answer has the real value restored | The PII masking promise holds across the network |
| Prometheus metrics are exposed; a rolling restart completes | Observability and zero-downtime updates work |

The `lint` job runs `helm lint --strict` and validates every rendered manifest (prod, dev, and
with ingress) against the Kubernetes 1.31 schemas with kubeconform.

## Layout

```
charts/spring-service/     one chart for any Spring Boot service
deploy/values/             llm-gateway.yaml, integration-gateway.yaml, dev.yaml
deploy/dev-deps/           single-replica Postgres, Redis, Mongo, Kafka, mock LLM (dev/CI only)
compose/                   all-in-one Docker Compose with Prometheus + Grafana dashboard
scripts/e2e.sh             the end-to-end test
docs/production.md         checklist for a customer environment (managed services, secrets, network)
docs/runbook.md            symptoms, causes and fixes for on-call
```

## The chart

One chart, because both services are Spring Boot apps with Actuator, and the customer's platform
team reviews one set of templates instead of two. Defaults are production-leaning:

- 2 replicas spread across nodes, PodDisruptionBudget, optional HPA
- zero-downtime rollouts: `maxUnavailable: 0`, `preStop` delay, Spring graceful shutdown
- startup, liveness and readiness probes on `/actuator/health/*`
- non-root, read-only root filesystem, all capabilities dropped, seccomp `RuntimeDefault`,
  no service-account token
- default-deny ingress NetworkPolicy; webhooks admitted only from the ingress controller
- secrets only by reference (`existingSecret`), never in values
- `enableServiceLinks: false`: otherwise a Service called `redis` injects `REDIS_PORT=tcp://…`
  and silently overrides the app's own `REDIS_PORT` setting
- Prometheus annotations, or a `ServiceMonitor` with the Prometheus Operator

## Run it

**Laptop or a single VM** (needs Docker):

```bash
docker compose -f compose/docker-compose.yml up --build
# llm-gateway :8080 (key local-demo-key) · integration-gateway :8081 · Prometheus :9090 · Grafana :3000
```

**Kubernetes** (kind, or any cluster):

```bash
kind create cluster --name gateways
docker build -t llm-gateway:dev https://github.com/coldworld22/llm-gateway.git#main
docker build -t integration-gateway:dev https://github.com/coldworld22/integration-gateway.git#main
kind load docker-image llm-gateway:dev integration-gateway:dev --name gateways
bash scripts/e2e.sh llm-gateway:dev integration-gateway:dev
```

For a real customer environment, see [docs/production.md](docs/production.md).
