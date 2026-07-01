#!/bin/bash
# ==========================================
#   NETSIMON 3.0 - INSTALADOR (OTIMIZADO)
# ==========================================

C=$'\033[1;36m'; G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; W=$'\033[1;37m'; NC=$'\033[0m'
REPO="https://raw.githubusercontent.com/miau4/Painel-SSH-Netsimon-3.0/main"
BASE="/etc/painel"
XRAY_CONF="/usr/local/etc/xray/config.json"
SSL_DIR="/etc/xray-manager/ssl"

clear
echo -e "${C}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${C}║${W}              🚀 INSTALADOR NETSIMON 3.0                       ${C}║${NC}"
echo -e "${C}╚══════════════════════════════════════════════════════════════╝${NC}"

# 1. Timezone e Firewall
echo -ne "${W}[+] Sincronizando relógio e liberando firewall... ${NC}"
timedatectl set-timezone America/Sao_Paulo
iptables -F && iptables -X
iptables -t nat -F && iptables -t nat -X
iptables -t mangle -F && iptables -t mangle -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
systemctl stop apache2 oracle-cloud-agent oracle-cloud-agent-updater nginx &>/dev/null
systemctl disable apache2 oracle-cloud-agent oracle-cloud-agent-updater &>/dev/null
apt purge apache2 -y &>/dev/null
echo -e "${G}OK${NC}"

# 2. Dependências
echo -ne "${W}[+] Instalando dependências... ${NC}"
apt update -y &>/dev/null
apt install wget curl jq python3 python3-pip dos2unix nginx \
    stunnel4 net-tools lsof iptables-persistent screen at -y &>/dev/null
systemctl enable --now atd &>/dev/null
echo -e "${G}OK${NC}"

# 3. Nginx na porta 81
echo -ne "${W}[+] Configurando Nginx (porta 81)... ${NC}"
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/netsimon_web <<'EOF'
server {
    listen 81;
    server_name _;
    location / { root /var/www/html; index index.html; }
}
EOF
ln -sf /etc/nginx/sites-available/netsimon_web /etc/nginx/sites-enabled/
systemctl restart nginx &>/dev/null
echo -e "${G}OK${NC}"

# 4. Stunnel
echo -ne "${W}[+] Configurando Stunnel (porta 8443)... ${NC}"
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 -sha256 \
    -subj "/CN=Netsimon" \
    -keyout /etc/stunnel/stunnel.pem -out /etc/stunnel/stunnel.pem &>/dev/null
cat > /etc/stunnel/stunnel.conf <<'EOF'
pid = /var/run/stunnel4.pid
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh]
accept = 8443
connect = 127.0.0.1:22
EOF
sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4
systemctl restart stunnel4 &>/dev/null
echo -e "${G}OK${NC}"

# 5. Estrutura de diretórios
echo -ne "${W}[+] Criando estrutura de diretórios... ${NC}"
mkdir -p "$BASE" "$SSL_DIR" "/etc/slowdns" "/var/log/xray" "/usr/local/etc/xray" "/etc/xray-manager"
touch /var/log/xray/access.log /var/log/xray/error.log
chmod -R 777 /var/log/xray
touch "$BASE/usuarios.db"
touch "/etc/xray-manager/blocked.db"
echo -e "${G}OK${NC}"

# 6. Download dos módulos
arquivos=(
    "menu.sh" "adduser.sh" "addtest.sh" "deluser.sh"
    "online.sh" "limit.sh" "unblock.sh" "websocket.sh"
    "xray.sh" "slowdns-server.sh" "monitor.sh" "proxy.py"
    "boot_check.sh" "repair.sh" "checkuser.py" "checkuser.sh"
    "atlas.sh"
)

echo -e "${Y}[!] Baixando módulos Netsimon 3.0...${NC}"
for file in "${arquivos[@]}"; do
    printf "${W}  -> %-20s ${NC}" "$file"
    wget -q -O "$BASE/$file" "$REPO/$file"
    if [ -s "$BASE/$file" ]; then
        chmod +x "$BASE/$file"
        dos2unix "$BASE/$file" &>/dev/null
        echo -e "${G}[OK]${NC}"
    else
        echo -e "${R}[FALHA]${NC}"
    fi
done

# 7. Xray
echo -ne "${W}[+] Instalando Xray... ${NC}"
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) &>/dev/null
setcap 'cap_net_bind_service=+ep' /usr/local/bin/xray 2>/dev/null

# Gera SSL
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/C=BR/ST=SP/L=SP/O=NetSimon/CN=www.tim.com.br" \
    -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" &>/dev/null
chmod 644 "$SSL_DIR/privkey.pem" "$SSL_DIR/fullchain.pem"

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
      "settings": { "clients": [], "decryption": "none" },
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
echo -e "${G}OK${NC}"

# 7.1 Otimização de Kernel (NETSIMON)
echo -ne "${W}[+] Aplicando Otimizações de Kernel... ${NC}"
sed -i '/net.ipv4.tcp_tw_reuse/d' /etc/sysctl.conf
sed -i '/net.ipv4.ip_local_port_range/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_fin_timeout/d' /etc/sysctl.conf
cat <<EOF >> /etc/sysctl.conf
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_fin_timeout=15
EOF
sysctl -p &>/dev/null
echo -e "${G}OK${NC}"

# 8. Systemd do Xray
echo -ne "${W}[+] Configurando serviço Xray... ${NC}"
cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service - Netsimon 3.0
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable xray &>/dev/null
systemctl start xray
echo -e "${G}OK${NC}"

# 9. Watchdog do Xray
echo "* * * * * root if ! systemctl is-active --quiet xray; then systemctl restart xray; fi" \
    > /etc/cron.d/xray_watchdog

# 10. Atalhos, limiter e crontab
echo -ne "${W}[+] Ativando Limiter e atalhos... ${NC}"
echo "bash $BASE/menu.sh" > /usr/local/bin/menu
chmod +x /usr/local/bin/menu
screen -dmS limitador bash "$BASE/limit.sh"
(crontab -l 2>/dev/null | grep -v "limit.sh"; echo "@reboot screen -dmS limitador bash $BASE/limit.sh") | crontab -
(crontab -l 2>/dev/null | grep -v "boot_check.sh"; echo "@reboot bash $BASE/boot_check.sh") | crontab -
netfilter-persistent save &>/dev/null
echo -e "${G}OK${NC}"

# 11. Configuração do Atlas API
echo ""
echo -e "${Y}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${Y}║${W}            🌐 CONFIGURAÇÃO DO ATLAS API                       ${Y}║${NC}"
echo -e "${Y}╚══════════════════════════════════════════════════════════════╝${NC}"
echo -e "${W}Para integrar com o painel Atlas em painel.netsimon.fun,${NC}"
echo -e "${W}informe sua API Key. Você pode configurar depois com a opção 20 do menu.${NC}"
echo -ne "${C}Cole sua API Key (ou Enter para pular): ${NC}"
read atlas_key
if [ -n "$atlas_key" ]; then
    echo "$atlas_key" > "$BASE/atlas.key"
    chmod 600 "$BASE/atlas.key"
    echo -e "${G}✅ Atlas configurado!${NC}"
else
    echo -e "${Y}⚠ Atlas não configurado. Use a opção 20 do menu para configurar.${NC}"
fi

echo ""

# Fix: mascara swap órfão para evitar filesystem em read-only no boot
if [ ! -f /swapfile ]; then
    systemctl mask swapfile.swap &>/dev/null
fi
echo -e "${G}✅ INSTALAÇÃO NETSIMON 3.0 CONCLUÍDA!${NC}"
echo -e "${W}Portas: ${C}443 (Xray), 80 (WS), 81 (Web), 8443 (SSL), 2000 (API interna)${NC}"
echo -e "${W}Digite ${C}menu${W} para começar.${NC}"