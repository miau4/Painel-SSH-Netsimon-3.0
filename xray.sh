#!/bin/bash
# ==========================================
#   NETSIMON 3.0 - XRAY MANAGER
# ==========================================

# CAMINHO CORRIGIDO (era /etc/xray/config.json — errado)
XRAY_CONF="/usr/local/etc/xray/config.json"
SSL_DIR="/etc/xray-manager/ssl"

C=$'\033[1;36m'; G=$'\033[1;32m'; R=$'\033[1;31m'
Y=$'\033[1;33m'; W=$'\033[1;37m'; M=$'\033[1;35m'; NC=$'\033[0m'
BG_G=$'\033[42m'; BG_R=$'\033[41m'

draw_status() {
    if systemctl is-active --quiet xray; then
        status_text="${BG_G}${W} ONLINE ${NC}"
    else
        status_text="${BG_R}${W} OFFLINE ${NC}"
    fi
    local port; port=$(jq -r '.inbounds[0].port' "$XRAY_CONF" 2>/dev/null || echo "443")
    local host; host=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host // "N/A"' "$XRAY_CONF" 2>/dev/null)
    echo -e "${M}────────────────────────────────────────────────────────────${NC}"
    echo -e " STATUS: $status_text  ${W}|${NC} PORTA: ${G}$port${NC}  ${W}|${NC} HOST: ${Y}${host:0:30}${NC}"
    echo -e "${M}────────────────────────────────────────────────────────────${NC}"
}

setup_xray() {
    clear
    echo -e "${C}⚙️  Configurando Xray xHTTP TLS...${NC}"
    mkdir -p "$SSL_DIR"
    apt update -qq && apt install jq openssl curl ufw -y &>/dev/null

    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=NetSimon/CN=www.tim.com.br" \
        -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" &>/dev/null
    chmod 644 "$SSL_DIR/privkey.pem" "$SSL_DIR/fullchain.pem"

    # Preserva clientes existentes
    local existing_clients="[]"
    if [ -f "$XRAY_CONF" ]; then
        existing_clients=$(jq -r '.inbounds[0].settings.clients // []' "$XRAY_CONF" 2>/dev/null || echo "[]")
    fi

    cat > "$XRAY_CONF" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "api": {
    "services": ["HandlerService","LoggerService","StatsService"],
    "tag": "api"
  },
  "stats": {},
  "policy": {
    "levels": { "0": { "statsUserDownlink": true, "statsUserOnline": true, "statsUserUplink": true } },
    "system": { "statsInboundDownlink": true, "statsInboundUplink": true }
  },
  "inbounds": [
    {
      "tag": "api",
      "port": 2000,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" },
      "listen": "127.0.0.1"
    },
    {
      "tag": "inbound-netsimon",
      "port": 443,
      "protocol": "vless",
      "settings": { "clients": $existing_clients, "decryption": "none" },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "xhttpSettings": {
          "path": "/",
          "host": "",
          "mode": "",
          "noSSEHeader": false,
          "scMaxBufferedPosts": 30,
          "scMaxEachPostBytes": "1000000",
          "scStreamUpServerSecs": "20-80",
          "xPaddingBytes": "100-1000"
        },
        "tlsSettings": {
          "certificates": [{ "certificateFile": "$SSL_DIR/fullchain.pem", "keyFile": "$SSL_DIR/privkey.pem" }],
          "alpn": ["http/1.1"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": { "domainStrategy": "UseIP" }, "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "inboundTag": ["api"], "outboundTag": "api", "type": "field" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF

    # Watchdog
    echo "* * * * * root if ! systemctl is-active --quiet xray; then systemctl restart xray; fi" \
        > /etc/cron.d/xray_watchdog

    systemctl daemon-reload
    systemctl restart xray
    echo -e "${G}✅ Xray configurado! Clientes preservados.${NC}"
    sleep 2
}

add_user_xray() {
    clear
    draw_status
    echo -ne "${W}👤 Nome do Usuário: ${NC}"; read nick
    [ -z "$nick" ] && return
    echo -ne "${W}📅 Dias de Validade: ${NC}"; read dias
    [ -z "$dias" ] && dias=30

    uuid=$(cat /proc/sys/kernel/random/uuid)
    exp_date=$(date -d "+$dias days" +%d/%m/%Y)

    local tmp; tmp=$(mktemp)
    jq --arg id "$uuid" --arg em "$nick" \
        '(.inbounds[] | select(.port == 443)).settings.clients += [{"id": $id, "email": $em}]' \
        "$XRAY_CONF" > "$tmp" 2>/dev/null

    if jq . "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$XRAY_CONF"
        systemctl restart xray

        local host; host=$(jq -r '.inbounds[] | select(.port==443) | .streamSettings.xhttpSettings.host // "HOST"' "$XRAY_CONF")
        local porta; porta=$(jq -r '.inbounds[] | select(.port==443) | .port' "$XRAY_CONF")

        echo -e "${G}✅ USUÁRIO XRAY CRIADO!${NC}"
        echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${Y}VLESS LINK:${NC}"
        echo -e "${C}vless://$uuid@m.ofertas.tim.com.br:$porta?encryption=none&flow=none&type=xhttp&host=$host&path=%2F&security=tls&sni=www.tim.com.br#$nick${NC}"
    else
        rm -f "$tmp"
        echo -e "${R}❌ Erro ao salvar.${NC}"
    fi
    read -p "ENTER..."
}

while true; do
    clear
    echo -e "${C}  🛰️  NETSIMON 3.0 - XRAY MANAGER${NC}"
    draw_status
    echo -e " ${G}[1]${NC} Instalar / Reconfigurar Xray"
    echo -e " ${G}[2]${NC} Criar Usuário Xray"
    echo -e " ${M}────────────────────────────────────────────────────────────${NC}"
    echo -e " ${Y}[3]${NC} 🔄 Reiniciar"
    echo -e " ${Y}[4]${NC} 🛑 Parar"
    echo -e " ${Y}[5]${NC} 🌐 Mudar Host"
    echo -e " ${Y}[6]${NC} 🔌 Mudar Porta"
    echo -e " ${R}[0]${NC} Sair"
    echo -e "${M}────────────────────────────────────────────────────────────${NC}"
    echo -ne " Escolha: "; read opt
    case $opt in
        1) setup_xray ;;
        2) add_user_xray ;;
        3) systemctl restart xray && echo -e "${G}OK!${NC}" && sleep 1 ;;
        4) systemctl stop xray && echo -e "${R}OK!${NC}" && sleep 1 ;;
        5)
            echo -ne "Novo Host: "; read nhost
            jq --arg h "$nhost" \
                '(.inbounds[] | select(.port==443)).streamSettings.xhttpSettings.host = $h' \
                "$XRAY_CONF" > /tmp/xc.tmp && mv /tmp/xc.tmp "$XRAY_CONF"
            systemctl restart xray ;;
        6)
            echo -ne "Nova Porta: "; read nport
            jq --argjson p "$nport" '(.inbounds[] | select(.port==443)).port = $p' \
                "$XRAY_CONF" > /tmp/xc.tmp && mv /tmp/xc.tmp "$XRAY_CONF"
            ufw allow "$nport"/tcp &>/dev/null
            systemctl restart xray ;;
        0) exit 0 ;;
    esac
done
