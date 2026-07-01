#!/bin/bash
# ==========================================
#   NETSIMON 3.0 - LIMITER HÍBRIDO AVANÇADO
#   Controle preciso: SSH/WebSocket + UUID Xray
#   Detecta e expulsa duplicatas em tempo real
# ==========================================

USERDB="/etc/painel/usuarios.db"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_LOG="/var/log/xray/access.log"
LOG_LIMIT="/var/log/netsimon_limit.log"
BLOCKED="/etc/xray-manager/blocked.db"
XRAY_API="http://127.0.0.1:2000"

# Estado interno para rastrear sessões ativas por UUID
STATE_DIR="/tmp/netsimon_limiter"

RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YEL=$'\033[1;33m'
CYA=$'\033[1;36m'; W=$'\033[1;37m'; NC=$'\033[0m'

# Módulo Atlas — usado para sincronizar usuários criados direto no
# painel Atlas (sem passar pelo menu SSH) para o banco local
source /etc/painel/atlas.sh 2>/dev/null

# -------------------------------------------------------
# Garante diretório de estado
# -------------------------------------------------------
mkdir -p "$STATE_DIR"
touch "$LOG_LIMIT"
chmod 666 "$LOG_LIMIT"
[ ! -f "$XRAY_LOG" ] && touch "$XRAY_LOG" && chmod 666 "$XRAY_LOG"
[ ! -f "$BLOCKED" ] && touch "$BLOCKED"

log() {
    echo "$(date '+%d/%m/%Y %H:%M:%S') $1" >> "$LOG_LIMIT"
    [ "${DEBUG:-0}" = "1" ] && echo -e "$1"
}

# -------------------------------------------------------
# Conta conexões SSH ativas de um usuário
# Usa who/w para maior precisão que ps aux
# -------------------------------------------------------
count_ssh() {
    local user="$1"
    # who mostra sessões reais de login; -q não filtra corretamente usuários parciais
    local n
    n=$(who | awk -v u="$user" '$1 == u' | wc -l)
    # Fallback via sshd processes
    local n2
    n2=$(ps -u "$user" -o comm= 2>/dev/null | grep -c "sshd" || true)
    # Retorna o maior valor entre os dois métodos
    echo $(( n > n2 ? n : n2 ))
}

# -------------------------------------------------------
# Conta conexões Xray ativas para um usuário específico
# Usa a API interna do Xray (porta 2000) quando disponível
# Fallback: analisa o log com janela de tempo curta
#
# CORRIGIDO: o access.log do Xray NUNCA grava o UUID na linha,
# apenas o "email:" do cliente. O formato real de uma linha é:
#   DATA HORA IP:PORTA accepted tcp:destino:porta [tag >> tag] email: NOME
# ou seja o IP fica no campo 3, não no campo 6.
# -------------------------------------------------------
count_xray_uuid() {
    local user="$1"
    local count=0

    # Método 1: API interna do Xray (mais preciso)
    if command -v curl &>/dev/null; then
        local api_resp
        api_resp=$(curl -s --max-time 2 \
            -H "Content-Type: application/grpc" \
            "$XRAY_API" 2>/dev/null)
        # Se a API respondeu, tenta extrair
        if [ -n "$api_resp" ]; then
            count=$(echo "$api_resp" | grep -c "email: $user" 2>/dev/null || echo 0)
            [ "$count" -gt 0 ] && echo "$count" && return
        fi
    fi

    # Método 2: Conexões TCP estabelecidas na porta 443
    # O Xray registra o EMAIL (não o UUID) no access.log com "accepted"
    # Janela de 90 segundos para considerar "ativa"
    local now_epoch
    now_epoch=$(date +%s)
    count=$(grep -E "email: ${user}\$" "$XRAY_LOG" 2>/dev/null | grep "accepted" | \
        while read -r line; do
            # Extrai timestamp da linha do log (formato: YYYY/MM/DD HH:MM:SS)
            local ts
            ts=$(echo "$line" | awk '{print $1 " " $2}')
            local line_epoch
            line_epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
            local diff=$(( now_epoch - line_epoch ))
            # Considera ativa se a conexão foi registrada nos últimos 90 segundos
            [ "$diff" -le 90 ] && echo "1"
        done | wc -l)

    echo "$count"
}

# -------------------------------------------------------
# Conta IPs únicos conectados ao Xray por usuário
# (principal método anti-compartilhamento)
#
# CORRIGIDO: filtra por "email: $user" (o UUID não aparece no
# access.log) e extrai o IP do campo 3 (formato real: IP:PORTA
# fica logo após o timestamp, antes de "accepted").
# -------------------------------------------------------
count_xray_unique_ips() {
    local user="$1"
    local now_epoch
    now_epoch=$(date +%s)

    # Extrai IPs únicos de conexões aceitas nos últimos 90s para este usuário
    grep -E "email: ${user}\$" "$XRAY_LOG" 2>/dev/null | grep "accepted" | \
        while read -r line; do
            local ts; ts=$(echo "$line" | awk '{print $1 " " $2}')
            local line_epoch; line_epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
            local diff=$(( now_epoch - line_epoch ))
            if [ "$diff" -le 90 ]; then
                # Campo 3 = IP:PORTA de origem (ex: 181.77.128.16:54321)
                echo "$line" | awk '{print $3}' | cut -d: -f1
            fi
        done | grep -v "^127.0.0.1$" | grep -v "^$" | sort -u | wc -l
}

# -------------------------------------------------------
# Mata todas as conexões SSH de um usuário
# -------------------------------------------------------
kick_ssh() {
    local user="$1"
    # Envia SIGHUP para todas as sessões sshd do usuário
    pkill -KILL -u "$user" -f sshd 2>/dev/null
    pkill -KILL -u "$user" 2>/dev/null
    log "- SSH KICK: $user"
}

# -------------------------------------------------------
# Expulsa conexões Xray de um UUID
# Remove o cliente do config, reinicia e readiciona
# (expulsão cirúrgica sem derrubar outros usuários)
# -------------------------------------------------------
kick_xray_uuid() {
    local user="$1"
    local uuid="$2"

    if [ ! -f "$XRAY_CONF" ]; then
        log "- XRAY KICK falhou: config.json não encontrado"
        return 1
    fi

    # 1. Remove o cliente do config temporariamente
    local tmp; tmp=$(mktemp)
    jq --arg u "$user" \
        '(.inbounds[] | select(.port == 443)).settings.clients |= map(select(.email != $u))' \
        "$XRAY_CONF" > "$tmp" 2>/dev/null

    if ! jq . "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        log "- XRAY KICK: JSON inválido, abortando"
        return 1
    fi

    mv "$tmp" "$XRAY_CONF"
    systemctl restart xray >/dev/null 2>&1
    sleep 2

    # 2. Readiciona o usuário (conexão existente foi cortada, nova será aceita)
    local tmp2; tmp2=$(mktemp)
    jq --arg id "$uuid" --arg email "$user" \
        '(.inbounds[] | select(.port == 443)).settings.clients += [{"id": $id, "email": $email}]' \
        "$XRAY_CONF" > "$tmp2" 2>/dev/null

    if jq . "$tmp2" >/dev/null 2>&1; then
        mv "$tmp2" "$XRAY_CONF"
        systemctl restart xray >/dev/null 2>&1
    else
        rm -f "$tmp2"
    fi

    log "- XRAY KICK UUID: $user ($uuid)"
}

# -------------------------------------------------------
# Mata conexões TCP diretas na porta 443 do usuário
# Complementar ao kick_xray_uuid
# -------------------------------------------------------
kill_tcp_connections() {
    local user="$1"
    # Lista PIDs de processos do usuário com conexões na 443
    local pids
    pids=$(lsof -u "$user" -i tcp:443 -t 2>/dev/null)
    if [ -n "$pids" ]; then
        echo "$pids" | xargs -r kill -9 2>/dev/null
        log "- TCP KILL: $user (PIDs: $pids)"
    fi
}

# -------------------------------------------------------
# Registra bloqueio no arquivo de bloqueados
# -------------------------------------------------------
register_block() {
    local user="$1"
    local reason="$2"
    # Evita duplicatas
    if ! grep -q "^$user|" "$BLOCKED" 2>/dev/null; then
        echo "$user|$(date '+%d/%m/%Y %H:%M')|$reason" >> "$BLOCKED"
    fi
}

# -------------------------------------------------------
# LOOP PRINCIPAL DO LIMITER
# -------------------------------------------------------
echo -e "${GREEN}[+] LIMITER NETSIMON 3.0 INICIADO — monitorando a cada 8s...${NC}"
log "=== LIMITER 3.0 INICIADO ==="

sync_cycle=0

while true; do
    # A cada ~48s (6 ciclos de 8s), busca novos usuários criados
    # direto no painel Atlas e os traz para o sistema local
    if type atlas_sync_users &>/dev/null && [ "$sync_cycle" -le 0 ]; then
        resultado_sync=$(atlas_sync_users 2>/dev/null)
        [ -n "$resultado_sync" ] && log "[ATLAS-SYNC] $resultado_sync"
        sync_cycle=6
    fi
    ((sync_cycle--))

    # Aguarda o banco de dados existir
    if [ ! -f "$USERDB" ] || [ ! -s "$USERDB" ]; then
        sleep 10
        continue
    fi

    while IFS='|' read -r user uuid exp pass limit; do
        # Ignora linhas inválidas
        [[ -z "$user" || "$user" =~ ^# ]] && continue
        [[ -z "$limit" ]] && limit=1

        DATA_LOG=$(date '+%d/%m/%Y %H:%M:%S')

        # ===================================================
        # BLOCO 1: VERIFICAÇÃO SSH / WEBSOCKET
        # ===================================================
        ssh_count=$(count_ssh "$user")

        if [[ "$ssh_count" -gt "$limit" ]]; then
            log "🔴 SSH EXCEDIDO: $user | Limite=$limit | Ativo=$ssh_count"
            kick_ssh "$user"
            register_block "$user" "SSH duplicado ($ssh_count/$limit)"
        fi

        # ===================================================
        # BLOCO 2: VERIFICAÇÃO XRAY POR UUID
        # Checa IPs únicos conectados com o mesmo UUID
        # ===================================================
        if [ -n "$uuid" ] && [ "$uuid" != "NULL" ]; then
            xray_ips=$(count_xray_unique_ips "$user")

            if [[ "$xray_ips" -gt "$limit" ]]; then
                log "🔴 XRAY UUID COMPARTILHADO: $user | UUID=$uuid | IPs únicos=$xray_ips | Limite=$limit"
                kick_xray_uuid "$user" "$uuid"
                kill_tcp_connections "$user"
                register_block "$user" "UUID compartilhado ($xray_ips IPs/$limit)"
            fi
        fi

        # ===================================================
        # BLOCO 3: EXPIRAÇÃO — apenas ignora, não reinicia xray
        # O limiter não expulsa expirados para evitar loop de restart.
        # Remoção de expirados é responsabilidade do painel/Atlas.
        # ===================================================
        if [ -n "$exp" ] && [ "$exp" != "NULL" ]; then
            hoje=$(date +%s)
            exp_s=$(date -d "$exp" +%s 2>/dev/null || echo 0)
            if [[ $exp_s -gt 0 && $exp_s -lt $hoje ]]; then
                continue
            fi
        fi

    done < "$USERDB"

    sleep 8
done
