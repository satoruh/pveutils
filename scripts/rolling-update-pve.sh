#!/usr/bin/env bash
#
# rolling-update-pve.sh - Proxmox VE クラスタを 1 ノードずつローリング更新する
#
# 運用端末から SSH 経由で各ノードを順番に更新する。ノードごとに
#   1. クラスタが quorate であることを確認
#   2. (drain=maintenance のとき) HA メンテナンスモードを有効化し HA リソースを退避
#   3. apt-get update / dist-upgrade で更新
#   4. 再起動ポリシーに従って再起動し、オンライン復帰と quorum 回復を待つ
#   5. HA メンテナンスモードを解除
# を実施し、1 ノードでも失敗したら以降は中断する。
#
# Usage:
#   ./rolling-update-pve.sh [options] [host ...]
#
# 引数の host... を SSH 対象ノードとして順に処理する。省略時は最初に
# 到達できたノードの pvecm から構成を自動検出する (--entry で起点指定)。
# apt の出力は常にノードごとのログ (./logs/) に保存される。
#
# Options:
#   -e, --entry HOST     自動検出の起点ホスト (host 引数省略時に使用)
#   -u, --user USER      SSH ユーザ (default: root)
#       --ssh CMD        ssh コマンドを上書きする (例: "ssh -F ~/.ssh/pve_config")
#                        環境変数 SSH_COMMAND でも指定可。既定の接続オプションは無効化される
#       --reboot MODE    再起動ポリシー: required|always|never (default: required)
#       --drain MODE     退避方法: maintenance|none (default: maintenance)
#   -w, --wait SECONDS   ノード復帰待ちのタイムアウト秒 (default: 900)
#   -y, --yes            ノードごとの確認プロンプトを省略する
#   -v, --verbose        apt の出力もコンソールに流す (既定は進捗のみ表示)
#   -n, --dry-run        実行内容を表示するだけで更新・再起動しない
#   -h, --help           このヘルプを表示する

set -euo pipefail

SSH_USER="root"
ENTRY=""
REBOOT_MODE="required"
DRAIN_MODE="maintenance"
WAIT_TIMEOUT=900
ASSUME_YES=0
DRY_RUN=0
VERBOSE=0
LOG_DIR="./logs"
HOSTS=()

# ssh コマンドの上書き。--ssh または環境変数 SSH_COMMAND が空なら既定を使う。
SSH_OVERRIDE="${SSH_COMMAND:-}"

source "$(dirname "${BASH_SOURCE[0]}")/lib/pve-common.sh"

usage() {
    sed -n '3,31p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--entry)  ENTRY="$2"; shift ;;
        -u|--user)   SSH_USER="$2"; shift ;;
        --ssh)       SSH_OVERRIDE="$2"; shift ;;
        --reboot)    REBOOT_MODE="$2"; shift ;;
        --drain)     DRAIN_MODE="$2"; shift ;;
        -w|--wait)   WAIT_TIMEOUT="$2"; shift ;;
        -y|--yes)    ASSUME_YES=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help)   usage 0 ;;
        --) shift; while [[ $# -gt 0 ]]; do HOSTS+=("$1"); shift; done; break ;;
        -*) err "不明なオプション: $1"; usage 1 ;;
        *)  HOSTS+=("$1") ;;
    esac
    shift
done

case "$REBOOT_MODE" in required|always|never) ;; *) err "--reboot は required|always|never"; exit 1 ;; esac
case "$DRAIN_MODE"  in maintenance|none) ;;     *) err "--drain は maintenance|none"; exit 1 ;; esac

build_ssh_cmd

# 到達可能なホストを返す (除外ホストを 1 つ指定可)。
reference_host() {
    local exclude="$1" h
    for h in "${HOSTS[@]}"; do
        [[ "$h" == "$exclude" ]] && continue
        if rssh "$h" true >/dev/null 2>&1; then
            printf '%s\n' "$h"
            return 0
        fi
    done
    return 1
}

resolve_hosts() {
    if [[ ${#HOSTS[@]} -gt 0 ]]; then
        return 0
    fi
    local entry="${ENTRY}"
    [[ -z "$entry" ]] && { err "host 引数も --entry も指定がありません。"; exit 1; }
    log "起点 ${entry} の pvecm からクラスタ構成を検出します"
    mapfile -t HOSTS < <(rssh "$entry" "pvecm nodes 2>/dev/null | awk '\$1 ~ /^[0-9]+\$/ {print \$3}'")
    [[ ${#HOSTS[@]} -gt 0 ]] || { err "ノードを検出できませんでした。"; exit 1; }
}

update_node() {
    local host="$1"
    local nodename; nodename="$(node_name "$host")"
    log "===== ノード ${nodename} (${host}) の更新を開始 ====="

    local ref; ref="$(reference_host "$host" || true)"
    if [[ ${#HOSTS[@]} -gt 1 ]]; then
        [[ -n "$ref" ]] || { err "到達可能な他ノードがありません。クラスタ状態を確認できません。"; return 1; }
        log "クラスタの quorum を確認します (${ref} 経由)"
        cluster_quorate "$ref" || { err "クラスタが quorate ではありません。中断します。"; return 1; }
    fi

    if [[ $ASSUME_YES -ne 1 && $DRY_RUN -ne 1 ]]; then
        read -r -p "ノード ${nodename} を更新しますか? [y/N] " reply
        case "$reply" in [yY][eE][sS]|[yY]) ;; *) warn "${nodename} をスキップしました。"; return 0 ;; esac
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] drain=${DRAIN_MODE} → apt-get update/dist-upgrade → reboot=${REBOOT_MODE} を実行予定"
        return 0
    fi

    if [[ "$DRAIN_MODE" == "maintenance" ]]; then
        log "HA メンテナンスモードを有効化し HA リソースを退避します"
        rssh "$host" "ha-manager crm-command node-maintenance enable ${nodename}" || \
            warn "メンテナンスモード有効化に失敗 (HA 未構成の可能性)。続行します。"
    fi

    # 公式手順 (System Software Updates wiki) に合わせ apt-get を直接使う。
    # pveupdate/pveupgrade は対話プロンプトを出す wrapper のため無人実行に不向き。
    # 設定ファイルの差し替え確認も抑止して既存設定を保持する。
    local upgrade='set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get --yes -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade
        apt-get --yes autoremove'

    # apt の出力は常にログへ残す。既定はコンソールに流さず進捗のみ、
    # --verbose のときだけ tee でライブ表示する。
    mkdir -p "$LOG_DIR"
    local logfile="${LOG_DIR}/${nodename}-$(date +%Y%m%d-%H%M%S).log"
    log "パッケージを更新します (apt-get update / dist-upgrade)"
    if [[ $VERBOSE -eq 1 ]]; then
        rssh "$host" "$upgrade" 2>&1 | tee "$logfile"
    elif ! rssh "$host" "$upgrade" >"$logfile" 2>&1; then
        err "更新に失敗しました。ログ末尾 (${logfile}):"
        tail -n 20 "$logfile" >&2
        return 1
    fi
    log "更新完了 (ログ: ${logfile})"

    local need_reboot=0
    case "$REBOOT_MODE" in
        always)   need_reboot=1 ;;
        never)    need_reboot=0 ;;
        required) rssh "$host" 'test -f /var/run/reboot-required' && need_reboot=1 || true ;;
    esac

    if [[ $need_reboot -eq 1 ]]; then
        log "${nodename} を再起動します"
        rssh "$host" 'reboot' || true
        log "ノードのダウンを待ちます"
        wait_for "ノード ${nodename} の停止" node_unreachable "$host"
        log "ノードのオンライン復帰と quorum 回復を待ちます (最大 ${WAIT_TIMEOUT}s)"
        wait_for "ノード ${nodename} の復帰" cluster_quorate "$host"
        log "${nodename} がオンラインに復帰しました"
    else
        log "再起動は行いません (reboot=${REBOOT_MODE})"
    fi

    if [[ "$DRAIN_MODE" == "maintenance" ]]; then
        log "HA メンテナンスモードを解除します"
        rssh "$host" "ha-manager crm-command node-maintenance disable ${nodename}" || \
            warn "メンテナンスモード解除に失敗。手動で確認してください: ha-manager crm-command node-maintenance disable ${nodename}"
    fi

    log "===== ノード ${nodename} の更新が完了 ====="
}

main() {
    resolve_hosts

    log "対象ノード (この順で処理): ${HOSTS[*]}"
    [[ $DRY_RUN -eq 1 ]] && warn "dry-run モードです。実際の更新・再起動は行いません。"

    for host in "${HOSTS[@]}"; do
        update_node "$host"
    done

    log "全ノードのローリング更新が完了しました。"
}

main
