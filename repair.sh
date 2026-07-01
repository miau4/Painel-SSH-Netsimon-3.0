#!/bin/bash
# ==========================================
#   NETSIMON 3.0 - REPAIR SYSTEM
# ==========================================

BASE="/etc/painel"
REPO="https://raw.githubusercontent.com/miau4/Painel-SSH-Netsimon-3.0/main"
C=$'\033[1;36m'; G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; W=$'\033[1;37m'; NC=$'\033[0m'

clear
echo -e "${C}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${C}║${W}            🛠️  REPARANDO SISTEMA NETSIMON 3.0                ${C}║${NC}"
echo -e "${C}╚══════════════════════════════════════════════════════════════╝${NC}"

arquivos=(
    "menu.sh" "adduser.sh" "addtest.sh" "deluser.sh"
    "online.sh" "limit.sh" "unblock.sh" "websocket.sh"
    "xray.sh" "slowdns-server.sh" "monitor.sh" "proxy.py"
    "boot_check.sh" "repair.sh" "checkuser.py" "checkuser.sh"
    "atlas.sh"
)

for file in "${arquivos[@]}"; do
    printf "${W}[+] Restaurando: ${Y}%-20s${NC}" "$file"
    wget -q -O "$BASE/$file" "$REPO/$file"
    if [ -s "$BASE/$file" ]; then
        chmod +x "$BASE/$file"
        dos2unix "$BASE/$file" &>/dev/null
        echo -e "${G}[ OK ]${NC}"
    else
        echo -e "${R}[ FALHA ]${NC}"
    fi
done

# Reset de permissões
chmod -R 777 /var/log/xray
setcap 'cap_net_bind_service=+ep' /usr/local/bin/xray 2>/dev/null
systemctl daemon-reload
systemctl restart xray

echo -e "\n${G}✅ SISTEMA 3.0 REPARADO!${NC}"
echo -e "${Y}Nota: sua API Key do Atlas foi preservada em /etc/painel/atlas.key${NC}"
sleep 2
