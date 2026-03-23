#!/bin/bash
# =============================================================================
# cleanup.sh — Elimina todos os recursos do Online Boutique do Docker Desktop
# Liberta CPU, RAM e disco ocupados pelo cluster Kubernetes
# =============================================================================
NAMESPACE="${NAMESPACE:-default}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "A eliminar todos os recursos do namespace '$NAMESPACE'..."

# 1. Apagar todos os recursos criados pelos manifests
kubectl delete -f kubernetes-manifests/ --ignore-not-found 2>/dev/null && \
  log "Manifests eliminados." || \
  log "AVISO: alguns manifests não encontrados (já apagados?)."

# 2. Garantir que não ficam pods a correr (por ex. se foram criados manualmente)
kubectl -n "$NAMESPACE" delete deployment --all --ignore-not-found 2>/dev/null
kubectl -n "$NAMESPACE" delete service    --all --ignore-not-found 2>/dev/null
kubectl -n "$NAMESPACE" delete configmap  --all --ignore-not-found 2>/dev/null
kubectl -n "$NAMESPACE" delete pvc        --all --ignore-not-found 2>/dev/null
kubectl -n "$NAMESPACE" delete hpa        --all --ignore-not-found 2>/dev/null

# 3. Aguardar que todos os pods terminem
log "A aguardar que os pods terminem..."
kubectl -n "$NAMESPACE" wait --for=delete pod --all --timeout=60s 2>/dev/null
log "Pods eliminados."

# 4. Limpar imagens Docker não utilizadas (liberta disco)
log "A limpar imagens Docker não utilizadas..."
docker image prune -f 2>/dev/null && log "Imagens limpas." || log "AVISO: Docker não acessível."

# 5. Limpar volumes Docker não utilizados
docker volume prune -f 2>/dev/null && log "Volumes limpos." || true

log ""
log "=== LIMPEZA CONCLUÍDA ==="
log "Para verificar: kubectl get all -n $NAMESPACE"
log "Para desligar o Kubernetes completamente: Docker Desktop → Settings → Kubernetes → Disable"
