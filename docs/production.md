# Deploying into a customer's environment

The kind cluster in CI proves the chart works. A customer deployment differs in three ways:
datastores are managed services, secrets come from the customer's vault, and traffic enters
through their ingress and firewall. This is the checklist I work through with the customer's
platform team.

## 1. Before the first meeting

- Which cloud and region? Saudi public-sector and health data usually has to stay in-Kingdom
  (PDPL, NCA ECC). Confirm the region before anything else.
- Kubernetes already there (EKS, AKS, GKE, OpenShift) or not? If not, start with the Compose
  stack on a VM and move later; the images and config are the same.
- Who owns DNS, TLS certificates, and the firewall for inbound webhooks?

## 2. Managed services

| Dev (this repo) | AWS | Azure | Google Cloud | Notes |
|---|---|---|---|---|
| `postgres` | RDS for PostgreSQL | Azure Database for PostgreSQL Flexible | Cloud SQL | llm-gateway runs Flyway migrations on start |
| `redis` | ElastiCache | Azure Cache for Redis | Memorystore | Rate limits only; losing it resets counters, nothing else |
| `mongo` | DocumentDB (check feature fit) or Atlas | Cosmos DB for MongoDB vCore or Atlas | Atlas | integration-gateway stores each event once (unique index) |
| `kafka` | MSK | Event Hubs (Kafka endpoint) | Managed Kafka | Producer uses `acks=all` + idempotence; topic `integration.events.v1` |

Set the connection values in a per-environment values file (`deploy/values/<env>.yaml`), never
in the chart.

## 3. Secrets

The chart only references a Secret by name (`existingSecret`). In production that Secret is
created by the customer's tooling:

| Customer uses | Create the Secret with |
|---|---|
| AWS Secrets Manager / Azure Key Vault / GCP Secret Manager | External Secrets Operator `ExternalSecret` |
| GitOps without a vault | Sealed Secrets |
| Nothing yet | `kubectl create secret generic …` from a password manager, then plan a vault |

| Secret key | Service |
|---|---|
| `DATABASE_PASSWORD`, `OPENAI_API_KEY`, `AZURE_OPENAI_API_KEY` | llm-gateway |
| `STRIPE_WEBHOOK_SECRET`, `META_APP_SECRET`, `META_VERIFY_TOKEN`, `GATEWAY_ADMIN_TOKEN` | integration-gateway |

## 4. Network

- **integration-gateway** must be reachable from Stripe and Meta: expose only `/webhooks` through
  the ingress (`ingress.paths: ["/webhooks"]`), with TLS. `/admin` and `/actuator` stay internal.
  Signatures are verified by the app, so no IP allow-list is needed (Meta's ranges change).
- **llm-gateway** is internal only. Its NetworkPolicy admits pods labelled
  `app.kubernetes.io/part-of: gateways`; add the calling apps' labels to `networkPolicy.allowFrom`.
- Egress: llm-gateway needs the LLM providers' endpoints (or the customer's Azure OpenAI private
  endpoint); integration-gateway needs only Mongo and Kafka.

## 5. Install

```bash
helm upgrade --install llm-gateway charts/spring-service -n gateways \
  -f deploy/values/llm-gateway.yaml -f deploy/values/prod.yaml --set image.tag=<git-sha>
helm upgrade --install integration-gateway charts/spring-service -n gateways \
  -f deploy/values/integration-gateway.yaml -f deploy/values/prod.yaml --set image.tag=<git-sha>
```

Defaults the chart already gives you: 2+ replicas spread across nodes, a PodDisruptionBudget,
zero-downtime rolling updates (`maxUnavailable: 0`, preStop delay, graceful shutdown), non-root
read-only containers with all capabilities dropped, and startup/liveness/readiness probes on
Spring Boot Actuator.

## 6. Observability

- With kube-prometheus-stack: `--set serviceMonitor.enabled=true`.
- Without it: pods carry `prometheus.io/*` annotations for annotation-based scraping.
- Import `compose/grafana/dashboards/gateways.json` into the customer's Grafana.
- Alerts worth creating on day one: 5xx ratio > 2% for 10 min; integration-gateway outbox
  events in `DEAD` status > 0; llm-gateway provider circuit breaker open.

## 7. Handover

Walk the customer's on-call through `docs/runbook.md`, run one rolling restart and one
dead-event replay together, and leave them with the values files in their own Git repository.
