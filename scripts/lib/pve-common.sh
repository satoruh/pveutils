#!/usr/bin/env bash
#
# pve-common.sh - pveutils スクリプト共通のヘルパ。
#
# 利用側で以下のグローバルを定義し、引数解釈後に build_ssh_cmd を呼んでから
# rssh 系を使う:
#   SSH_USER       SSH ユーザ
#   SSH_OVERRIDE   ssh コマンドの上書き (空なら既定)。--ssh / SSH_COMMAND 由来
#   WAIT_TIMEOUT   wait_for のタイムアウト秒

log()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

# 実際に使う ssh コマンド (SSH_CMD 配列) を確定する。上書き時はユーザ指定を
# そのまま使い、既定の接続オプションは付与しない (ユーザが完全に制御する)。
build_ssh_cmd() {
    if [[ -n "${SSH_OVERRIDE:-}" ]]; then
        read -r -a SSH_CMD <<< "$SSH_OVERRIDE"
    else
        SSH_CMD=(ssh "${SSH_OPTS[@]}")
    fi
    command -v "${SSH_CMD[0]}" >/dev/null 2>&1 || { err "ssh コマンドが見つかりません: ${SSH_CMD[0]}"; exit 1; }
}

# SSH ヘルパ。第 1 引数がホスト、以降が remote で実行するコマンド。
rssh() {
    local host="$1"; shift
    "${SSH_CMD[@]}" "${SSH_USER}@${host}" "$@"
}

# 指定ホストの Proxmox ノード名 (pvecm 上の名前) を取得する。
node_name() {
    rssh "$1" hostname
}

cluster_quorate() {
    rssh "$1" 'pvecm status 2>/dev/null | grep -qi "Quorate:\s*Yes"'
}

# 指定ホストに SSH 到達できないとき成功を返す (ダウン待ち用)。
node_unreachable() {
    ! rssh "$1" true >/dev/null 2>&1
}

wait_for() {  # wait_for "説明" 判定コマンド... ; タイムアウトで 1
    local desc="$1"; shift
    local deadline=$(( SECONDS + WAIT_TIMEOUT ))
    while ! "$@" >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
            err "タイムアウト: ${desc}"
            return 1
        fi
        sleep 5
    done
}
