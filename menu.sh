#!/bin/bash
# ==========================================
#         🚀 PAINEL NETSIMON 3.0 🚀
# ==========================================
# Atualização de CPU/RAM/Hora: feita via "read -r -t 1" com timeout.
# Quando o timer expira sem input, atualiza só as linhas dinâmicas
# (sem clear, sem background process, sem interferência no cursor).
# Input: read -r aguarda Enter — Delete/Backspace/Ctrl+C funcionam.

BASE="/etc/painel"
USERDB="/etc/painel/usuarios.db"
BLOCKED="/etc/xray-manager/blocked.db"
XRAY_CONF="/usr/local/etc/xray/config.json"
NS_CACHE_IP="/tmp/ns_cached_ip"
NS_CACHE_XP="/tmp/ns_xp"

# Posições das linhas dinâmicas (1-indexadas, contadas após o clear):
readonly ROW_HORA=5
readonly ROW_CPU=9
readonly ROW_RAM=10
readonly ROW_PROMPT=25

P=$'\033[1;35m'; G=$'\033[1;32m'; GD=$'\033[0;32m'; R=$'\033[1;31m'
Y=$'\033[1;33m'; W=$'\033[1;37m'; C=$'\033[1;36m'; B=$'\033[1;34m'
O=$'\033[38;5;208m'; NC=$'\033[0m'

source "$BASE/atlas.sh" 2>/dev/null

# ── Ctrl+C: restaura terminal e sai para o prompt da VPS ─────────
trap 'tput cnorm 2>/dev/null; echo ""; exit 130' INT TERM
trap 'tput cnorm 2>/dev/null' EXIT

# ── Coleta de dados ───────────────────────────────────────────────
get_cpu()  { top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print int($2+$4)}'; }
get_ram()  { free 2>/dev/null | awk '/Mem:/ {printf "%d", $3/$2*100}'; }
get_disk() { df / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%'; }
get_total()        { [ -f "$USERDB"  ] && wc -l < "$USERDB"  || echo 0; }
get_blocked_count(){ [ -f "$BLOCKED" ] && wc -l < "$BLOCKED" || echo 0; }

get_online() {
    local ssh xray
    ssh=$(who 2>/dev/null | wc -l)
    xray=$(ss -tn 2>/dev/null | grep ":443" | grep ESTAB \
        | awk '{print $4}' | cut -d: -f1 | sort -u \
        | grep -cvE "127.0.0.1|0.0.0.0|^$")
    echo $((ssh + xray))
}

get_expired() {
    local hoje cont=0
    hoje=$(date +%s)
    [ ! -f "$USERDB" ] && echo 0 && return
    while IFS='|' read -r _ _ exp _; do
        local s; s=$(date -d "$exp" +%s 2>/dev/null)
        [[ $? -eq 0 && -n "$s" && $s -lt $hoje ]] && ((cont++))
    done < "$USERDB"
    echo "$cont"
}

check_proto() {
    pgrep -f "$1" >/dev/null 2>&1 || systemctl is-active --quiet "$1" 2>/dev/null \
        && printf "${G}ON${NC}" || printf "${R}OFF${NC}"
}
atlas_dot() {
    [ -s "/etc/painel/atlas.key" ] && printf "${G}OK${NC}" || printf "${R}N/A${NC}"
}

# ── Barra de progresso ────────────────────────────────────────────
bar() {
    local p=$1 size=20
    [[ -z "$p" || ! "$p" =~ ^[0-9]+$ ]] && p=0
    [[ $p -gt 100 ]] && p=100
    local filled=$((p * size / 100)) empty=$((size - filled))
    local color=$G
    [ "$p" -gt 70 ] && color=$O
    [ "$p" -gt 85 ] && color=$R
    local i s="${color}["
    for ((i=0; i<filled; i++)); do s+="#"; done
    for ((i=0; i<empty; i++)); do s+="-"; done
    s+="] ${p}%${NC}"
    printf "%s" "$s"
}

# ── Atualiza SOMENTE as linhas dinâmicas (sem clear, sem mover o cursor do usuário)
# Salva posição do cursor com \0337 e restaura com \0338 (VT100, suportado em todos
# os clientes SSH modernos: PuTTY, OpenSSH, Termux, etc.)
do_update() {
    local ip xp hora cpu ram
    ip=$(cat "$NS_CACHE_IP" 2>/dev/null); [ -z "$ip" ] && ip="..."
    xp=$(cat "$NS_CACHE_XP" 2>/dev/null); [ -z "$xp" ] && xp="--"
    hora=$(date +"%H:%M:%S")
    cpu=$(get_cpu);  [ -z "$cpu" ] && cpu=0
    ram=$(get_ram);  [ -z "$ram" ] && ram=0

    printf "\0337"  # salva posição atual do cursor (onde usuário está digitando)

    # Linha ROW_HORA — apaga e reimprima
    printf "\033[%d;1H\033[2K" "$ROW_HORA"
    printf "${P}║${NC} ${B}IP:${W} %-15s ${P}│${B} Port:${W} %-8s ${P}│${B} Hora:${W} %-10s${NC}" \
        "$ip" "$xp" "$hora"

    # Linha ROW_CPU
    printf "\033[%d;1H\033[2K${P}║${NC} CPU  " "$ROW_CPU"
    bar "$cpu"

    # Linha ROW_RAM
    printf "\033[%d;1H\033[2K${P}║${NC} RAM  " "$ROW_RAM"
    bar "$ram"

    printf "\0338"  # restaura o cursor exatamente onde estava antes da atualização
}

# ── Desenho completo da tela (executado 1x por ciclo de input) ────
draw_full() {
    clear
    local cpu ram disk hora ip xp lmt

    cpu=$(get_cpu);   [ -z "$cpu"  ] && cpu=0
    ram=$(get_ram);   [ -z "$ram"  ] && ram=0
    disk=$(get_disk); [ -z "$disk" ] && disk=0
    hora=$(date +"%H:%M:%S")
    ip=$(cat "$NS_CACHE_IP" 2>/dev/null);  [ -z "$ip" ] && ip="..."
    xp=$(cat "$NS_CACHE_XP" 2>/dev/null);  [ -z "$xp" ] && xp="--"
    lmt=$(pgrep -f limit.sh >/dev/null && printf "${G}ON${NC}" || printf "${R}OFF${NC}")

    # ROW 1
    echo -e "${P}╔══════════════════════════════════════════════════════════════${NC}"
    # ROW 2
    echo -e "${P}║${C}                🚀 PAINEL NETSIMON 3.0 🚀                    ${NC}"
    # ROW 3
    echo -e "${P}╠══════════════════════════════════════════════════════════════${NC}"
    # ROW 4
    printf "${P}║${NC} ${C}Users:${O} %-4s ${P}│${C} Online:${G} %-4s ${P}│${C} Expired:${R} %-4s ${P}│${C} Block:${R} %-4s${NC}\n" \
        "$(get_total)" "$(get_online)" "$(get_expired)" "$(get_blocked_count)"
    # ROW 5  ← ROW_HORA (atualizado pelo do_update)
    printf "${P}║${NC} ${B}IP:${W} %-15s ${P}│${B} Port:${W} %-8s ${P}│${B} Hora:${W} %-10s${NC}\n" \
        "$ip" "$xp" "$hora"
    # ROW 6
    echo -e "${P}╟──────────────────────────────────────────────────────────────${NC}"
    # ROW 7
    printf "${P}║${NC} ${O}XRAY:${NC} $(check_proto xray)  ${P}│${O} SLOWDNS:${NC} $(check_proto slowdns)  ${P}│${O} WS:${NC} $(check_proto proxy.py)  ${P}│${O} ATLAS:${NC} $(atlas_dot)  ${P}│${O} LIMITER:${NC} ${lmt}${NC}\n"
    # ROW 8
    echo -e "${P}╟──────────────────────────────────────────────────────────────${NC}"
    # ROW 9  ← ROW_CPU
    printf "${P}║${NC} CPU  "; bar "$cpu"; echo
    # ROW 10 ← ROW_RAM
    printf "${P}║${NC} RAM  "; bar "$ram"; echo
    # ROW 11
    printf "${P}║${NC} DISK "; bar "$disk"; echo
    # ROW 12
    echo -e "${P}╠══════════════════════════════════════════════════════════════${NC}"
    # ROWS 13-24
    printf "${P}║${GD} 01) Criar Usuário              ${P}│${C} 12) Reiniciar Xray              ${NC}\n"
    printf "${P}║${GD} 02) Criar Teste                ${P}│${C} 13) Reparar Sistema             ${NC}\n"
    printf "${P}║${C} 03) Remover Usuário            ${P}│${G} 14) Ativar Limiter              ${NC}\n"
    printf "${P}║${C} 04) Listar Usuários            ${P}│${R} 15) Parar Limiter               ${NC}\n"
    printf "${P}║${C} 05) Usuários Online            ${P}│${C} 16) Teste Velocidade            ${NC}\n"
    printf "${P}║${C} 06) Renovar Usuário            ${P}│${B} 17) WebSocket Manager           ${NC}\n"
    printf "${P}║${C} 07) Renovar Revendedor         ${P}│${B} 18) SlowDNS Manager             ${NC}\n"
    printf "${P}║${C} 08) Ver Bloqueados             ${P}│${B} 19) Xray Manager                ${NC}\n"
    printf "${P}║${C} 09) Desbloquear Usuário        ${P}│${C} 20) Status VPS                  ${NC}\n"
    printf "${P}║${C} 10) Limpar Bloqueios           ${P}│${C} 21) Ver Logs                    ${NC}\n"
    printf "${P}║${C} 11) Backup Config              ${P}│${O} 22) Atlas Manager               ${NC}\n"
    # ROW 25
    echo -e "${P}╚══════════════════════════════════════════════════════════════${NC}"
    # ROW 26 — sem newline; cursor fica aqui para o read
    printf "${O}✨ Opção: ${NC}"
}

# ── Cache do IP público e portas Xray ────────────────────────────
refresh_cache() {
    local new_ip
    new_ip=$(wget -qO- --timeout=3 ipv4.icanhazip.com 2>/dev/null | tr -d '\n')
    [ -n "$new_ip" ] && echo "$new_ip" > "$NS_CACHE_IP" || echo "offline" > "$NS_CACHE_IP"
    if [ -f "$XRAY_CONF" ]; then
        jq -r '.inbounds[].port' "$XRAY_CONF" 2>/dev/null | xargs | sed 's/ /,/g' > "$NS_CACHE_XP"
    else
        echo "--" > "$NS_CACHE_XP"
    fi
}

# ── LOOP PRINCIPAL ────────────────────────────────────────────────
ip_timer=0
refresh_cache &   # busca IP em background para não travar o primeiro desenho

while true; do
    # Refresca cache do IP a cada 30 ciclos
    if [ "$ip_timer" -le 0 ]; then
        refresh_cache &
        ip_timer=30
    fi
    ((ip_timer--))

    draw_full   # limpa tela e desenha tudo 1x; cursor fica em ROW 26 após "Opção: "

    # Aguarda input com timeout de 1 segundo.
    # ret=0   → usuário pressionou Enter (input recebido)
    # ret>128 → timeout expirou (1s sem Enter) → atualiza CPU/RAM/Hora e volta a aguardar
    op=""
    while true; do
        IFS= read -r -t 1 op
        ret=$?
        if [ "$ret" -eq 0 ]; then
            break          # Enter recebido — sai do loop de input
        elif [ "$ret" -gt 128 ]; then
            do_update      # timeout — atualiza linhas dinâmicas sem tocar no cursor
        fi
        # ret 1-128 = EOF ou erro — continuamos aguardando
    done

    echo ""   # desce uma linha antes de processar

    case "$op" in
        1|01) bash "$BASE/adduser.sh" ;;
        2|02) bash "$BASE/addtest.sh" ;;
        3|03) bash "$BASE/deluser.sh" ;;
        4|04)
            clear
            echo -e "${P}╔══════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${P}║${NC} ${O} #   USUÁRIO    SENHA       UUID             DATA          LIM.${NC}"
            echo -e "${P}╠══════════════════════════════════════════════════════════════════╣${NC}"
            if [ -s "$USERDB" ]; then
                local num=0
                # Lê na ordem exata do arquivo (= ordem de criação, sem sort)
                while IFS='|' read -r user uuid exp pass lim; do
                    ((num++))
                    data_fmt=$(date -d "$exp" +"%d/%m/%y %H:%M" 2>/dev/null || echo "--/--")
                    uuid_curto="${uuid:0:8}..."
                    printf "${P}║${W} %-3s %-10s %-11s %-16s %-13s %-4s${NC}\n" \
                        "$num" "$user" "$pass" "$uuid_curto" "$data_fmt" "$lim"
                done < "$USERDB"
            else
                echo -e "${P}║${R}                  NENHUM USUÁRIO ENCONTRADO!                        ${NC}"
            fi
            echo -e "${P}╚══════════════════════════════════════════════════════════════════╝${NC}"
            read -rp "Pressione ENTER para voltar..." ;;
        5|05) bash "$BASE/online.sh" ;;
        6|06)
            clear
            echo -e "${P}╔══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${P}║${W}                  🔄 RENOVAR USUÁRIO                          ${P}║${NC}"
            echo -e "${P}╚══════════════════════════════════════════════════════════════╝${NC}"
            read -rp " Usuário a renovar: " ruser
            if [ -n "$ruser" ]; then
                resp=$(atlas_renovar_user "$ruser")
                echo -e "${C}Atlas: $resp${NC}"
                echo -e "${Y}Sincronizando dados locais...${NC}"
                result=$(atlas_sync_users 2>&1)
                echo -e "${G}✅ Concluído! ($result)${NC}"
            fi
            read -rp "ENTER para voltar..." ;;
        7|07)
            clear
            echo -e "${P}╔══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${P}║${W}                🔄 RENOVAR REVENDEDOR                         ${P}║${NC}"
            echo -e "${P}╚══════════════════════════════════════════════════════════════╝${NC}"
            read -rp " Revendedor a renovar: " rrev
            if [ -n "$rrev" ]; then
                resp=$(atlas_renovar_rev "$rrev")
                echo -e "${C}Atlas: $resp${NC}"
            fi
            read -rp "ENTER para voltar..." ;;
        8|08)
            clear
            echo -e "${P}╔══════════════════════════════╗${NC}"
            echo -e "${P}║${W}       USUÁRIOS BLOQUEADOS     ${P}║${NC}"
            echo -e "${P}╚══════════════════════════════╝${NC}"
            if [ -s "$BLOCKED" ]; then
                printf "${W}%-20s %-18s %s${NC}\n" "USUÁRIO" "DATA" "MOTIVO"
                echo -e "${P}──────────────────────────────────────────────${NC}"
                while IFS='|' read -r u d m; do
                    printf "${R}%-20s ${Y}%-18s ${C}%s${NC}\n" "$u" "$d" "$m"
                done < "$BLOCKED"
            else
                echo -e "${Y}Nenhum bloqueio registrado.${NC}"
            fi
            read -rp "ENTER para voltar..." ;;
        9|09) bash "$BASE/unblock.sh" ;;
        10)
            : > "$BLOCKED"
            echo -e "${G}✅ Todos os bloqueios removidos!${NC}"; sleep 2 ;;
        11)
            clear
            BKP="/root/backup_netsimon_$(date +%d%m%y_%H%M).tar.gz"
            tar -czf "$BKP" "$BASE" "/usr/local/etc/xray" "/etc/xray-manager" 2>/dev/null
            echo -e "${G}✅ Backup: $BKP${NC}"; sleep 3 ;;
        12)
            systemctl restart xray 2>/dev/null
            echo -e "${G}✅ Xray reiniciado!${NC}"; sleep 1 ;;
        13) bash "$BASE/repair.sh" ;;
        14)
            screen -dmS limitador bash "$BASE/limit.sh" 2>/dev/null
            echo -e "${G}✅ Limiter ativado!${NC}"; sleep 1 ;;
        15)
            pkill -f limit.sh 2>/dev/null; screen -wipe >/dev/null 2>&1
            echo -e "${R}⛔ Limiter parado!${NC}"; sleep 1 ;;
        16)
            clear
            which speedtest-cli >/dev/null 2>&1 || apt-get install -y speedtest-cli >/dev/null 2>&1
            speedtest-cli --simple 2>&1
            read -rp "ENTER para voltar..." ;;
        17) bash "$BASE/websocket.sh" ;;
        18) bash "$BASE/slowdns-server.sh" ;;
        19) bash "$BASE/xray.sh" ;;
        20) bash "$BASE/monitor.sh" ;;
        21)
            clear
            echo -e "${P}══════════════ LOGS DO SISTEMA ══════════════${NC}"
            if [ -s /var/log/xray/access.log ]; then
                echo -e "${W}Xray (últimas 15 entradas):${NC}"
                tail -n 15 /var/log/xray/access.log \
                    | sed "s/accepted/${G}accepted${NC}/g" \
                    | sed "s/failed/${R}failed${NC}/g"
            fi
            echo -e "${P}──────────────────────────────────────────────${NC}"
            if [ -s /var/log/netsimon_limit.log ]; then
                echo -e "${W}Limiter (últimas 10 entradas):${NC}"
                tail -n 10 /var/log/netsimon_limit.log
            fi
            read -rp "ENTER para voltar..." ;;
        22) atlas_menu ;;
        "")  ;;   # Enter em branco — apenas redesenha
        *) echo -e "${R}Opção inválida: '$op'${NC}"; sleep 1 ;;
    esac
done
