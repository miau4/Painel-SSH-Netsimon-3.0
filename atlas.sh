#!/bin/bash
# ==========================================
#   NETSIMON 3.0 - MÓDULO ATLAS API
#   Integração central com painel.netsimon.fun
# ==========================================
# IMPORTANTE: este arquivo é "sourced" (source) por outros scripts
# (menu.sh, adduser.sh, addtest.sh, deluser.sh, limit.sh, boot_check.sh).
# Por isso ele NUNCA deve definir variáveis globais com nomes genéricos
# como P/G/R/Y/W/C/NC — isso sobrescreveria as cores do script que o
# chamou. Cores usadas aqui ficam sempre dentro de funções, como "local".

ATLAS_URL="https://painel.netsimon.fun/core/apiatlas.php"
ATLAS_KEY_FILE="/etc/painel/atlas.key"
USERDB="/etc/painel/usuarios.db"
XRAY_CONF="/usr/local/etc/xray/config.json"

# -------------------------------------------------------
# Carrega a chave do disco (salva uma vez pelo install.sh)
# -------------------------------------------------------
atlas_get_key() {
    if [ ! -f "$ATLAS_KEY_FILE" ] || [ ! -s "$ATLAS_KEY_FILE" ]; then
        echo ""
        return 1
    fi
    cat "$ATLAS_KEY_FILE"
}

# -------------------------------------------------------
# Chamada genérica para a API do Atlas
# Retorna o corpo da resposta HTTP ou vazio em caso de erro
# -------------------------------------------------------
atlas_call() {
    local key
    key=$(atlas_get_key)
    if [ -z "$key" ]; then
        echo "[ATLAS] ERRO: chave API não configurada em $ATLAS_KEY_FILE" >&2
        return 1
    fi

    local extra_params=()
    for arg in "$@"; do
        extra_params+=(--data-urlencode "$arg")
    done

    local response
    response=$(curl -s --max-time 10 \
        -X POST "$ATLAS_URL" \
        --data-urlencode "passapi=$key" \
        "${extra_params[@]}" 2>/dev/null)

    local curl_exit=$?
    if [ $curl_exit -ne 0 ]; then
        echo "[ATLAS] ERRO de rede (curl exit $curl_exit)" >&2
        return 1
    fi

    echo "$response"
}

# -------------------------------------------------------
# Funções de alto nível — usadas pelos outros módulos
# -------------------------------------------------------

atlas_criar_user() {
    local user="$1" pass="$2" dias="$3" limite="$4" whatsapp="${5:-}"
    atlas_call \
        "module=criaruser" "user=$user" "pass=$pass" "admincid=1" \
        "validadeusuario=$dias" "userlimite=$limite" "whatsapp=$whatsapp"
}

atlas_criar_teste() {
    local user="$1" pass="$2" minutos="$3"
    atlas_call \
        "module=criarteste" "user=$user" "pass=$pass" \
        "testtime=$minutos" "admincid=1"
}

atlas_renovar_user() {
    local user="$1"
    atlas_call "module=renewuser" "user=$user"
}

atlas_renovar_rev() {
    local user="$1"
    atlas_call "module=renewrev" "user=$user"
}

# Marca o usuário como "notificado" no Atlas (usado quando removemos
# o usuário localmente, para manter os dois lados cientes da remoção)
atlas_desativar_user() {
    local user="$1"
    local resp uid
    resp=$(atlas_call "module=userget")
    [ -z "$resp" ] && return 1

    uid=$(echo "$resp" | ATLAS_TARGET_USER="$user" python3 -c "
import sys, json, os
target = os.environ.get('ATLAS_TARGET_USER', '')
try:
    data = json.loads(sys.stdin.read())
    for u in data:
        if u.get('login', '') == target:
            print(u.get('id', ''))
            break
except Exception:
    pass
" 2>/dev/null)

    if [ -n "$uid" ]; then
        atlas_call "module=notificado" "idpony=$uid" > /dev/null
    fi
}

atlas_listar_users() {
    atlas_call "module=userget"
}

atlas_onlines() {
    atlas_call "module=onlinesadm"
}

atlas_limpar_device() {
    local user="$1"
    atlas_call "module=deviceclean" "user=$user"
}

atlas_criar_rev() {
    local user="$1" pass="$2" limite="$3" whatsapp="${4:-}"
    atlas_call \
        "module=createrev" "user=$user" "pass=$pass" "admincid=1" \
        "userlimite=$limite" "whatsapp=$whatsapp"
}

# -------------------------------------------------------
# SINCRONIZAÇÃO ATLAS -> LOCAL
# O Atlas é a fonte da verdade. Usuários criados diretamente
# no painel Atlas (painel.netsimon.fun) precisam ganhar conta
# Linux + UUID Xray localmente para que o túnel funcione e para
# que apareçam em "Listar Usuários" / no Limiter.
# Retorna uma linha de resumo "N novo(s), M atualizado(s)".
# -------------------------------------------------------
atlas_sync_users() {
    local resp
    resp=$(atlas_listar_users 2>/dev/null)

    if [ -z "$resp" ]; then
        echo "sem resposta do Atlas"
        return 1
    fi

    if ! echo "$resp" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
assert isinstance(d, list)
" 2>/dev/null; then
        echo "resposta inválida do Atlas"
        return 1
    fi

    local linhas
    linhas=$(echo "$resp" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
except Exception:
    data = []
for u in data:
    login  = (u.get('login') or '').strip()
    senha  = (u.get('senha') or '').strip()
    expira = (u.get('expira') or '').strip()
    limite = str(u.get('limite') or '1').strip()
    uuidat = (u.get('uuid') or '').strip()
    if not login:
        continue
    print(login + '|' + senha + '|' + expira + '|' + limite + '|' + uuidat)
" 2>/dev/null)

    [ -z "$linhas" ] && { echo "0 novo(s), 0 atualizado(s)"; return 0; }

    local novos=0
    local atualizados=0
    [ ! -f "$USERDB" ] && touch "$USERDB"

    while IFS='|' read -r login senha expira limite uuidat; do
        [ -z "$login" ] && continue
        # Apenas logins com caracteres seguros (letras, números, . _ -)
        if [[ ! "$login" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            continue
        fi
        [ -z "$expira" ] && expira="$(date -d '+30 days' +'%Y-%m-%d 23:59:59')"
        [ -z "$limite" ] && limite=1
        [ -z "$senha" ] && senha="netsimon"

        if grep -q "^$login|" "$USERDB" 2>/dev/null; then
            # Já existe localmente: atualiza expira/senha/limite, mantém o UUID local
            local uuid_local
            uuid_local=$(grep "^$login|" "$USERDB" | head -n1 | cut -d'|' -f2)
            awk -F'|' -v login="$login" -v uuid="$uuid_local" -v exp="$expira" \
                -v senha="$senha" -v lim="$limite" 'BEGIN{OFS="|"}
                $1==login {print login, uuid, exp, senha, lim; next}
                {print}' "$USERDB" > "$USERDB.tmp" 2>/dev/null \
                && mv "$USERDB.tmp" "$USERDB"
            echo "$login:$senha" | chpasswd &>/dev/null

            # AUTO-CURA: usuários vindos de um sync antigo podem ter ficado
            # gravados no usuarios.db sem nunca terem entrado no array
            # "clients" do Xray (ex.: falha silenciosa de jq no primeiro
            # sync, feito no boot antes do Xray subir). Sem essa checagem,
            # esse usuário fica "órfão" para sempre, pois este branch nunca
            # tocava no config.json. Aqui verificamos se o email já está
            # presente e, se não estiver, injetamos usando o UUID já salvo.
            if [ -f "$XRAY_CONF" ] && [ -n "$uuid_local" ]; then
                local ja_existe
                ja_existe=$(jq --arg u "$login" \
                    '[.inbounds[] | select(.port == 443) | .settings.clients[]? | select(.email == $u)] | length' \
                    "$XRAY_CONF" 2>/dev/null)
                if [ "$ja_existe" = "0" ] || [ -z "$ja_existe" ]; then
                    local tmp2; tmp2=$(mktemp)
                    jq --arg u "$login" --arg id "$uuid_local" \
                        '(.inbounds[] | select(.port == 443)).settings.clients += [{"id": $id, "email": $u}]' \
                        "$XRAY_CONF" > "$tmp2" 2>/dev/null
                    if jq . "$tmp2" >/dev/null 2>&1; then
                        mv "$tmp2" "$XRAY_CONF"
                        ((novos++))
                    else
                        rm -f "$tmp2"
                        echo "[ATLAS] ERRO: falha ao curar cliente órfão '$login' no Xray" >&2
                    fi
                fi
            fi
            ((atualizados++))
        else
            # Não existe localmente: cria usuário Linux + Xray + registro local
            if ! id "$login" &>/dev/null; then
                useradd -M -s /bin/false "$login" &>/dev/null
            fi
            echo "$login:$senha" | chpasswd &>/dev/null

            local exp_chage
            exp_chage=$(echo "$expira" | cut -d' ' -f1)
            [ -n "$exp_chage" ] && chage -E "$exp_chage" "$login" 2>/dev/null

            local uuid_final="$uuidat"
            [ -z "$uuid_final" ] && uuid_final=$(cat /proc/sys/kernel/random/uuid)

            if [ -f "$XRAY_CONF" ]; then
                local tmp; tmp=$(mktemp)
                jq --arg u "$login" --arg id "$uuid_final" \
                    '(.inbounds[] | select(.port == 443)).settings.clients += [{"id": $id, "email": $u}]' \
                    "$XRAY_CONF" > "$tmp" 2>/dev/null
                if jq . "$tmp" >/dev/null 2>&1; then
                    mv "$tmp" "$XRAY_CONF"
                else
                    rm -f "$tmp"
                    echo "[ATLAS] ERRO: falha ao injetar '$login' no Xray (config.json ausente/inválido no momento do sync)" >&2
                fi
            fi

            echo "$login|$uuid_final|$expira|$senha|$limite" >> "$USERDB"
            ((novos++))
        fi
    done <<< "$linhas"

    [ "$novos" -gt 0 ] && systemctl restart xray &>/dev/null

    echo "$novos novo(s), $atualizados atualizado(s)"
}

# -------------------------------------------------------
# Menu de gerenciamento do Atlas (chamado pelo menu.sh)
# Apenas tarefas administrativas específicas do Atlas ficam
# aqui. Ações do dia a dia (criar/listar/renovar usuário) já
# vivem no menu principal e conversam com o Atlas por trás dos
# panos — não há duas listas de usuários separadas.
# -------------------------------------------------------
atlas_menu() {
    local P=$'\033[1;35m' G=$'\033[1;32m' R=$'\033[1;31m'
    local Y=$'\033[1;33m' W=$'\033[1;37m' C=$'\033[1;36m' NC=$'\033[0m'

    while true; do
        clear
        local key; key=$(atlas_get_key 2>/dev/null)
        [ -z "$key" ] && key="NÃO CONFIGURADA"

        echo -e "${P}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${P}║${W}               🌐 GERENCIADOR ATLAS API                       ${P}║${NC}"
        echo -e "${P}╠══════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${P}║${NC} ${W}URL  :${C} $ATLAS_URL${NC}"
        echo -e "${P}║${NC} ${W}KEY  :${Y} $key${NC}"
        echo -e "${P}╠══════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${P}║${G} 1)${NC} Configurar / Alterar API Key"
        echo -e "${P}║${C} 2)${NC} Testar Conexão com Atlas"
        echo -e "${P}║${C} 3)${NC} Sincronizar Usuários Agora"
        echo -e "${P}║${C} 4)${NC} Limpar Device ID de Usuário"
        echo -e "${P}║${R} 0)${NC} Voltar"
        echo -e "${P}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo -ne "${Y} Escolha: ${NC}"; read -r op

        case $op in
            1)
                echo -ne "\n${W}Cole sua API Key do Atlas: ${NC}"; read -r nova_key
                if [ -n "$nova_key" ]; then
                    echo "$nova_key" > "$ATLAS_KEY_FILE"
                    chmod 600 "$ATLAS_KEY_FILE"
                    echo -e "${G}✅ Chave salva com sucesso!${NC}"
                else
                    echo -e "${R}Chave vazia, nada alterado.${NC}"
                fi
                sleep 2 ;;
            2)
                echo -e "\n${Y}Testando conexão...${NC}"
                local resp; resp=$(atlas_listar_users 2>&1)
                if echo "$resp" | python3 -c "import sys, json; json.loads(sys.stdin.read())" 2>/dev/null; then
                    local qtd
                    qtd=$(echo "$resp" | python3 -c "import sys, json; print(len(json.loads(sys.stdin.read())))" 2>/dev/null)
                    echo -e "${G}✅ Atlas respondeu corretamente!${NC}"
                    echo -e "${W}Usuários cadastrados no Atlas: ${C}${qtd}${NC}"
                else
                    echo -e "${R}❌ Falha na conexão ou chave inválida.${NC}"
                    echo -e "${W}Resposta bruta: ${Y}$resp${NC}"
                fi
                read -rp "ENTER para continuar..." ;;
            3)
                echo -e "\n${Y}Sincronizando usuários do Atlas...${NC}"
                local resultado; resultado=$(atlas_sync_users)
                echo -e "${G}✅ Sincronização concluída: ${C}$resultado${NC}"
                read -rp "ENTER para continuar..." ;;
            4)
                echo -ne "\n${W}Usuário para limpar Device ID: ${NC}"; read -r udev
                if [ -n "$udev" ]; then
                    local r; r=$(atlas_limpar_device "$udev")
                    echo -e "${C}Atlas: $r${NC}"
                fi
                sleep 2 ;;
            0) return ;;
            *) echo -e "${R}Opção inválida!${NC}"; sleep 1 ;;
        esac
    done
}
