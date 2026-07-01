#!/bin/bash
# ==========================================
#   NETSIMON 3.0 - AUTO-RECOVERY NO BOOT
# ==========================================

BASE="/etc/painel"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_LOG="/var/log/xray/access.log"

# Aguarda rede e serviços estabilizarem
sleep 15

# 0. Sincroniza usuários do Atlas antes de tudo, para que o
#    Limiter já nasça sabendo de usuários criados direto no painel
source "$BASE/atlas.sh" 2>/dev/null
if type atlas_sync_users &>/dev/null; then
    atlas_sync_users >> /var/log/netsimon_limit.log 2>&1
fi

# 1. Limiter
if ! pgrep -f "limit.sh" > /dev/null; then
    screen -dmS limitador bash "$BASE/limit.sh"
fi

# 2. Xray
if [ -f "/usr/local/bin/xray" ] && [ -f "$XRAY_CONF" ]; then
    if ! systemctl is-active --quiet xray; then
        systemctl start xray
    fi
fi

# 3. WebSocket (proxy.py)
if ! pgrep -f "proxy.py" > /dev/null; then
    screen -dmS ws80 python3 "$BASE/proxy.py" 80 &>/dev/null
fi

# 4. CheckUser API
if ! pgrep -f "checkuser.py" > /dev/null; then
    nohup python3 "$BASE/checkuser.py" > /dev/null 2>&1 &
fi

# 5. SlowDNS
if [ -f "/etc/slowdns/priv.key" ] && [ -f "/etc/slowdns/domain" ]; then
    if ! pgrep -f "dnstt-server" > /dev/null; then
        NS=$(cat /etc/slowdns/domain 2>/dev/null || hostname)
        systemctl stop systemd-resolved &>/dev/null
        nohup /etc/slowdns/dnstt-server -udp :5353 \
            -privkey-file /etc/slowdns/priv.key "$NS" 127.0.0.1:22 > /dev/null 2>&1 &
    fi
fi

# 6. Limpeza segura de log do Xray (somente se > 50MB)
#    NÃO apaga logs do sistema — apenas o log de acesso do Xray
if [ -f "$XRAY_LOG" ]; then
    tamanho=$(stat -c%s "$XRAY_LOG" 2>/dev/null || echo 0)
    if [ "$tamanho" -gt 52428800 ]; then
        # Mantém as últimas 1000 linhas antes de truncar
        tail -n 1000 "$XRAY_LOG" > /tmp/xray_access_last.log
        cat /tmp/xray_access_last.log > "$XRAY_LOG"
        rm -f /tmp/xray_access_last.log
    fi
fi

exit 0
