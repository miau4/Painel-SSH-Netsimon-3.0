#!/bin/bash
# ==========================================
#   NETSIMON 3.0 - DESBLOQUEAR USUÁRIO
# ==========================================

USERDB="/etc/painel/usuarios.db"
BLOCKED="/etc/xray-manager/blocked.db"
XRAY_CONF="/usr/local/etc/xray/config.json"

G=$'\033[1;32m'; R=$'\033[1;31m'; C=$'\033[1;36m'
Y=$'\033[1;33m'; W=$'\033[1;37m'; P=$'\033[1;35m'; NC=$'\033[0m'

clear
echo -e "${P}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${P}║${W}                🔓 DESBLOQUEAR USUÁRIO 3.0                    ${P}║${NC}"
echo -e "${P}╚══════════════════════════════════════════════════════════════╝${NC}"

if [ ! -f "$BLOCKED" ] || [ ! -s "$BLOCKED" ]; then
    echo -e "\n${Y}Nenhum usuário bloqueado no momento.${NC}"
    read -p "ENTER..."; exit 0
fi

mapfile -t bloqueados < <(cut -d'|' -f1 "$BLOCKED")

echo -e "\n${W}Usuários bloqueados:${NC}\n"
for i in "${!bloqueados[@]}"; do
    local_user="${bloqueados[$i]}"
    motivo=$(grep "^$local_user|" "$BLOCKED" | cut -d'|' -f3)
    printf "${C}%02d)${NC} %-20s ${Y}%s${NC}\n" "$((i+1))" "$local_user" "$motivo"
done

echo -e "\n${C}00)${NC} Voltar"
echo -e "${P}──────────────────────────────────────────────────────${NC}"
read -p " Escolha: " op

[[ "$op" == "0" || "$op" == "00" ]] && exit

user="${bloqueados[$((op-1))]}"
if [[ -z "$user" ]]; then
    echo -e "${R}Opção inválida!${NC}"; sleep 2; exit
fi

echo -e "\n${Y}Restaurando acesso para: $user ...${NC}"

# 1. Desbloqueia conta Linux
passwd -u "$user" &>/dev/null
echo -e "${G}[OK]${NC} Linux/SSH restaurado"

# 2. Verifica se o UUID já está no Xray; se não estiver, readiciona
uuid=$(grep "^$user|" "$USERDB" | cut -d'|' -f2)
if [ -n "$uuid" ] && [ -f "$XRAY_CONF" ]; then
    if ! jq -e --arg u "$user" '.inbounds[].settings.clients[]? | select(.email == $u)' \
            "$XRAY_CONF" >/dev/null 2>&1; then
        tmp=$(mktemp)
        jq --arg id "$uuid" --arg email "$user" \
            '(.inbounds[] | select(.port == 443)).settings.clients += [{"id": $id, "email": $email}]' \
            "$XRAY_CONF" > "$tmp" 2>/dev/null
        if jq . "$tmp" >/dev/null 2>&1; then
            mv "$tmp" "$XRAY_CONF"
            systemctl restart xray &>/dev/null
            echo -e "${G}[OK]${NC} Xray UUID restaurado"
        else
            rm -f "$tmp"
            echo -e "${Y}[AVISO]${NC} Não foi possível reinserir UUID no Xray"
        fi
    else
        echo -e "${G}[OK]${NC} UUID já presente no Xray"
    fi
fi

# 3. Remove da lista de bloqueados
sed -i "/^$user|/d" "$BLOCKED"

echo -e "\n${G}✅ $user está liberado!${NC}"
read -p "ENTER..."
