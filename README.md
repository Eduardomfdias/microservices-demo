# ASID 2025/2026 — Tema 2: Escalabilidade Horizontal e Custo Marginal
## Online Boutique — Microservices Demo no Kubernetes

Repositório de trabalho da unidade curricular **Análise de Sistemas Informáticos Distribuídos** (MEGSI, 2.º semestre).

Baseia-se no projecto open-source [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) da Google, adaptado para correr localmente em **Kubernetes (Docker Desktop)** com observabilidade via **Jaeger** e testes de carga com **Locust**.

---

## Arquitectura

O sistema é composto por **11 microserviços** que comunicam via gRPC:

```
Browser / Locust
      │
      ▼
  frontend (Go) ──────────────────────────────────────────────┐
      │                                                        │
      ├──► productcatalogservice (Go)                          │
      ├──► currencyservice (Node.js)                           │
      ├──► cartservice (.NET)  ──► redis-cart                  │
      ├──► recommendationservice (Python) ──► productcatalog   │
      ├──► checkoutservice (Go) ───────────────────────────────┤
      │         ├──► cartservice                               │
      │         ├──► productcatalogservice                     │
      │         ├──► currencyservice                           │
      │         ├──► shippingservice (Go)                      │
      │         ├──► paymentservice (Node.js)                  │
      │         └──► emailservice (Python)                     │
      └──► adservice (Java)
```

### Pipeline de Observabilidade

```
Microserviços ──OTLP gRPC──► OpenTelemetry Collector ──OTLP gRPC──► Jaeger
                (porta 4317)       (porta 4317)                   UI: 16686
```

---

## Pré-requisitos

- **Docker Desktop** com Kubernetes activado
- **kubectl** configurado para o cluster local
- **Python 3** + **Locust**: `pip3 install locust`

---

## Deploy

```bash
# 1. Deploy de todos os serviços (aplicação + Jaeger + OTEL Collector)
kubectl apply -f kubernetes-manifests/

# 2. Activar tracing nos microserviços
for svc in frontend checkoutservice productcatalogservice paymentservice \
           currencyservice emailservice recommendationservice shippingservice \
           cartservice adservice; do
  kubectl set env deployment/$svc \
    COLLECTOR_SERVICE_ADDR=opentelemetrycollector:4317 \
    ENABLE_TRACING=1 \
    OTEL_SERVICE_NAME=$svc
done

# 3. Fix para Apple Silicon (arm64) — bug do .NET JIT com W^X
kubectl set env deployment/cartservice DOTNET_EnableWriteXorExecute=0

# 4. Verificar que tudo está Running
kubectl get pods
```

### URLs

| Serviço | URL |
|---|---|
| Online Boutique | http://localhost |
| Jaeger UI | http://localhost:31686 |

---

## Ficheiros adicionados

### `kubernetes-manifests/jaeger.yaml`
Deploy do **Jaeger all-in-one** no namespace `default`:
- `Deployment`: `jaegertracing/all-in-one:latest` com OTLP activado (`COLLECTOR_OTLP_ENABLED=true`)
- `Service` (NodePort): UI na porta **31686**, OTLP gRPC na porta **4317**

### `kubernetes-manifests/otel-collector.yaml`
Deploy standalone do **OpenTelemetry Collector** configurado para exportar traces para o Jaeger:
- `ConfigMap`: pipeline `otlp receiver → batch processor → otlp/jaeger exporter`
- `Deployment`: `otel/opentelemetry-collector-contrib:0.144.0`
- `Service` (ClusterIP): porta 4317 (gRPC) e 4318 (HTTP)

> O collector original exportava para Google Cloud Operations. Esta versão substitui esse backend pelo Jaeger local, sem alterar nenhum microserviço.

---

## Observabilidade com Jaeger

Abre http://localhost:31686

### Workflows instrumentados

| Workflow | Service no Jaeger | Operation |
|---|---|---|
| **W1** — Browse Product | `frontend` | `hipstershop.ProductCatalogService/GetProduct` |
| **W2** — Add to Cart | `frontend` | `hipstershop.CartService/AddItem` |
| **W3** — Checkout | `frontend` | `hipstershop.CheckoutService/PlaceOrder` |

O trace do **W3** é o mais completo — propaga por ~8 serviços e mostra a cadeia completa de dependências.

---

## Testes de carga

### Script incremental (`experimentos_escalamento.sh`)

Incrementa 1 utilizador virtual por step até o sistema quebrar (critérios: p99 > 2000 ms ou taxa de falhas > 5%).

```bash
# Modo recomendado
./experimentos_escalamento.sh incremental

# Com parâmetros customizados
MAX_USERS=80 STEP_DURATION=90 P99_THRESHOLD=3000 ./experimentos_escalamento.sh incremental
```

**Variáveis:**

| Variável | Default | Descrição |
|---|---|---|
| `MAX_USERS` | 60 | Limite máximo de utilizadores |
| `STEP_DURATION` | 60 | Segundos de carga por step |
| `P99_THRESHOLD` | 2000 | ms de p99 para considerar quebra |
| `FAIL_THRESHOLD` | 5 | % de falhas para considerar quebra |
| `COOLDOWN` | 15 | Segundos entre steps |

**Outputs** em `resultados_YYYYMMDD_HHMMSS/`:
```
baseline/                    # estado do cluster antes dos testes
step_Nusers/                 # métricas Locust por step (CSV + HTML)
monitoring/pods_metrics.csv  # séries temporais de CPU/RAM
RESUMO_EXPERIMENTOS.txt      # relatório consolidado
```

### Script de cenários (`test1.sh`)

Versão compatível com GKE e Docker Desktop. Suporta modo `demo` (validação rápida do ciclo completo) e modo `incremental`.

```bash
# Docker Desktop
NAMESPACE=default DISABLE_LG=false ./test1.sh demo

# GKE
HOST_IP=34.x.x.x NAMESPACE=ob ./test1.sh incremental
```

### Distribuição de tarefas Locust

| Tarefa | Peso | ~Freq | Serviços envolvidos |
|---|---|---|---|
| Browse product | 10 | 43% | frontend, productcatalogservice, currencyservice, adservice |
| Homepage | 5 | 22% | frontend, productcatalogservice, recommendationservice, currencyservice |
| Add to cart | 3 | 13% | frontend, cartservice |
| View cart | 2 | 9% | frontend, cartservice |
| Set currency | 2 | 9% | frontend, currencyservice |
| Checkout | 1 | 4% | todos |

---

## Notas de compatibilidade

### Apple Silicon (arm64)

O `cartservice` (.NET) crasha em arm64 por um bug do JIT com a protecção W^X (Write XOR Execute). Corrigido com:

```bash
kubectl set env deployment/cartservice DOTNET_EnableWriteXorExecute=0
```

Aplicar após cada `kubectl apply -f kubernetes-manifests/`.

---

## Estrutura do repositório

```
.
├── kubernetes-manifests/
│   ├── jaeger.yaml              ← NOVO: Jaeger all-in-one + NodePort
│   ├── otel-collector.yaml      ← NOVO: OTEL Collector → Jaeger
│   ├── frontend.yaml
│   ├── checkoutservice.yaml
│   └── ...
├── src/                         # Código fonte dos microserviços
├── helm-chart/                  # Helm chart (deploy cloud)
├── kustomize/                   # Componentes Kustomize
├── experimentos_escalamento.sh  # Testes de carga incrementais
├── test1.sh                     # Cenários de teste (GKE + Docker Desktop)
└── locustfile.py                # Comportamento dos utilizadores virtuais
```

---

## Referências

- [Online Boutique — repositório original](https://github.com/GoogleCloudPlatform/microservices-demo)
- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [Jaeger — distributed tracing](https://www.jaegertracing.io/)
- [Locust — load testing](https://locust.io/)
