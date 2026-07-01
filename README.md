# 🚀 Painel SSH Netsimon 3.0

Painel de gerenciamento SSH/Xray com integração nativa ao **Atlas API** (`painel.netsimon.fun`), limiter híbrido avançado e controle de duplicidade por UUID.

---

## 📦 Instalação

```bash
wget -O install.sh https://raw.githubusercontent.com/miau4/Painel-SSH-Netsimon-3.0/main/install.sh
bash install.sh
```

Limpeza prévia (rm -rf): Garante que, se o usuário já tiver uma versão antiga ou um diretório com o mesmo nome, ele será removido antes da instalação para evitar conflitos de arquivos.

Clonagem (git clone): Baixa todo o seu projeto conforme ele está no GitHub, garantindo que o usuário tenha a versão mais atualizada.

Permissões (chmod +x): Garante que o arquivo de instalação tenha permissão de execução, evitando erros de "Permission Denied".

Execução imediata: Já dispara o script de instalação assim que o download termina.
```bash
rm -rf /root/netsimon && git clone https://github.com/miau4/Painel-SSH-Netsimon-3.0.git /root/netsimon && chmod +x /root/netsimon/install.sh && /root/netsimon/install.sh
```

Após instalar, acesse o painel com:
```bash
menu
```

---

## 🩹 Correções desta rodada (pós-lançamento)

### 🎯 Causa raiz da "visualização quebrada" (encontrada e corrigida)
O `atlas.sh` definia as cores do seu próprio menu com nomes genéricos (`P`, `G`, `R`, `Y`, `W`, `C`, `NC`) **no nível do arquivo**, fora de qualquer função, e com uma barra invertida duplicada (`'\\033...'` em vez de `'\033...'`). Como `atlas.sh` é carregado via `source` por `menu.sh`, `deluser.sh`, `adduser.sh` e `addtest.sh`, essa linha sobrescrevia as cores corretas desses scripts com a versão quebrada, fazendo aparecer literalmente `\033[1;36m` na tela em vez da cor. Isso explicava de uma só vez:
- A tela principal aparecendo quebrada depois de visitar o Atlas Manager.
- O menu "Remover Usuário" sempre quebrado (ele carrega o `atlas.sh` no início).
- Voltar do Atlas Manager ("0) Voltar") devolvendo ao menu principal com a tela quebrada.

**Correção:** as cores do `atlas_menu()` agora são `local` à função, e todas as definições de cor do projeto foram convertidas para aspas ANSI-C (`$'\033[...m'`), que são imunes a esse tipo de problema mesmo que ocorra um descuido futuro.

### 🐍 Bug de sintaxe Python no "Listar Usuários do Atlas"
A linha que montava o cabeçalho da tabela usava aspas simples aninhadas dentro de uma f-string também delimitada por aspas simples (`f'{'LOGIN':<15}...'`), o que é um erro de sintaxe em versões do Python anteriores à 3.12. Isso fazia o script Python falhar silenciosamente e cair no fallback `"Erro ao processar resposta do Atlas"`, mesmo com a conexão funcionando (prova disso: a opção "Testar Conexão" funcionava, pois não tinha esse bug). Essa função foi removida do submenu do Atlas e sua lógica foi unificada com "Listar Usuários" do menu principal (veja abaixo).

### 🔁 Usuários criados direto no Atlas agora aparecem no painel
Antes, o painel só conhecia usuários criados pela própria opção "Criar Usuário" do menu SSH. Usuários cadastrados diretamente no painel Atlas (web) nunca ganhavam conta Linux/Xray local e não apareciam em "Listar Usuários". Agora existe `atlas_sync_users()` em `atlas.sh`, que busca `module=userget` no Atlas e, para cada usuário:
- Se já existe localmente: atualiza senha, validade e limite a partir do Atlas.
- Se não existe localmente: cria o usuário Linux, gera (ou reaproveita) o UUID Xray, adiciona ao `config.json` e grava no banco local.

Essa sincronização roda automaticamente:
- Sempre que você abre **"04) Listar Usuários"**.
- A cada ~48s dentro do **Limiter** (`limit.sh`), mesmo sem ninguém com o menu aberto.
- Uma vez no **boot** (`boot_check.sh`), antes do Limiter subir.

### 🧭 Opções do Atlas unificadas com o menu principal
"Renovar Usuário" e "Renovar Revendedor" deixaram de ser exclusivas do submenu Atlas e agora são opções de primeira classe no menu principal (**06** e **07**), exatamente como Criar/Remover Usuário. O submenu **22) Atlas Manager** ficou enxuto, só com tarefas que não têm equivalente "local": configurar a API Key, testar conexão, forçar uma sincronização imediata e limpar Device ID.

### 📊 Painel principal agora atualiza CPU/RAM/Hora a cada 1 segundo
O loop do `menu.sh` foi reescrito: ele redesenha o painel automaticamente a cada 1 segundo (igual o antigo "Monitor Tempo Real"), mas sem bloquear a digitação — basta começar a digitar um número que o relógio para de atualizar até você confirmar a opção. O IP público não é mais buscado a cada segundo (isso seria lento); ele é cacheado e atualizado a cada ~30 ciclos.

### 🖥️ "Monitor Tempo Real" (item 17) renomeado para "Status VPS" (item 20)
O antigo `monitor.sh` tinha duas falhas reais: usava `awk "%.1f"` (valor decimal) dentro de uma conta `$((...))` do Bash, que só aceita inteiros — isso gerava erro de sintaxe aritmética sempre que a barra de CPU era desenhada; e usava a variável de cor `${O}` (laranja) sem nunca defini-la. Como a função de atualização automática foi movida para o painel principal, esse script foi totalmente reescrito como **"Status VPS"**: mostra CPU/RAM/disco/uptime, uma checklist de portas-chave do Netsimon (aberta/fechada) e a lista completa de portas em LISTEN — e volta para o menu principal com um simples ENTER, como pedido.

### 🎯 Limiter/Online não detectavam IP compartilhado no Xray
`limit.sh` (`count_xray_unique_ips`) e `online.sh` liam o `access.log` do Xray assumindo que o **UUID** do cliente aparece na linha e que o IP de origem fica no campo 6. Nenhuma das duas premissas é real: o Xray só grava o **email** do client (não o UUID) e o IP:porta de origem fica no **campo 3** da linha (`DATA HORA IP:PORTA accepted tcp:destino [tag] email: NOME`). Na prática isso zerava a contagem de IPs únicos por usuário — o anti-compartilhamento do Xray nunca expulsava ninguém, e "Usuários Online" não mostrava o IP da conexão Xray. Corrigido para filtrar por `email: $user` e extrair o IP do campo 3.

### 🌐 Campo `host` do xhttp volta em branco por padrão
O `config.json` gerado por `install.sh`/`xray.sh` tinha um domínio de CDN fixo (`idglokgvu4k.map.azionedge.net`) no `xhttpSettings.host`, herdado de uma configuração de terceiros. Agora esse campo nasce vazio (`""`); use a opção **[5] Mudar Host** do Xray Manager (item 19 do menu) para definir seu próprio domínio de fronting, se for usar essa técnica.

---

## 🆕 Novidades da versão 3.0 (lançamento inicial)

### 🌐 Integração Atlas API
- Módulo `atlas.sh` centraliza toda comunicação com `painel.netsimon.fun`.
- Criação de usuários e testes sincroniza automaticamente com o Atlas.
- Remoção de usuários notifica o Atlas via flag de expiração.

### 🔒 Limiter Híbrido 3.0
- **Bloco SSH:** detecta sessões duplicadas via `who` + processos `sshd`.
- **Bloco Xray por UUID:** conta IPs únicos conectados com o mesmo UUID nos últimos 90s e expulsa o excedente sem derrubar os demais usuários.
- Mata conexões TCP na porta 443 do usuário infrator.
- Registra o motivo do bloqueio em `/etc/xray-manager/blocked.db`.
- Loop de verificação a cada 8 segundos, com expiração automática integrada.

---

## 📋 Menu principal (numeração atual)

```
01) Criar Usuário              12) Reiniciar Xray
02) Criar Teste                13) Reparar Sistema
03) Remover Usuário            14) Ativar Limiter
04) Listar Usuários            15) Parar Limiter
05) Usuários Online            16) Teste Velocidade
06) Renovar Usuário            17) WebSocket Manager
07) Renovar Revendedor         18) SlowDNS Manager
08) Ver Bloqueados             19) Xray Manager
09) Desbloquear Usuário        20) Status VPS
10) Limpar Bloqueios           21) Ver Logs
11) Backup Config              22) Atlas Manager
```

> O painel não tem mais opção numérica de "Sair" — para encerrar, use `Ctrl+C` (o `trap` do `menu.sh` restaura o terminal normalmente antes de devolver o prompt da VPS).

---

## 📁 Estrutura de arquivos

```
/etc/painel/
├── atlas.sh          # Integração Atlas API + sincronização
├── menu.sh           # Menu principal (dashboard ao vivo)
├── adduser.sh        # Criar usuário (sync Atlas)
├── addtest.sh        # Criar teste (sync Atlas)
├── deluser.sh        # Remover usuário (notifica Atlas)
├── limit.sh          # Limiter SSH + UUID Xray + sync Atlas periódico
├── online.sh         # Usuários online
├── unblock.sh        # Desbloquear usuário
├── monitor.sh        # Status VPS (recursos + portas abertas)
├── websocket.sh       # WebSocket Manager
├── slowdns-server.sh  # SlowDNS Manager
├── xray.sh            # Xray Manager
├── checkuser.sh / .py # CheckUser API
├── proxy.py           # WebSocket/SOCKS Proxy
├── boot_check.sh       # Auto-recovery + sync Atlas no boot
├── repair.sh            # Reparar arquivos
├── atlas.key            # API Key do Atlas (chmod 600)
└── usuarios.db           # Banco local de usuários

/usr/local/etc/xray/config.json   # Config do Xray
/etc/xray-manager/ssl/            # Certificados TLS
/etc/xray-manager/blocked.db      # Usuários bloqueados pelo limiter
/var/log/xray/access.log          # Log do Xray
/var/log/netsimon_limit.log       # Log do limiter
```

---

## 🌐 Atlas API — módulos usados

| Ação | Módulo Atlas |
|------|-------------|
| Criar usuário | `criaruser` |
| Criar teste | `criarteste` |
| Renovar usuário | `renewuser` |
| Renovar revendedor | `renewrev` |
| Listar/sincronizar usuários | `userget` |
| Limpar Device ID | `deviceclean` |
| Marcar notificado (ao remover) | `notificado` |

---

## ♻️ Reparar sistema

```bash
bash /etc/painel/repair.sh
```

> A API Key do Atlas é preservada durante o repair.