#!/bin/bash
# ==========================================
#   NETSIMON 3.0 - CRIAR USUÁRIO
#   Local + Xray + Atlas sincronizados
# ==========================================

BASE="/etc/painel"
USERDB="/etc/painel/usuarios.db"
XRAY_CONF="/usr/local/etc/xray/config.json"

P=$'\033[1;35m'; G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'
W=$'\033[1;37m'; C=$'\033[1;36m'; NC=$'\033[0m'

# Carrega módulo Atlas
source "$BASE/atlas.sh" 2>/dev/null || {
    echo -e "${R}ERRO: atlas.sh não encontrado em $BASE${NC}"
    sleep 2; exit 1
}

[[ ! -f "$USERDB" ]] && touch "$USERDB"

clear
echo -e "${P}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${P}║${W}                 🚀 CRIAR NOVO USUÁRIO 3.0                    ${P}║${NC}"
echo -e "${P}╚══════════════════════════════════════════════════════════════╝${NC}"

read -p " Nome do Usuário: " user
[[ -z "$user" ]] && exit 1

if grep -qw "^$user|" "$USERDB" || id "$user" &>/dev/null; then
    echo -e "\n${R}Erro: Usuário já existe!${NC}"; sleep 2; exit 1
fi

read -p " Senha: " pass
[[ -z "$pass" ]] && pass="1234"

read -p " Dias de Validade: " dias
[[ -z "$dias" ]] && dias=30

read -p " Limite de Conexões: " limite
[[ -z "$limite" ]] && limite=1

read -p " WhatsApp do cliente (opcional, Enter para pular): " whatsapp

# ---- Sistema Linux ----
useradd -M -s /bin/false "$user" &>/dev/null
echo "$user:$pass" | chpasswd &>/dev/null
exp=$(date -d "+$dias days" +"%Y-%m-%d 23:59:59")
exp_chage=$(date -d "+$dias days" +"%Y-%m-%d")
chage -E "$exp_chage" "$user"

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
        echo -e "${Y}⚠ Aviso: falha ao injetar UUID no Xray. Config preservada.${NC}"
    fi
fi

# ---- Banco Local ----
echo "$user|$uuid|$exp|$pass|$limite" >> "$USERDB"

# ---- Atlas API ----
echo -ne "${C}[ATLAS] Sincronizando com o painel... ${NC}"
atlas_resp=$(atlas_criar_user "$user" "$pass" "$dias" "$limite" "$whatsapp" 2>&1)
if echo "$atlas_resp" | grep -qi "sucess\|criado\|success"; then
    echo -e "${G}OK${NC}"
elif echo "$atlas_resp" | grep -qi "erro\|error\|falha"; then
    echo -e "${Y}⚠ Atlas retornou aviso: $atlas_resp${NC}"
else
    echo -e "${Y}Atlas: $atlas_resp${NC}"
fi

clear
echo -e "${G}✅ USUÁRIO CRIADO COM SUCESSO!${NC}"
echo -e "${P}────────────────────────────────────────────────────────────────${NC}"
printf "${W} Usuário : ${Y}%-20s ${W} Senha  : ${Y}%-10s${NC}\n" "$user" "$pass"
printf "${W} Validade: ${Y}%-20s ${W} Limite : ${Y}%-10s${NC}\n" "$exp_chage" "$limite"
echo -e "${W} UUID    : ${C}$uuid${NC}"
echo -e "${W} Atlas   : ${G}Sincronizado${NC}"
echo -e "${P}────────────────────────────────────────────────────────────────${NC}"
read -p "Pressione ENTER para voltar..."
