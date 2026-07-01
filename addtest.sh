#!/bin/bash
# ==========================================
#   NETSIMON 3.0 - TESTE TEMPORÁRIO
#   Local + Xray + Atlas sincronizados
# ==========================================

BASE="/etc/painel"
USERDB="/etc/painel/usuarios.db"
XRAY_CONF="/usr/local/etc/xray/config.json"
LOG_LIMIT="/var/log/netsimon_limit.log"

P=$'\033[1;35m'; G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'
W=$'\033[1;37m'; C=$'\033[1;36m'; NC=$'\033[0m'

source "$BASE/atlas.sh" 2>/dev/null || {
    echo -e "${R}ERRO: atlas.sh não encontrado${NC}"; sleep 2; exit 1
}

clear
echo -e "${P}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${P}║${W}                ⚡ GERAR TESTE TEMPORÁRIO 3.0                 ${P}║${NC}"
echo -e "${P}╚══════════════════════════════════════════════════════════════╝${NC}"

read -p " Nome do Teste (Enter para aleatório): " user
if [[ -z "$user" ]]; then
    user="teste$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
fi

if grep -q "^$user|" "$USERDB" 2>/dev/null || id "$user" &>/dev/null; then
    echo -e "\n${R}Erro: Usuário '$user' já existe!${NC}"; sleep 2; exit 1
fi

read -p " Senha (Padrão 123): " pass
[[ -z "$pass" ]] && pass="123"

echo -e "${W}Duração do teste — exemplos: 30m | 1h | 2h${NC}"
read -p " Duração: " tempo
[[ -z "$tempo" ]] && tempo="30m"

# Converte duração para minutos (para o Atlas)
if [[ "$tempo" =~ ^([0-9]+)m$ ]]; then
    minutos="${BASH_REMATCH[1]}"
elif [[ "$tempo" =~ ^([0-9]+)h$ ]]; then
    minutos=$(( BASH_REMATCH[1] * 60 ))
else
    minutos=30
fi

# ---- Sistema Linux ----
useradd -M -s /bin/false "$user" &>/dev/null
echo "$user:$pass" | chpasswd &>/dev/null

# ---- Xray ----
uuid=$(cat /proc/sys/kernel/random/uuid)
if [ -f "$XRAY_CONF" ]; then
    tmp=$(mktemp)
    jq --arg u "$user" --arg id "$uuid" \
        '(.inbounds[] | select(.port == 443)).settings.clients += [{"id": $id, "email": $u}]' \
        "$XRAY_CONF" > "$tmp"
    if jq . "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$XRAY_CONF"
        systemctl restart xray >/dev/null 2>&1
    else
        rm -f "$tmp"
    fi
fi

# ---- Banco Local (expira hoje + duração) ----
exp=$(date +"%Y-%m-%d 23:59:59")
echo "$user|$uuid|$exp|$pass|1" >> "$USERDB"

# ---- Auto-Destruição via 'at' ----
if ! command -v at &>/dev/null; then
    apt install at -y &>/dev/null
    systemctl enable --now atd &>/dev/null
fi
echo "bash $BASE/deluser.sh $user --auto" | at "now + $tempo" &>/dev/null
AVISO_AUTO="${G}AUTO-REMOÇÃO EM: ${Y}$tempo${NC}"

# ---- Atlas API ----
echo -ne "${C}[ATLAS] Sincronizando teste... ${NC}"
atlas_resp=$(atlas_criar_teste "$user" "$pass" "$minutos" 2>&1)
if echo "$atlas_resp" | grep -qi "sucess\|criado\|success"; then
    echo -e "${G}OK${NC}"
else
    echo -e "${Y}Atlas: $atlas_resp${NC}"
fi

echo "$(date '+%d/%m/%Y %H:%M:%S') - TESTE CRIADO: $user por $tempo" >> "$LOG_LIMIT"

clear
echo -e "${G}✅ CONTA DE TESTE CRIADA!${NC}"
echo -e "${P}────────────────────────────────────────────────────────────────${NC}"
printf "${W} Usuário : ${Y}%-20s ${W} Senha  : ${Y}%-10s${NC}\n" "$user" "$pass"
printf "${W} Duração : ${Y}%-20s ${W} Limite : ${Y}%-10s${NC}\n" "$tempo" "1"
echo -e "${W} UUID    : ${C}$uuid${NC}"
echo -e " ${AVISO_AUTO}"
echo -e "${P}────────────────────────────────────────────────────────────────${NC}"
read -p "Pressione ENTER para voltar..."
