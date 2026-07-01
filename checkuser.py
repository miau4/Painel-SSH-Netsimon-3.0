#!/usr/bin/env python3
# ==========================================
#   NETSIMON 3.0 - CHECKUSER API
#   Porta 5000 — consulta por login/UUID
# ==========================================

from flask import Flask, jsonify, request
import subprocess
import datetime
import os

app = Flask(__name__)

USERDB = "/etc/painel/usuarios.db"

def get_user_from_db(username):
    """Lê o banco local e retorna os dados do usuário."""
    if not os.path.exists(USERDB):
        return None
    with open(USERDB, "r") as f:
        for line in f:
            parts = line.strip().split("|")
            if len(parts) >= 5 and parts[0] == username:
                return {
                    "login": parts[0],
                    "uuid": parts[1],
                    "expira": parts[2],
                    "senha": parts[3],
                    "limite": parts[4]
                }
    return None

def get_user_by_uuid(uuid):
    """Busca usuário pelo UUID."""
    if not os.path.exists(USERDB):
        return None
    with open(USERDB, "r") as f:
        for line in f:
            parts = line.strip().split("|")
            if len(parts) >= 5 and parts[1] == uuid:
                return {
                    "login": parts[0],
                    "uuid": parts[1],
                    "expira": parts[2],
                    "senha": parts[3],
                    "limite": parts[4]
                }
    return None

def is_expired(expira_str):
    """Verifica se a data de expiração já passou."""
    try:
        expira = datetime.datetime.strptime(expira_str, "%Y-%m-%d %H:%M:%S")
        return datetime.datetime.now() > expira
    except Exception:
        try:
            expira = datetime.datetime.strptime(expira_str, "%Y-%m-%d")
            return datetime.datetime.now().date() > expira.date()
        except Exception:
            return False

def is_online_ssh(username):
    """Verifica se usuário tem sessão SSH ativa."""
    try:
        result = subprocess.check_output(
            ["who"], text=True, stderr=subprocess.DEVNULL
        )
        return any(line.split()[0] == username for line in result.splitlines() if line)
    except Exception:
        return False

# ── Endpoints ───────────────────────────────────────────────────

@app.route('/check/<username>', methods=['GET'])
def check_user(username):
    """Verifica status de um usuário por login."""
    data = get_user_from_db(username)
    if not data:
        return jsonify({"status": "not_found", "user": username}), 404

    expired = is_expired(data["expira"])
    online  = is_online_ssh(username)

    return jsonify({
        "status":  "expired" if expired else "active",
        "user":    username,
        "uuid":    data["uuid"],
        "expira":  data["expira"],
        "limite":  data["limite"],
        "online":  online
    })

@app.route('/check/uuid/<uuid>', methods=['GET'])
def check_uuid(uuid):
    """Verifica status de um usuário pelo UUID Xray."""
    data = get_user_by_uuid(uuid)
    if not data:
        return jsonify({"status": "not_found", "uuid": uuid}), 404

    expired = is_expired(data["expira"])

    return jsonify({
        "status": "expired" if expired else "active",
        "user":   data["login"],
        "uuid":   uuid,
        "expira": data["expira"],
        "limite": data["limite"]
    })

@app.route('/users', methods=['GET'])
def list_users():
    """Lista todos os usuários cadastrados (sem senha)."""
    users = []
    if os.path.exists(USERDB):
        with open(USERDB, "r") as f:
            for line in f:
                parts = line.strip().split("|")
                if len(parts) >= 5:
                    expired = is_expired(parts[2])
                    users.append({
                        "login":  parts[0],
                        "uuid":   parts[1],
                        "expira": parts[2],
                        "limite": parts[4],
                        "status": "expired" if expired else "active"
                    })
    return jsonify({"total": len(users), "users": users})

@app.route('/ping', methods=['GET'])
def ping():
    return jsonify({"status": "ok", "version": "netsimon-3.0"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
