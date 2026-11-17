# pfm-core-ledger-infra

Repositório dedicado **1:1 de Infraestrutura como Código (IaC) & GitOps** para o microsserviço `pfm-core-ledger-java` (Java 25 LTS, ZGC Generational, Virtual Threads, PostgreSQL 16 RLS e Transactional Outbox).

## Estrutura
- `terraform/aws`, `terraform/azure`, `terraform/gcp`: Políticas IAM / Service Accounts (IRSA / Workload Identity) de menor privilégio restritas exclusivamente ao banco `pfm_core_ledger`, tópicos Kafka (`tx.categorized`, `ledger.entry.committed`) e chave KMS do tenant.
- `helm/`: Chart Kubernetes com suporte a Virtual Threads + ZGC Generational (`JAVA_TOOL_OPTIONS="-XX:+UseZGC -XX:+ZGenerational"`), probes HTTP/gRPC, `PodDisruptionBudget`, `NetworkPolicy` Zero-Trust (aceitando tráfego gRPC apenas de `pfm-ingestion-bff-go` e conectando apenas no PostgreSQL/Kafka) e exportação OpenTelemetry OTLP.
- `monitoring/prometheus-alerts.yaml`: Regras Prometheus baseadas no SLO oficial (Artefato 07 V2): disponibilidade < 99,95% (Multi-window Burn Rate), latência gRPC p99 > 150ms e acúmulo na tabela `outbox_events` > 100 registros não publicados.
- `.github/workflows/infra-validate.yml`: Pipeline GitOps executando `tofu fmt -check`, `tofu validate`, `helm lint`, `tfsec` e `checkov`.

---

## Topologia de Portas: Local Host vs. Kubernetes Cloud

- **Host Local (`values-local.yaml`):** HTTP `18200` (`SERVER_PORT`), gRPC `18210` (`GRPC_SERVER_PORT`), PostgreSQL `15432`, Kafka `19092`.
- **Produção K8s (`values-prod.yaml`):** HTTP `8080` (Service & Container), gRPC `9090` (Service & Container), PostgreSQL `5432`, Kafka `9092`.
