#!/bin/bash
# ==========================================
#   NETSIMON 3.0 - USUÁRIOS ONLINE
#   SSH / WebSocket / Xray VLESS
# ==========================================

P=$'\033[1;35m'; G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'
W=$'\033[1;37m'; C=$'\033[1;36m'; NC=$'\033[0m'
USERDB="/etc/painel/usuarios.db"
XRAY_LOG="/var/log/xray/access.log"

clear
echo -e "${P}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${P}║${W}                👥 USUÁRIOS CONECTADOS AGORA                  ${P}║${NC}"
echo -e "${P}╚══════════════════════════════════════════════════════════════╝${NC}"
printf " ${W}%-15s | %-20s | %-12s | %-6s${NC}\n" "USUÁRIO" "IP DE CONEXÃO" "PROTOCOLO" "DURAÇÃO"
echo -e "${P}────────────────────────────────────────────────────────────────${NC}"

TMP_ON=$(mktemp)

# ── SSH / WebSocket ──────────────────────────────────────────────
# Usa 'ss' (mais preciso que netstat) para listar sessões estabelecidas
while read -r user; do
    [[ -z "$user" ]] && continue
    # Verifica se existe no banco do painel
    grep -q "^$user|" "$USERDB" 2>/dev/null || continue

    # Tenta pegar o IP da sessão via ss
    IP_CONN=$(ss -tnp 2>/dev/null | awk -v u="sshd" '$NF ~ u' | grep ESTAB | \
        awk '{print $5}' | cut -d: -f1 | grep -v "127.0.0.1" | head -n1)
    [[ -z "$IP_CONN" ]] && IP_CONN="WebSocket"

    # Tempo de sessão
    DURACAO=$(ps -u "$user" -o etimes= 2>/dev/null | sort -n | head -n1)
    if [ -n "$DURACAO" ]; then
        MINS=$(( DURACAO / 60 ))
        DUR_STR="${MINS}min"
    else
        DUR_STR="--"
    fi

    printf " ${G}%-15s${NC} | ${C}%-20s${NC} | ${Y}%-12s${NC} | ${W}%-6s${NC}\n" \
        "$user" "$IP_CONN" "SSH/WS" "$DUR_STR" >> "$TMP_ON"
done < <(who 2>/dev/null | awk '{print $1}' | sort -u)

# ── Xray VLESS ───────────────────────────────────────────────────
if [ -f "$XRAY_LOG" ] && [ -s "$USERDB" ]; then
    NOW=$(date +%s)
    # Pega últimas 200 linhas com "accepted" nos últimos 90s
    RECENT=$(tail -n 200 "$XRAY_LOG" | grep "accepted")

    while IFS='|' read -r user uuid exp pass lim; do
        [[ -z "$user" ]] && continue
        # Procura linha recente com o email/user do Xray
        LINE=$(echo "$RECENT" | grep "email: $user" | tail -n1)
        [[ -z "$LINE" ]] && continue

        # Verifica se é recente (últimos 90s)
        TS=$(echo "$LINE" | awk '{print $1 " " $2}')
        TS_EPOCH=$(date -d "$TS" +%s 2>/dev/null || echo 0)
        DIFF=$(( NOW - TS_EPOCH ))
        [ "$DIFF" -gt 90 ] && continue

        # Campo 3 = IP:PORTA de origem (formato real do access.log do Xray:
        # "DATA HORA IP:PORTA accepted tcp:destino [tag] email: NOME")
        IP_X=$(echo "$LINE" | awk '{print $3}' | cut -d: -f1)
        [[ -z "$IP_X" || "$IP_X" == "127.0.0.1" ]] && IP_X="tunnel"

        printf " ${G}%-15s${NC} | ${C}%-20s${NC} | ${P}%-12s${NC} | ${W}%-6s${NC}\n" \
            "$user" "$IP_X" "XRAY/VLESS" "--" >> "$TMP_ON"
    done < "$USERDB"
fi

# ── Exibição ─────────────────────────────────────────────────────
if [ -s "$TMP_ON" ]; then
    sort -u "$TMP_ON"
else
    echo -e "             ${R}Nenhum usuário logado no momento.${NC}"
fi

echo -e "${P}────────────────────────────────────────────────────────────────${NC}"
TOTAL=$(sort -u "$TMP_ON" | wc -l)
echo -e " ${W}TOTAL DE CONEXÕES: ${G}$TOTAL${NC}"
echo -e "${P}────────────────────────────────────────────────────────────────${NC}"
rm -f "$TMP_ON"
read -p " Pressione ENTER para voltar..."
