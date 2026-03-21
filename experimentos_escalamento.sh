#!/bin/bash
# =============================================================================
# ASID 2025/2026 — Tema 2: Escalabilidade Horizontal e Custo Marginal
# Script de Experimentação — Online Boutique no Kubernetes (Docker Desktop)
# =============================================================================
# DESCRIÇÃO:
#   Este script automatiza os testes de escalabilidade do sistema Online Boutique
#   em Kubernetes. Começa com 1 utilizador virtual e vai incrementando 1 por step
#   até o sistema quebrar (alta latência ou muitos erros) ou atingir MAX_USERS.
#
# COMO USAR:
#   chmod +x experimentos_escalamento.sh           # dar permissão de execução
#   ./experimentos_escalamento.sh incremental      # modo recomendado
#   ./experimentos_escalamento.sh baseline         # só captura estado inicial
#   ./experimentos_escalamento.sh monitor          # só monitorização contínua
#   ./experimentos_escalamento.sh report           # gera resumo dos resultados
#
# VARIÁVEIS OPCIONAIS (passar antes do comando):
#   MAX_USERS=80        número máximo de utilizadores (default: 60)
#   STEP_DURATION=90    segundos por step (default: 60)
#   P99_THRESHOLD=3000  ms de p99 para considerar quebra (default: 2000)
#   FAIL_THRESHOLD=2    % de falhas para considerar quebra (default: 5)
#
# EXEMPLO:
#   MAX_USERS=30 STEP_DURATION=30 ./experimentos_escalamento.sh incremental
# =============================================================================

# URL do frontend a testar. Por omissão aponta para localhost (Docker Desktop).
# Em GKE substituir pelo EXTERNAL-IP do serviço frontend.
FRONTEND_URL="${FRONTEND_URL:-http://localhost}"

# Nome da pasta de resultados com data e hora para não sobrescrever corridas anteriores.
# Exemplo: resultados_20260308_180646/
RESULTS_DIR="resultados_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

# Função auxiliar de logging: imprime a mensagem com timestamp no terminal
# e guarda também no ficheiro run.log dentro da pasta de resultados.
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RESULTS_DIR/run.log"; }

# =============================================================================
# SECÇÃO 0 — PRÉ-REQUISITOS
# Verifica se todas as ferramentas necessárias estão disponíveis antes de
# iniciar qualquer teste. Se algo falhar, o script termina com erro.
# =============================================================================
check_prerequisites() {
  log "A verificar pré-requisitos..."

  # Verifica se o kubectl consegue comunicar com o cluster Kubernetes.
  # Se o Docker Desktop não tiver o Kubernetes activado, este comando falha.
  kubectl cluster-info > /dev/null 2>&1 || { log "ERRO: kubectl não conectado ao cluster"; exit 1; }

  # Verifica se o metrics-server está instalado.
  # O metrics-server é necessário para o comando "kubectl top" funcionar —
  # sem ele não conseguimos ver o consumo de CPU e RAM dos pods.
  kubectl top nodes > /dev/null 2>&1 || {
    log "metrics-server não encontrado. A instalar..."
    # Instala o metrics-server a partir do repositório oficial
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    log "Aguarda 60s para o metrics-server arrancar..."
    sleep 60
  }

  # Localiza o binário do Locust.
  # No macOS, o pip instala programas em ~/Library/Python/3.x/bin/ que não está
  # no PATH padrão do bash/zsh. Por isso é necessário procurá-lo manualmente.
  LOCUST_BIN=$(which locust 2>/dev/null)

  # Se não encontrou no PATH, procura na pasta típica do pip no macOS
  if [ -z "$LOCUST_BIN" ]; then
    LOCUST_BIN=$(find ~/Library/Python -name "locust" -type f 2>/dev/null | head -1)
  fi

  # Se ainda não encontrou, instala o Locust via pip e tenta de novo
  if [ -z "$LOCUST_BIN" ]; then
    log "locust não encontrado, a instalar..."
    pip3 install locust faker --quiet 2>/dev/null
    LOCUST_BIN=$(find ~/Library/Python -name "locust" -type f 2>/dev/null | head -1)
  fi

  # Se após instalação ainda não encontrou, o script não pode continuar
  [ -z "$LOCUST_BIN" ] && { log "ERRO: locust não encontrado após instalação"; exit 1; }

  # Exporta a variável para que fique disponível em todas as funções do script
  export LOCUST_BIN
  log "Locust encontrado: $LOCUST_BIN"
  log "Pré-requisitos OK"
}

# =============================================================================
# SECÇÃO 1 — BASELINE
# Captura o estado inicial do cluster ANTES de qualquer carga.
# Estes dados servem de referência para comparar o comportamento do sistema
# sob stress com o seu estado em repouso.
# =============================================================================
capture_baseline() {
  log "=== BASELINE: captura estado inicial ==="
  local out="$RESULTS_DIR/baseline"
  mkdir -p "$out"

  # Lista todos os deployments com informação detalhada (réplicas, imagem, etc.)
  kubectl get deployments -o wide > "$out/deployments.txt"

  # Gera uma tabela formatada com os limites de recursos de cada serviço:
  # CPU request (garantido), CPU limit (máximo), Mem request, Mem limit
  kubectl get deployments -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f'{'Serviço':<30} {'Réplicas':<10} {'CPU req':<12} {'CPU lim':<12} {'Mem req':<12} {'Mem lim':<12}')
print('-'*90)
for d in data['items']:
    name = d['metadata']['name']
    spec = d['spec']
    replicas = spec.get('replicas', 1)
    containers = spec['template']['spec']['containers']
    for c in containers:
        res = c.get('resources', {})
        req = res.get('requests', {})
        lim = res.get('limits', {})
        print(f'{name:<30} {replicas:<10} {req.get(\"cpu\",\"n/a\"):<12} {lim.get(\"cpu\",\"n/a\"):<12} {req.get(\"memory\",\"n/a\"):<12} {lim.get(\"memory\",\"n/a\"):<12}')
" | tee "$out/resources_config.txt"

  # Consumo real de CPU e RAM de cada pod em repouso (sem carga)
  kubectl top pods --sort-by=cpu > "$out/top_pods_idle.txt" 2>&1

  # Consumo do nó Kubernetes (o próprio Docker Desktop)
  kubectl top nodes > "$out/top_nodes_idle.txt" 2>&1

  # Estado de todos os pods: Running, Pending, CrashLoopBackOff, etc.
  kubectl get pods -o wide > "$out/pods_status.txt"

  # Verifica se existe Horizontal Pod Autoscaler (HPA).
  # Na fase baseline não deve haver nenhum — os testes correm sem auto-scaling.
  kubectl get hpa > "$out/hpa_inicial.txt" 2>&1

  log "Baseline guardado em $out/"
}

# =============================================================================
# SECÇÃO 2 — MONITORIZAÇÃO CONTÍNUA
# Lança um processo filho em background que recolhe métricas do cluster
# de 10 em 10 segundos, enquanto os testes de carga correm em paralelo.
# =============================================================================
start_monitoring() {
  local interval=${1:-15}  # intervalo em segundos entre cada snapshot (default: 15s)
  local out="$RESULTS_DIR/monitoring"
  mkdir -p "$out"
  log "A iniciar monitorização (intervalo: ${interval}s) → $out/"

  # O bloco ( ... ) & lança um subshell em background.
  # Isto permite que a monitorização corra em paralelo com o Locust.
  (
    i=0  # contador de snapshots
    while true; do
      ts=$(date +%H:%M:%S)  # timestamp do momento

      # Recolhe CPU e RAM de todos os pods e guarda em CSV.
      # O awk salta o cabeçalho (NR>1) e formata: timestamp,snapshot,pod,cpu,ram
      kubectl top pods --sort-by=cpu 2>/dev/null | \
        awk -v ts="$ts" -v i="$i" 'NR>1{print ts","i","$1","$2","$3}' \
        >> "$out/pods_metrics.csv"

      # Detecção de crashes: regista qualquer pod com restarts > 0.
      # Um restart pode indicar OOMKill (falta de memória) ou crash do processo.
      kubectl get pods --no-headers 2>/dev/null | \
        awk -v ts="$ts" '$4>0{print ts" RESTART pod="$1" restarts="$4}' \
        >> "$out/restarts.log"

      i=$((i+1))
      sleep "$interval"
    done
  ) &

  # Guarda o PID do processo de monitorização para o terminar mais tarde
  MONITOR_PID=$!
  echo $MONITOR_PID > "$RESULTS_DIR/monitor.pid"
  log "Monitor PID: $MONITOR_PID"
}

# Termina o processo de monitorização em background
stop_monitoring() {
  if [ -f "$RESULTS_DIR/monitor.pid" ]; then
    kill "$(cat "$RESULTS_DIR/monitor.pid")" 2>/dev/null
    log "Monitorização parada"
  fi
}

# =============================================================================
# SECÇÃO 3 — FICHEIRO DE TESTE LOCUST
# Cria o ficheiro Python que define o comportamento dos utilizadores virtuais.
# O Locust simula utilizadores reais a navegar na loja — cada um executa
# tarefas com pesos diferentes (frequência relativa).
# =============================================================================
create_locustfile() {
# Usa heredoc para escrever o ficheiro Python directamente
cat > "$RESULTS_DIR/locustfile.py" << 'LOCUST_EOF'
from locust import HttpUser, task, between
import random

# IDs dos 9 produtos disponíveis na loja Online Boutique
PRODUCT_IDS = [
    "OLJCESPC7Z", "66VCHSJNUP", "1YMWWN1N4O",
    "L9ECAV7KIM", "2ZYFJ3GM2N", "0PUK6V6EV0",
    "LS4PSXUNUM", "9SIQT8TOJO", "6E92ZMYYFZ"
]

class OnlineBoutiqueUser(HttpUser):
    # Cada utilizador espera entre 0.5 e 1 segundo entre pedidos.
    # Simula utilizadores frequentes (ex: Black Friday).
    # Valores mais baixos = mais pressão no sistema.
    wait_time = between(0.5, 1)

    # Peso 10: ver produto é a acção mais frequente (43% do total).
    # Chama o productcatalogservice via frontend.
    @task(10)
    def browse_product(self):
        pid = random.choice(PRODUCT_IDS)
        self.client.get(f"/product/{pid}", name="/product/[id]")

    # Peso 5: página inicial (22% do total).
    # Chama productcatalogservice + recommendationservice + currencyservice.
    @task(5)
    def index(self):
        self.client.get("/")

    # Peso 3: adicionar ao carrinho (13% do total).
    # Chama cartservice + productcatalogservice. Usa data= (form POST) em vez
    # de json= porque o frontend espera application/x-www-form-urlencoded.
    @task(3)
    def add_to_cart(self):
        pid = random.choice(PRODUCT_IDS)
        self.client.post("/cart", data={"product_id": pid, "quantity": "1"}, name="/cart [add]")

    # Peso 2: ver carrinho (9% do total).
    # Chama cartservice para listar os itens.
    @task(2)
    def view_cart(self):
        self.client.get("/cart")

    # Peso 1: checkout (4% do total) — a operação mais pesada.
    # Chama 6 microserviços em cadeia: currency → cart → product →
    # shipping → payment → email. Por isso o peso é baixo.
    @task(1)
    def checkout(self):
        # Garante que há pelo menos um item no carrinho antes do checkout.
        # Sem isto o servidor devolve 422 (Unprocessable Entity).
        pid = random.choice(PRODUCT_IDS)
        self.client.post("/cart", data={"product_id": pid, "quantity": "1"}, name="/cart [add]")
        self.client.post("/cart/checkout", data={
            "email": "test@asid.uc.pt",
            "street_address": "123 Main St",
            "zip_code": "10001",
            "city": "New York",
            "state": "NY",
            "country": "United States",
            "credit_card_number": "4432801561520454",
            "credit_card_expiration_month": "1",
            "credit_card_expiration_year": "2030",
            "credit_card_cvv": "672"
        }, name="/cart/checkout")

    # Peso 2: mudar a moeda (9% do total).
    # Chama o currencyservice para converter preços.
    @task(2)
    def set_currency(self):
        currency = random.choice(["EUR", "USD", "GBP", "JPY"])
        self.client.post("/setCurrency", data={"currency_code": currency})
LOCUST_EOF
  log "locustfile.py criado"
}

# =============================================================================
# SECÇÃO 4 — FASE DE CARGA (modo manual/fixo)
# Corre o Locust com um número fixo de utilizadores durante um tempo fixo.
# Usado pelo modo "all" para fases pré-definidas (ex: 5, 25, 100 users).
# Para o modo incremental usa-se find_breaking_point() em vez desta função.
# =============================================================================
run_load_phase() {
  local phase_name=$1   # nome da fase (ex: "A", "B", "baseline")
  local users=$2        # número de utilizadores simultâneos
  local duration=$3     # duração (ex: "5m", "300s")
  local out="$RESULTS_DIR/fase_${phase_name}_${users}users"
  mkdir -p "$out"

  log "=== FASE ${phase_name}: ${users} utilizadores, ${duration} ==="

  # Snapshot do consumo de CPU/RAM antes de iniciar a carga
  kubectl top pods --sort-by=cpu > "$out/pods_before.txt" 2>/dev/null
  kubectl get pods > "$out/pods_status_before.txt"

  # Corre o Locust em modo headless (sem interface gráfica).
  # --spawn-rate: quantos utilizadores por segundo são lançados até chegar ao total
  # --csv: guarda os resultados em ficheiros CSV para análise posterior
  # --html: gera um relatório visual interactivo
  locust \
    --locustfile "$RESULTS_DIR/locustfile.py" \
    --host "$FRONTEND_URL" \
    --users "$users" \
    --spawn-rate "$((users / 10 > 0 ? users / 10 : 1))" \
    --run-time "$duration" \
    --headless \
    --csv "$out/locust" \
    --html "$out/report.html" \
    --loglevel WARNING \
    2>> "$out/locust.log"

  # Snapshot do consumo de CPU/RAM depois da carga
  kubectl top pods --sort-by=cpu > "$out/pods_after.txt" 2>/dev/null
  kubectl get pods > "$out/pods_status_after.txt"

  # Eventos recentes do cluster (crashes, OOMKill, etc.)
  kubectl get events --sort-by=.lastTimestamp 2>/dev/null | tail -20 > "$out/events.txt"

  # Extrai e imprime as métricas-chave do CSV gerado pelo Locust
  log "Resultados fase ${phase_name} (${users} users):"
  if [ -f "$out/locust_stats.csv" ]; then
    python3 -c "
import csv
with open('$out/locust_stats.csv') as f:
    rows = list(csv.DictReader(f))
# Mostra a linha 'Aggregated' por último (resumo total)
agg = [r for r in rows if r['Name']=='Aggregated']
rest = [r for r in rows if r['Name']!='Aggregated']
for row in rest + agg:
    p50 = row.get('50%','n/a')
    p90 = row.get('90%','n/a')
    p99 = row.get('99%','n/a')
    fail = row.get('Failure Count','0')
    rps  = row.get('Requests/s','n/a')
    name = row.get('Name','?')[:40]
    print(f'  {name:<42} p50={p50}ms  p90={p90}ms  p99={p99}ms  fail={fail}  rps={rps}')
" 2>/dev/null | tee -a "$RESULTS_DIR/run.log"
  fi

  log "Resultados em $out/"
}

# =============================================================================
# SECÇÃO 5 — SNAPSHOT PONTUAL DE RECURSOS
# Tira uma fotografia instantânea do consumo de CPU/RAM.
# Útil para comparar o estado do cluster entre fases diferentes.
# =============================================================================
snapshot_resources() {
  local label=$1  # etiqueta para identificar o snapshot (ex: "antes_escala")
  local out="$RESULTS_DIR/snapshots"
  mkdir -p "$out"
  kubectl top pods --sort-by=cpu 2>/dev/null > "$out/top_${label}.txt"
  kubectl get pods -o wide 2>/dev/null > "$out/pods_${label}.txt"
  log "Snapshot '$label' guardado"
}

# =============================================================================
# SECÇÃO 6 — RELATÓRIO FINAL
# Consolida os resultados de todas as fases num único ficheiro de texto.
# Lê os CSVs de cada step e extrai as métricas agregadas.
# =============================================================================
generate_report() {
  local report="$RESULTS_DIR/RESUMO_EXPERIMENTOS.txt"
  log "A gerar resumo..."

  # Cabeçalho do relatório
  cat > "$report" << REPORT_EOF
=============================================================================
ASID 2025/2026 — Tema 2: Escalabilidade Horizontal
Resumo dos Experimentos — Online Boutique
Gerado em: $(date)
=============================================================================

CONFIGURAÇÃO INICIAL (ver baseline/resources_config.txt)
---------------------------------------------------------

FASES EXECUTADAS
---------------------------------------------------------
Fase      Utilizadores  Duração
REPORT_EOF

  # Itera sobre todas as pastas de fase e extrai as métricas do CSV
  for dir in "$RESULTS_DIR"/fase_*; do
    [ -d "$dir" ] || continue
    phase=$(basename "$dir")
    if [ -f "$dir/locust_stats.csv" ]; then
      echo "" >> "$report"
      echo "--- $phase ---" >> "$report"
      python3 -c "
import csv
with open('$dir/locust_stats.csv') as f:
    rows = list(csv.DictReader(f))
for row in rows:
    if row.get('Name') == 'Aggregated':
        print(f'  Total req: {row.get(\"Request Count\",\"?\")}')
        print(f'  Falhas:    {row.get(\"Failure Count\",\"?\")}')
        print(f'  p50: {row.get(\"50%\",\"?\")}ms  p90: {row.get(\"90%\",\"?\")}ms  p99: {row.get(\"99%\",\"?\")}ms')
        print(f'  RPS: {row.get(\"Requests/s\",\"?\")}')
" 2>/dev/null >> "$report"
    fi
  done

  # Rodapé com sugestões de próximos passos
  cat >> "$report" << REPORT_EOF2

=============================================================================
PRÓXIMOS PASSOS
-----------------------------------------------------------------------------
1. Identifica o serviço com maior CPU em kubectl top pods durante carga alta
2. Escala esse serviço: kubectl scale deployment <nome> --replicas=3
3. Repete a fase de carga e compara os p99
4. Documenta: latência antes/depois, custo marginal (réplicas adicionais)
=============================================================================
REPORT_EOF2

  log "Resumo: $report"
  cat "$report"
}

# =============================================================================
# SECÇÃO 7 — PONTO DE QUEBRA (modo incremental)
# Núcleo do script. Aumenta 1 utilizador por step até o sistema quebrar.
#
# CRITÉRIOS DE QUEBRA (configuráveis via variáveis de ambiente):
#   - Taxa de falhas > FAIL_THRESHOLD % (default: 5%)
#     → O servidor está a rejeitar pedidos (erros 4xx/5xx/timeout)
#   - p99 > P99_THRESHOLD ms (default: 2000ms)
#     → 1% dos utilizadores espera mais de 2 segundos
#
# FLUXO POR STEP:
#   1. Corre Locust com N users durante STEP_DURATION segundos
#   2. Lê o CSV de resultados e analisa com Python
#   3. Se quebra → regista e para; se OK → espera COOLDOWN e avança
# =============================================================================

# Parâmetros configuráveis (podem ser substituídos por variáveis de ambiente)
P99_THRESHOLD="${P99_THRESHOLD:-2000}"   # ms — p99 acima disto = degradação inaceitável
FAIL_THRESHOLD="${FAIL_THRESHOLD:-5}"    # % falhas acima disto = sistema a falhar
MAX_USERS="${MAX_USERS:-60}"             # limite de segurança para não correr indefinidamente
STEP_DURATION="${STEP_DURATION:-60}"     # segundos de carga por step
COOLDOWN="${COOLDOWN:-15}"               # segundos de pausa entre steps (deixa o sistema estabilizar)

find_breaking_point() {
  log "========================================================"
  log "MODO INCREMENTAL: 1 user → ${MAX_USERS} users"
  log "  Duração por step : ${STEP_DURATION}s"
  log "  Cooldown          : ${COOLDOWN}s"
  log "  Limite p99        : ${P99_THRESHOLD}ms"
  log "  Limite falhas     : ${FAIL_THRESHOLD}%"
  log "========================================================"

  local breaking_point=0      # número de users no momento da quebra (0 = não quebrou)
  local breaking_reason=""    # razão da quebra (QUEBRA_FALHAS ou QUEBRA_LATENCIA)

  # Ficheiro CSV de progresso actualizado em tempo real após cada step
  local progress="$RESULTS_DIR/progresso_incremental.csv"
  echo "users,p50,p90,p99,fail_count,fail_pct,rps,status" > "$progress"

  # Loop principal: de 1 até MAX_USERS, incrementando 1 por step
  for users in $(seq 1 1 "$MAX_USERS"); do
    local out="$RESULTS_DIR/step_${users}users"
    mkdir -p "$out"

    log "--- Step: ${users} user(s) ---"

    # Corre o Locust em modo headless para este step.
    # --spawn-rate igual a --users para lançar todos os utilizadores de imediato.
    # Os resultados ficam guardados em CSV e HTML para análise posterior.
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

    # Snapshot de CPU/RAM de todos os pods imediatamente após o step
    kubectl top pods --sort-by=cpu > "$out/top_pods.txt" 2>/dev/null

    # Analisa o CSV com Python para decidir se o sistema quebrou.
    # Lê a linha "Aggregated" que contém os totais de todos os endpoints.
    local status="OK"
    if [ -f "$out/locust_stats.csv" ]; then
      result=$(python3 - "$out/locust_stats.csv" "$P99_THRESHOLD" "$FAIL_THRESHOLD" << 'PYEOF'
import csv, sys

csv_file   = sys.argv[1]   # caminho para o ficheiro CSV do Locust
p99_limit  = int(sys.argv[2])    # limiar de p99 em ms
fail_limit = float(sys.argv[3])  # limiar de taxa de falhas em %

with open(csv_file) as f:
    rows = list(csv.DictReader(f))

for row in rows:
    # Só nos interessa a linha "Aggregated" — os totais de todos os endpoints
    if row.get('Name') != 'Aggregated':
        continue

    total    = int(row.get('Request Count', 0) or 0)
    failures = int(row.get('Failure Count', 0) or 0)
    p50      = row.get('50%', '0') or '0'   # mediana das latências
    p90      = row.get('90%', '0') or '0'   # percentil 90
    p99      = row.get('99%', '0') or '0'   # percentil 99 (mais sensível)
    rps      = row.get('Requests/s', '0') or '0'  # throughput
    fail_pct = (failures / total * 100) if total > 0 else 0

    p99_val  = int(p99) if p99.isdigit() else 0

    # Critério 1: taxa de falhas acima do limiar
    if failures > 0 and fail_pct >= fail_limit:
        status = f"QUEBRA_FALHAS({fail_pct:.1f}%)"
    # Critério 2: p99 acima do limiar de latência
    elif p99_val >= p99_limit:
        status = f"QUEBRA_LATENCIA(p99={p99}ms)"
    else:
        status = "OK"

    # Imprime os resultados numa linha CSV para o script bash processar
    print(f"{p50},{p90},{p99},{failures},{fail_pct:.1f},{rps},{status}")
    break
PYEOF
)
      if [ -n "$result" ]; then
        # Guarda o resultado no ficheiro de progresso
        echo "${users},${result}" >> "$progress"

        # Extrai cada campo do resultado CSV
        status=$(echo "$result" | cut -d',' -f7)
        p50=$(echo "$result" | cut -d',' -f1)
        p90=$(echo "$result" | cut -d',' -f2)
        p99=$(echo "$result" | cut -d',' -f3)
        fail=$(echo "$result" | cut -d',' -f4)
        rps=$(echo "$result" | cut -d',' -f6)

        log "  ${users} users → p50=${p50}ms  p90=${p90}ms  p99=${p99}ms  falhas=${fail}  rps=${rps}  [${status}]"
      fi
    fi

    # Verifica se o status indica quebra (começa por "QUEBRA")
    if [[ "$status" == QUEBRA* ]]; then
      breaking_point=$users
      breaking_reason=$status
      log "========================================================"
      log "PONTO DE QUEBRA ENCONTRADO: ${users} users"
      log "   Razão: ${breaking_reason}"
      log "========================================================"
      break  # para o loop — ponto de quebra encontrado
    fi

    # Pausa entre steps para o sistema estabilizar antes do próximo step.
    # Sem esta pausa o sistema pode começar o próximo step ainda sobrecarregado.
    sleep "$COOLDOWN"
  done

  # Mensagem final se chegou ao limite sem quebrar
  if [ $breaking_point -eq 0 ]; then
    log "Sistema aguentou até ${MAX_USERS} users sem quebrar (limite MAX_USERS atingido)"
    log "Aumenta MAX_USERS para continuar: MAX_USERS=100 ./experimentos_escalamento.sh incremental"
  fi

  # Imprime a tabela completa de progresso no terminal
  log ""
  log "=== PROGRESSO COMPLETO ==="
  cat "$progress" | column -t -s','
  log ""
  log "CSV completo: $progress"
}

# =============================================================================
# MAIN — ponto de entrada do script
# Interpreta o argumento passado na linha de comandos e chama a função certa.
# =============================================================================
main() {
  case "${1:-all}" in

    # Modo monitor: só lança a monitorização contínua, sem testes de carga.
    # Útil para observar o cluster manualmente enquanto se fazem testes manuais.
    monitor)
      start_monitoring 15
      log "Monitorização activa. Ctrl+C para parar."
      wait
      ;;

    # Modo baseline: só captura o estado inicial do cluster.
    # Útil para verificar a configuração antes de iniciar testes.
    baseline)
      check_prerequisites
      capture_baseline
      ;;

    # Modo all: executa fases de carga fixas (não incremental).
    # Inclui monitorização e relatório final.
    all)
      check_prerequisites
      capture_baseline
      create_locustfile
      start_monitoring 10
      find_breaking_point
      stop_monitoring
      generate_report
      ;;

    # Modo report: gera o resumo a partir de resultados já existentes.
    # Útil se o script foi interrompido e se quer gerar o relatório manualmente.
    report)
      generate_report
      ;;

    # Modo incremental (RECOMENDADO): 1 user → 2 → 3 → ... até quebrar.
    # Executa baseline, monitorização, testes incrementais e relatório final.
    incremental)
      check_prerequisites
      capture_baseline
      create_locustfile
      start_monitoring 10
      find_breaking_point
      stop_monitoring
      generate_report
      ;;

    # Se o argumento não é reconhecido, mostra a ajuda
    *)
      echo "Uso: $0 [all|incremental|baseline|monitor|report]"
      echo ""
      echo "  all          — fases fixas (5, 25, 100, 250 users)"
      echo "  incremental  — 1, 2, 3, 4... até quebrar (recomendado)"
      echo "  baseline     — só captura estado inicial"
      echo "  monitor      — só monitorização contínua"
      echo "  report       — gera resumo dos resultados existentes"
      echo ""
      echo "Variáveis opcionais:"
      echo "  MAX_USERS=80        número máximo de users (default: 60)"
      echo "  STEP_DURATION=90    segundos por step (default: 60)"
      echo "  P99_THRESHOLD=3000  ms de p99 para considerar quebra (default: 2000)"
      echo "  FAIL_THRESHOLD=2    % de falhas para considerar quebra (default: 5)"
      ;;
  esac
}

# Chama a função main passando todos os argumentos da linha de comandos
main "$@"
