#!/bin/bash
# =============================================================================
# ASID 2025/2026 — Tema 2: Escalabilidade Horizontal e Custo Marginal
# Script de Cenários de Teste — Online Boutique (baseado nos cenários da prof.)
# Ficheiro: testes_cenarios_ob.sh
# =============================================================================
# DIFERENÇAS face ao experimentos_escalamento.sh anterior:
#   - Namespace "ob" (cluster GKE com o Online Boutique já deployado)
#   - URL do frontend via NodePort (não localhost)
#   - Desativa/reativa o loadgenerator nativo do repositório antes/depois dos testes
#   - Inclui queries Prometheus (Grafana) e instruções Jaeger conforme o PDF
#   - Modo "demo": um único run curto para validar o ciclo completo
#   - Modo "incremental": 1 user → N até quebrar (igual ao anterior, mas em "ob")
#
# MODOS DISPONÍVEIS:
#   ./testes_cenarios_ob.sh demo          # run único de validação (PDF §4)
#   ./testes_cenarios_ob.sh incremental   # 1 user → MAX_USERS até quebrar
#   ./testes_cenarios_ob.sh baseline      # captura estado inicial
#   ./testes_cenarios_ob.sh report        # gera resumo de resultados existentes
#   ./testes_cenarios_ob.sh pause_lg      # pausa o loadgenerator nativo
#   ./testes_cenarios_ob.sh resume_lg     # retoma o loadgenerator nativo
#
# VARIÁVEIS OPCIONAIS:
#   HOST_IP=34.x.x.x       IP externo do nó (obrigatório em GKE)
#   NAMESPACE=ob           namespace Kubernetes (default: ob)
#   MAX_USERS=60           limite de utilizadores (default: 60)
#   STEP_DURATION=60       segundos por step incremental (default: 60)
#   DEMO_USERS=10          utilizadores no modo demo (default: 10)
#   DEMO_DURATION=120      segundos do modo demo (default: 120)
#   P99_THRESHOLD=2000     ms de p99 para quebra (default: 2000)
#   FAIL_THRESHOLD=5       % de falhas para quebra (default: 5)
#   DISABLE_LG=true        desativar loadgenerator nativo antes dos testes (default: true)
#
# EXEMPLO GKE:
#   HOST_IP=34.90.1.2 ./testes_cenarios_ob.sh demo
#   HOST_IP=34.90.1.2 MAX_USERS=40 ./testes_cenarios_ob.sh incremental
#
# EXEMPLO Docker Desktop (namespace default):
#   NAMESPACE=default DISABLE_LG=false ./testes_cenarios_ob.sh incremental
# =============================================================================

NAMESPACE="${NAMESPACE:-ob}"
DISABLE_LG="${DISABLE_LG:-true}"
MAX_USERS="${MAX_USERS:-50}"
STEP_DURATION="${STEP_DURATION:-60}"
DEMO_USERS="${DEMO_USERS:-10}"
DEMO_DURATION="${DEMO_DURATION:-120}"
P99_THRESHOLD="${P99_THRESHOLD:-2000}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-5}"
COOLDOWN="${COOLDOWN:-15}"

RESULTS_DIR="cenarios_ob_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RESULTS_DIR/run.log"; }

# =============================================================================
# SECÇÃO 0 — PRÉ-REQUISITOS
# =============================================================================
check_prerequisites() {
  log "A verificar pré-requisitos..."

  kubectl cluster-info > /dev/null 2>&1 || { log "ERRO: kubectl não conectado ao cluster"; exit 1; }

  # Verifica se o namespace existe
  kubectl get namespace "$NAMESPACE" > /dev/null 2>&1 || {
    log "AVISO: namespace '$NAMESPACE' não encontrado."
    log "       Verifica com: kubectl get namespaces"
    log "       Se usas Docker Desktop, define: NAMESPACE=default"
    exit 1
  }

  # Calcula a URL do frontend via NodePort no namespace correto
  if [ -n "$HOST_IP" ]; then
    # GKE ou máquina remota: usa o IP fornecido com o NodePort
    NODEPORT=$(kubectl -n "$NAMESPACE" get svc frontend-external \
      -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    if [ -n "$NODEPORT" ]; then
      FRONTEND_URL="http://${HOST_IP}:${NODEPORT}"
    else
      # Tenta também pelo LoadBalancer (GKE)
      LB_IP=$(kubectl -n "$NAMESPACE" get svc frontend-external \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
      [ -n "$LB_IP" ] && FRONTEND_URL="http://${LB_IP}" || {
        log "ERRO: não foi possível determinar a URL do frontend."
        log "       Define HOST_IP com o IP externo do nó GKE."
        exit 1
      }
    fi
  else
    # Docker Desktop: o LoadBalancer expõe sempre na porta 80 em localhost
    FRONTEND_URL="http://localhost"
  fi

  log "Frontend URL: $FRONTEND_URL"

  # Testa se o frontend responde antes de continuar
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$FRONTEND_URL" 2>/dev/null)
  if [ "$HTTP_STATUS" != "200" ]; then
    log "AVISO: frontend devolveu HTTP $HTTP_STATUS (esperado 200)."
    log "       Verifica se o cluster está up e o namespace correto."
    log "       Continua mesmo assim em 5s... (Ctrl+C para cancelar)"
    sleep 5
  else
    log "Frontend OK (HTTP 200)"
  fi

  # Locust — procura no PATH e nas pastas típicas do pip
  LOCUST_BIN=$(which locust 2>/dev/null)
  [ -z "$LOCUST_BIN" ] && LOCUST_BIN=$(find ~/Library/Python -name "locust" -type f 2>/dev/null | head -1)
  [ -z "$LOCUST_BIN" ] && LOCUST_BIN=$(find ~/.local/bin -name "locust" -type f 2>/dev/null | head -1)

  if [ -z "$LOCUST_BIN" ]; then
    log "locust não encontrado, a instalar..."
    pip3 install locust --quiet 2>/dev/null || pip install locust --quiet 2>/dev/null
    LOCUST_BIN=$(which locust 2>/dev/null)
    [ -z "$LOCUST_BIN" ] && LOCUST_BIN=$(find ~/Library/Python ~/.local -name "locust" -type f 2>/dev/null | head -1)
  fi

  [ -z "$LOCUST_BIN" ] && { log "ERRO: locust não encontrado após instalação"; exit 1; }
  export LOCUST_BIN FRONTEND_URL
  log "Locust: $LOCUST_BIN"

  # metrics-server
  kubectl top nodes -n "$NAMESPACE" > /dev/null 2>&1 || {
    log "metrics-server ausente. A instalar..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    log "Aguarda 60s para o metrics-server arrancar..."
    sleep 60
  }

  log "Pré-requisitos OK"
}

# =============================================================================
# SECÇÃO 1 — GESTÃO DO LOADGENERATOR NATIVO
# O repositório Online Boutique inclui um loadgenerator que corre em contínuo.
# Para testar com carga controlada (Locust externo), é necessário pausá-lo;
# caso contrário, há interferência entre o tráfego nativo e o de teste.
# =============================================================================
pause_loadgenerator() {
  log "A pausar o loadgenerator nativo (namespace: $NAMESPACE)..."
  kubectl -n "$NAMESPACE" scale deploy/loadgenerator --replicas=0 2>/dev/null && \
    log "loadgenerator pausado." || \
    log "AVISO: loadgenerator não encontrado ou já parado (pode não existir)."
  # Guarda o estado para restaurar depois
  echo "paused" > "$RESULTS_DIR/lg_state.txt"
}

resume_loadgenerator() {
  log "A retomar o loadgenerator nativo (namespace: $NAMESPACE)..."
  kubectl -n "$NAMESPACE" scale deploy/loadgenerator --replicas=1 2>/dev/null && \
    log "loadgenerator retomado." || \
    log "AVISO: não foi possível retomar o loadgenerator."
  echo "running" > "$RESULTS_DIR/lg_state.txt"
}

# Versão standalone (chamada diretamente da linha de comandos)
pause_lg_standalone() {
  kubectl -n "${NAMESPACE}" scale deploy/loadgenerator --replicas=0 2>/dev/null && \
    echo "loadgenerator pausado (namespace: ${NAMESPACE})" || \
    echo "AVISO: loadgenerator não encontrado em namespace '${NAMESPACE}'"
}

resume_lg_standalone() {
  kubectl -n "${NAMESPACE}" scale deploy/loadgenerator --replicas=1 2>/dev/null && \
    echo "loadgenerator retomado (namespace: ${NAMESPACE})" || \
    echo "AVISO: não foi possível retomar o loadgenerator"
}

# =============================================================================
# SECÇÃO 2 — BASELINE
# =============================================================================
capture_baseline() {
  log "=== BASELINE: captura estado inicial (namespace: $NAMESPACE) ==="
  local out="$RESULTS_DIR/baseline"
  mkdir -p "$out"

  kubectl -n "$NAMESPACE" get deployments -o wide > "$out/deployments.txt"

  # Tabela de recursos configurados por serviço
  kubectl -n "$NAMESPACE" get deployments -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f'{'Serviço':<30} {'Réplicas':<10} {'CPU req':<12} {'CPU lim':<12} {'Mem req':<12} {'Mem lim':<12}')
print('-'*90)
for d in data['items']:
    name = d['metadata']['name']
    replicas = d['spec'].get('replicas', 1)
    for c in d['spec']['template']['spec']['containers']:
        res = c.get('resources', {})
        req = res.get('requests', {})
        lim = res.get('limits', {})
        print(f'{name:<30} {replicas:<10} {req.get(\"cpu\",\"n/a\"):<12} {lim.get(\"cpu\",\"n/a\"):<12} {req.get(\"memory\",\"n/a\"):<12} {lim.get(\"memory\",\"n/a\"):<12}')
" | tee "$out/resources_config.txt"

  kubectl -n "$NAMESPACE" top pods --sort-by=cpu > "$out/top_pods_idle.txt" 2>&1
  kubectl top nodes > "$out/top_nodes_idle.txt" 2>&1
  kubectl -n "$NAMESPACE" get pods -o wide > "$out/pods_status.txt"
  kubectl -n "$NAMESPACE" get hpa > "$out/hpa_inicial.txt" 2>&1

  # Estado do loadgenerator nativo
  kubectl -n "$NAMESPACE" get deploy loadgenerator \
    -o jsonpath='REPLICAS={.spec.replicas} ENV={.spec.template.spec.containers[0].env}{"\n"}' \
    2>/dev/null > "$out/loadgenerator_config.txt" || \
    echo "loadgenerator não encontrado" > "$out/loadgenerator_config.txt"

  log "Baseline em $out/"
}

# =============================================================================
# SECÇÃO 3 — MONITORIZAÇÃO CONTÍNUA
# =============================================================================
start_monitoring() {
  local interval=${1:-15}
  local out="$RESULTS_DIR/monitoring"
  mkdir -p "$out"
  log "A iniciar monitorização (${interval}s) → $out/"
  (
    i=0
    while true; do
      ts=$(date +%H:%M:%S)
      kubectl -n "$NAMESPACE" top pods --sort-by=cpu 2>/dev/null | \
        awk -v ts="$ts" -v i="$i" 'NR>1{print ts","i","$1","$2","$3}' \
        >> "$out/pods_metrics.csv"
      kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | \
        awk -v ts="$ts" '$4>0{print ts" RESTART pod="$1" restarts="$4}' \
        >> "$out/restarts.log"
      i=$((i+1))
      sleep "$interval"
    done
  ) &
  MONITOR_PID=$!
  echo $MONITOR_PID > "$RESULTS_DIR/monitor.pid"
  log "Monitor PID: $MONITOR_PID"
}

stop_monitoring() {
  if [ -f "$RESULTS_DIR/monitor.pid" ]; then
    kill "$(cat "$RESULTS_DIR/monitor.pid")" 2>/dev/null
    log "Monitorização parada"
  fi
}

# =============================================================================
# SECÇÃO 4 — FICHEIRO LOCUST
# Usa o mesmo comportamento do locustfile.py do repositório original,
# garantindo consistência entre os testes externos e o loadgenerator nativo.
# =============================================================================
create_locustfile() {
cat > "$RESULTS_DIR/locustfile.py" << 'LOCUST_EOF'
# Comportamento equivalente ao src/loadgenerator/locustfile.py do repositório
# oficial do Online Boutique. Os pesos foram ajustados para reflectir a
# distribuição realista de acções de um utilizador de e-commerce.
from locust import HttpUser, task, between
import random

PRODUCT_IDS = [
    "OLJCESPC7Z", "66VCHSJNUP", "1YMWWN1N4O",
    "L9ECAV7KIM", "2ZYFJ3GM2N", "0PUK6V6EV0",
    "LS4PSXUNUM", "9SIQT8TOJO", "6E92ZMYYFZ"
]

class OnlineBoutiqueUser(HttpUser):
    wait_time = between(1, 3)  # mais conservador que o padrão — simula utilizadores reais

    @task(10)
    def browse_product(self):
        pid = random.choice(PRODUCT_IDS)
        self.client.get(f"/product/{pid}", name="/product/[id]")

    @task(5)
    def index(self):
        self.client.get("/")

    @task(3)
    def add_to_cart(self):
        pid = random.choice(PRODUCT_IDS)
        self.client.post("/cart", data={"product_id": pid, "quantity": "1"}, name="/cart [add]")

    @task(2)
    def view_cart(self):
        self.client.get("/cart")

    @task(1)
    def checkout(self):
        pid = random.choice(PRODUCT_IDS)
        self.client.post("/cart", data={"product_id": pid, "quantity": "1"}, name="/cart [add]")
        self.client.post("/cart/checkout", data={
            "email": "test@asid.uc.pt",
            "street_address": "Rua Pedro Hispano 1",
            "zip_code": "3030-199",
            "city": "Coimbra",
            "state": "Coimbra",
            "country": "Portugal",
            "credit_card_number": "4432801561520454",
            "credit_card_expiration_month": "1",
            "credit_card_expiration_year": "2030",
            "credit_card_cvv": "672"
        }, name="/cart/checkout")

    @task(2)
    def set_currency(self):
        currency = random.choice(["EUR", "USD", "GBP", "JPY"])
        self.client.post("/setCurrency", data={"currency_code": currency})
LOCUST_EOF
  log "locustfile.py criado"
}

# =============================================================================
# SECÇÃO 5 — MODO DEMO (PDF §4)
# Um único run curto para validar o ciclo completo:
# Locust → logs → Grafana → Jaeger.
# Não procura o ponto de quebra — apenas confirma que tudo funciona.
# =============================================================================
run_demo() {
  log "========================================================"
  log "MODO DEMO — ${DEMO_USERS} users durante ${DEMO_DURATION}s"
  log "Objectivo: validar ciclo Driver → SUT → Grafana → Jaeger"
  log "========================================================"

  local out="$RESULTS_DIR/demo_${DEMO_USERS}users"
  mkdir -p "$out"

  # Snapshot antes
  kubectl -n "$NAMESPACE" top pods --sort-by=cpu > "$out/pods_before.txt" 2>/dev/null
  kubectl -n "$NAMESPACE" get pods > "$out/pods_status_before.txt"

  log "A correr Locust (${DEMO_USERS} users, ${DEMO_DURATION}s)..."

  "$LOCUST_BIN" \
    --locustfile "$RESULTS_DIR/locustfile.py" \
    --host "$FRONTEND_URL" \
    --users "$DEMO_USERS" \
    --spawn-rate "$DEMO_USERS" \
    --run-time "${DEMO_DURATION}s" \
    --headless \
    --csv "$out/locust" \
    --html "$out/report.html" \
    --loglevel WARNING \
    2>> "$out/locust.log"

  # Snapshot depois
  kubectl -n "$NAMESPACE" top pods --sort-by=cpu > "$out/pods_after.txt" 2>/dev/null
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null | tail -20 > "$out/events.txt"

  # Resultados
  log ""
  log "=== RESULTADOS DEMO ==="
  if [ -f "$out/locust_stats.csv" ]; then
    python3 -c "
import csv
with open('$out/locust_stats.csv') as f:
    rows = list(csv.DictReader(f))
agg = [r for r in rows if r['Name']=='Aggregated']
rest = [r for r in rows if r['Name']!='Aggregated']
for row in rest + agg:
    print(f'  {row.get(\"Name\",\"?\")[:42]:<44} p50={row.get(\"50%\",\"?\"):>6}ms  p99={row.get(\"99%\",\"?\"):>6}ms  fails={row.get(\"Failure Count\",\"0\"):>5}  rps={row.get(\"Requests/s\",\"?\"):>6}')
" 2>/dev/null | tee -a "$RESULTS_DIR/run.log"
  fi

  log ""
  log "=== PRÓXIMOS PASSOS: GRAFANA (PDF §5) ==="
  cat << 'GRAFANA_EOF'
Abre o Grafana → Explore → Prometheus e corre estas queries no período do teste:

  1. CPU total do namespace:
     sum(rate(container_cpu_usage_seconds_total{namespace="ob", container!="", image!=""}[5m]))

  2. Top pods por CPU:
     topk(10, sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="ob", container!="", image!=""}[5m])))

  3. Top pods por memória:
     topk(10, sum by (pod) (container_memory_working_set_bytes{namespace="ob", container!="", image!=""}))

  4. Restarts de pods:
     sum by (pod) (kube_pod_container_status_restarts_total{namespace="ob"})

Dica: usa Table view (em vez de Graph) para queries de top pods e restarts.
GRAFANA_EOF

  log ""
  log "=== PRÓXIMOS PASSOS: JAEGER (PDF §6) ==="
  cat << 'JAEGER_EOF'
Abre o Jaeger UI → selecciona serviço "frontend" → Last 15 minutes → Find Traces.
  1. Abre um trace recente (do período do teste).
  2. Identifica a cadeia de serviços chamados (spans).
  3. Encontra o span mais lento.
  4. Confirma que não há spans com erro.
JAEGER_EOF

  log ""
  log "HTML: $out/report.html"
  log "CSV:  $out/locust_stats.csv"
}

# =============================================================================
# SECÇÃO 6 — MODO INCREMENTAL
# Igual ao script anterior mas com namespace "ob" e sem loadgenerator nativo.
# =============================================================================
find_breaking_point() {
  log "========================================================"
  log "MODO INCREMENTAL: 1 user → ${MAX_USERS} users"
  log "  Namespace       : ${NAMESPACE}"
  log "  Duração/step    : ${STEP_DURATION}s"
  log "  Cooldown        : ${COOLDOWN}s"
  log "  Limite p99      : ${P99_THRESHOLD}ms"
  log "  Limite falhas   : ${FAIL_THRESHOLD}%"
  log "========================================================"

  local breaking_point=0
  local breaking_reason=""
  local progress="$RESULTS_DIR/progresso_incremental.csv"
  echo "users,p50,p90,p99,fail_count,fail_pct,rps,status" > "$progress"

  for users in $(seq 10 10 "$MAX_USERS"); do
    local out="$RESULTS_DIR/step_${users}users"
    mkdir -p "$out"

    log "--- Step: ${users} user(s) ---"

    "$LOCUST_BIN" \
      --locustfile "$RESULTS_DIR/locustfile.py" \
      --host "$FRONTEND_URL" \
      --users "$users" \
      --spawn-rate "$users" \
      --run-time "${STEP_DURATION}s" \
      --headless \
      --csv "$out/locust" \
      --html "$out/report.html" \
      --loglevel WARNING \
      2>> "$out/locust.log"

    kubectl -n "$NAMESPACE" top pods --sort-by=cpu > "$out/top_pods.txt" 2>/dev/null

    local status="OK"
    if [ -f "$out/locust_stats.csv" ]; then
      result=$(python3 - "$out/locust_stats.csv" "$P99_THRESHOLD" "$FAIL_THRESHOLD" << 'PYEOF'
import csv, sys
csv_file  = sys.argv[1]
p99_limit = int(sys.argv[2])
fail_limit = float(sys.argv[3])
with open(csv_file) as f:
    rows = list(csv.DictReader(f))
for row in rows:
    if row.get('Name') != 'Aggregated':
        continue
    total    = int(row.get('Request Count', 0) or 0)
    failures = int(row.get('Failure Count', 0) or 0)
    p50  = row.get('50%', '0') or '0'
    p90  = row.get('90%', '0') or '0'
    p99  = row.get('99%', '0') or '0'
    rps  = row.get('Requests/s', '0') or '0'
    fail_pct = (failures / total * 100) if total > 0 else 0
    p99_val  = int(p99) if str(p99).isdigit() else 0
    if failures > 0 and fail_pct >= fail_limit:
        status = f"QUEBRA_FALHAS({fail_pct:.1f}%)"
    elif p99_val >= p99_limit:
        status = f"QUEBRA_LATENCIA(p99={p99}ms)"
    else:
        status = "OK"
    print(f"{p50},{p90},{p99},{failures},{fail_pct:.1f},{rps},{status}")
    break
PYEOF
)
      if [ -n "$result" ]; then
        echo "${users},${result}" >> "$progress"
        status=$(echo "$result" | cut -d',' -f7)
        p50=$(echo "$result" | cut -d',' -f1)
        p90=$(echo "$result" | cut -d',' -f2)
        p99=$(echo "$result" | cut -d',' -f3)
        fail=$(echo "$result" | cut -d',' -f4)
        rps=$(echo "$result" | cut -d',' -f6)
        log "  ${users} users → p50=${p50}ms  p90=${p90}ms  p99=${p99}ms  falhas=${fail}  rps=${rps}  [${status}]"
      fi
    fi

    if [[ "$status" == QUEBRA* ]]; then
      breaking_point=$users
      breaking_reason=$status
      log "========================================================"
      log "PONTO DE QUEBRA: ${users} users — ${breaking_reason}"
      log "========================================================"
      break
    fi

    sleep "$COOLDOWN"
  done

  if [ $breaking_point -eq 0 ]; then
    log "Sistema aguentou até ${MAX_USERS} users sem quebrar."
    log "Aumenta MAX_USERS para continuar: MAX_USERS=100 $0 incremental"
  fi

  log ""
  log "=== PROGRESSO COMPLETO ==="
  column -t -s',' "$progress" 2>/dev/null || cat "$progress"
  log ""
  log "CSV: $progress"
}

# =============================================================================
# SECÇÃO 7 — RELATÓRIO FINAL
# =============================================================================
generate_report() {
  local report="$RESULTS_DIR/RESUMO.txt"
  log "A gerar resumo..."

  cat > "$report" << REPORT_EOF
=============================================================================
ASID 2025/2026 — Tema 2: Escalabilidade Horizontal
Online Boutique — Resumo de Testes
Namespace: ${NAMESPACE}
Gerado em: $(date)
=============================================================================

CONFIGURAÇÃO INICIAL
--------------------
$(cat "$RESULTS_DIR/baseline/resources_config.txt" 2>/dev/null || echo "(baseline não encontrado)")

FASES EXECUTADAS
----------------
REPORT_EOF

  for dir in "$RESULTS_DIR"/step_* "$RESULTS_DIR"/demo_*; do
    [ -d "$dir" ] || continue
    phase=$(basename "$dir")
    [ -f "$dir/locust_stats.csv" ] || continue
    echo "" >> "$report"
    echo "--- $phase ---" >> "$report"
    python3 -c "
import csv
with open('$dir/locust_stats.csv') as f:
    rows = list(csv.DictReader(f))
for row in rows:
    if row.get('Name') == 'Aggregated':
        print(f'  Pedidos : {row.get(\"Request Count\",\"?\")}')
        print(f'  Falhas  : {row.get(\"Failure Count\",\"?\")}')
        print(f'  p50={row.get(\"50%\",\"?\")}ms  p90={row.get(\"90%\",\"?\")}ms  p99={row.get(\"99%\",\"?\")}ms')
        print(f'  RPS     : {row.get(\"Requests/s\",\"?\")}')
" 2>/dev/null >> "$report"
  done

  # Inclui o progresso incremental se existir
  if [ -f "$RESULTS_DIR/progresso_incremental.csv" ]; then
    echo "" >> "$report"
    echo "PROGRESSO INCREMENTAL (users → métricas)" >> "$report"
    echo "----------------------------------------" >> "$report"
    column -t -s',' "$RESULTS_DIR/progresso_incremental.csv" 2>/dev/null >> "$report" || \
      cat "$RESULTS_DIR/progresso_incremental.csv" >> "$report"
  fi

  cat >> "$report" << 'REPORT_EOF2'

=============================================================================
QUERIES PROMETHEUS PARA O RELATÓRIO (Grafana Explore)
-----------------------------------------------------------------------------
CPU namespace:
  sum(rate(container_cpu_usage_seconds_total{namespace="ob",container!="",image!=""}[5m]))

Top pods CPU:
  topk(10, sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="ob",container!="",image!=""}[5m])))

Top pods memória:
  topk(10, sum by (pod) (container_memory_working_set_bytes{namespace="ob",container!="",image!=""}))

Restarts:
  sum by (pod) (kube_pod_container_status_restarts_total{namespace="ob"})
=============================================================================
REPORT_EOF2

  log "Resumo: $report"
  cat "$report"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  case "${1:-}" in

    # Pausar o loadgenerator nativo (sem precisar de executar testes)
    pause_lg)
      pause_lg_standalone
      ;;

    # Retomar o loadgenerator nativo
    resume_lg)
      resume_lg_standalone
      ;;

    # Baseline apenas
    baseline)
      check_prerequisites
      capture_baseline
      ;;

    # Demo: run único de validação (PDF §4)
    demo)
      check_prerequisites
      capture_baseline
      create_locustfile
      [ "$DISABLE_LG" = "true" ] && pause_loadgenerator
      run_demo
      [ "$DISABLE_LG" = "true" ] && resume_loadgenerator
      generate_report
      ;;

    # Incremental: 1 user → MAX_USERS até quebrar
    incremental)
      check_prerequisites
      capture_baseline
      create_locustfile
      [ "$DISABLE_LG" = "true" ] && pause_loadgenerator
      start_monitoring 10
      find_breaking_point
      stop_monitoring
      [ "$DISABLE_LG" = "true" ] && resume_loadgenerator
      generate_report
      ;;

    # Gerar relatório de resultados existentes
    report)
      generate_report
      ;;

    # Ajuda
    *)
      cat << 'HELP_EOF'
Uso: ./testes_cenarios_ob.sh [MODO]

MODOS:
  demo          run único de validação — confirma ciclo Driver→SUT→Grafana→Jaeger
  incremental   1 user → MAX_USERS até o sistema quebrar
  baseline      captura estado inicial do cluster
  pause_lg      pausa o loadgenerator nativo do repositório
  resume_lg     retoma o loadgenerator nativo
  report        gera resumo de resultados já existentes

VARIÁVEIS OPCIONAIS:
  HOST_IP=34.x.x.x       IP do nó GKE (obrigatório em GKE; omitir em Docker Desktop)
  NAMESPACE=ob           namespace Kubernetes (default: ob)
  DISABLE_LG=true        pausar loadgenerator nativo antes dos testes (default: true)
  MAX_USERS=60           limite de users no modo incremental (default: 60)
  STEP_DURATION=60       segundos por step (default: 60)
  DEMO_USERS=10          users no modo demo (default: 10)
  DEMO_DURATION=120      segundos do modo demo (default: 120)
  P99_THRESHOLD=2000     ms de p99 para quebra (default: 2000)
  FAIL_THRESHOLD=5       % falhas para quebra (default: 5)

EXEMPLOS:
  # GKE — demo de validação
  HOST_IP=34.90.1.2 ./testes_cenarios_ob.sh demo

  # GKE — teste incremental até 80 users
  HOST_IP=34.90.1.2 MAX_USERS=80 ./testes_cenarios_ob.sh incremental

  # Docker Desktop — não desativar loadgenerator nativo
  NAMESPACE=default DISABLE_LG=false ./testes_cenarios_ob.sh incremental

  # Pausar/retomar o loadgenerator manualmente
  NAMESPACE=ob ./testes_cenarios_ob.sh pause_lg
  NAMESPACE=ob ./testes_cenarios_ob.sh resume_lg
HELP_EOF
      ;;
  esac
}

main "$@"