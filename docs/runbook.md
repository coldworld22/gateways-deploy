# Runbook

## Is it healthy?

```bash
kubectl -n gateways get pods
kubectl -n gateways rollout status deploy/llm-gateway deploy/integration-gateway
```

Grafana dashboard **Gateways**: request rate, latency, 5xx ratio, 401s on webhooks, JVM heap.

## Symptoms

| Symptom | Likely cause | Check | Fix |
|---|---|---|---|
| Pod `CrashLoopBackOff` right after deploy | Missing secret key or wrong datastore URL | `kubectl logs deploy/<svc> --previous` | Fix the Secret or values; `helm upgrade` |
| Pod never `Ready`, startup probe failing | Database unreachable or migrations slow | Logs for `Flyway` / connection errors | Network/credentials; raise `probes.startup.failureThreshold` |
| Stripe dashboard shows webhook failures with 401 | Signing secret rotated in Stripe but not here | Grafana panel "Webhook signature rejections" | Update `STRIPE_WEBHOOK_SECRET`, `kubectl rollout restart deploy/integration-gateway` |
| Events accepted but consumers see nothing | Kafka unreachable; events wait in the outbox and retry | integration-gateway logs for Kafka producer errors | Restore Kafka; the outbox drains by itself |
| Events in `DEAD` status | Kafka down longer than the retry budget | `…/admin/events?status=DEAD` | After fixing Kafka: `POST /admin/events/{id}/replay` |
| llm-gateway rejects a team's requests as over limit | The team hit its per-minute limit or monthly token budget | `GET /v1/usage` with the team's key | Raise the team's limit or budget, or wait for the window |
| llm-gateway 502/503 | All providers on the route failing | Logs: circuit breaker opened | Check provider status and keys; routes fall back in order |
| `OOMKilled` | Memory limit too low for the heap | `kubectl describe pod` | Raise `resources.limits.memory`; the JVM uses 75% of it |

## Routine operations

```bash
# Restart without downtime (e.g. after a secret change)
kubectl -n gateways rollout restart deploy/integration-gateway

# Roll back a bad release
helm -n gateways history integration-gateway
helm -n gateways rollback integration-gateway <revision>

# Scale manually (if autoscaling is off)
kubectl -n gateways scale deploy/llm-gateway --replicas=4
```
