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

### Script principal (`c1.sh`) — Cenário C1

Script de testes de carga com **3 perfis de utilizador** de comportamento natural (timings diferenciados) e spawn gradual.

```bash
# Dar permissão de execução (só é preciso fazer uma vez)
chmod +x c1.sh

# Demo rápida (10 users, 2 min) — para validar que tudo está OK
NAMESPACE=default ./c1.sh demo

# Cenário C1 — escada incremental até quebra (5 → 50 users)
NAMESPACE=default ./c1.sh incremental

# Com parâmetros customizados
MAX_USERS=80 STEP_DURATION=90 SPAWN_RATE=3 NAMESPACE=default ./c1.sh incremental
```

**Modos disponíveis:**

| Modo | Descrição |
|---|---|
| `demo` | Run único de validação (10 users, 2 min) |
| `incremental` | Escada 5 → MAX_USERS até o sistema quebrar (Cenário C1) |
| `baseline` | Captura estado inicial do cluster |
| `pause_lg` | Pausa o loadgenerator nativo do cluster |
| `resume_lg` | Retoma o loadgenerator nativo |
| `report` | Gera resumo de resultados já existentes |

**Variáveis de ambiente:**

| Variável | Default | Descrição |
|---|---|---|
| `NAMESPACE` | `default` | Namespace Kubernetes |
| `MAX_USERS` | `50` | Limite máximo de utilizadores (modo incremental) |
| `STEP_DURATION` | `60` | Segundos de carga por step |
| `SPAWN_RATE` | `2` | Utilizadores lançados por segundo (entrada gradual) |
| `P99_THRESHOLD` | `2000` | ms de p99 para considerar quebra |
| `FAIL_THRESHOLD` | `5` | % de falhas para considerar quebra |
| `COOLDOWN` | `15` | Segundos de cooldown entre steps |

**Outputs** em `cenarios_ob_YYYYMMDD_HHMMSS/`:
```
baseline/                    # estado do cluster antes dos testes
step_Nusers/                 # métricas Locust por step (CSV + HTML)
monitoring/pods_metrics.csv  # séries temporais de CPU/pod
progresso_incremental.csv    # tabela consolidada com todos os steps
RESUMO.txt                   # relatório final
run.log                      # log completo da execução
```

### Perfis de utilizador (simulação realista)

| Perfil | Peso | Wait time | Comportamento |
|---|---|---|---|
| `CasualUser` | 30 % | 5–15 s | Navega devagar, raramente compra |
| `NormalUser` | 50 % | 2–6 s | Ritmo médio, checkout ocasional |
| `PowerUser` | 20 % | 0,5–2 s | Age rapidamente, vai direto ao checkout |

### Resultados — Execução de referência (2026-03-22)

| Users | p50 | p90 | p99 | Falhas | RPS | Estado |
| --- | --- | --- | --- | --- | --- | --- |
| 5 | 25 ms | 36 ms | 130 ms | 0 | 1,71 | ✅ OK |
| 10 | 21 ms | 36 ms | 77 ms | 0 | 3,41 | ✅ OK |
| 15 | 22 ms | 35 ms | 120 ms | 0 | 4,98 | ✅ OK |
| 20 | 26 ms | 120 ms | 410 ms | 0 | 6,60 | ✅ OK |
| 25 | 21 ms | 65 ms | 420 ms | 0 | 8,35 | ✅ OK |
| **30** | **13 ms** | **210 ms** | **910 ms** | **247 (47,6 %)** | **8,79** | 🔴 QUEBRA |

**Ponto de quebra:** 30 utilizadores — `QUEBRA_FALHAS(47.6%)`. Gargalo nos serviços `frontend`, `cartservice` e `productcatalogservice`.

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
