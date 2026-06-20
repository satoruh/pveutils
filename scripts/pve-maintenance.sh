#!/usr/bin/env bash
#
# pve-maintenance.sh - 物理メンテのため Proxmox VE ノードを切り離す / 復帰させる
#
# 運用端末から SSH 経由で 1 ノードをクラスタから安全に切り離し、作業後に戻す。
#
# Usage:
#   pve-maintenance.sh drain  [options] <host>   メンテ前: ノードを切り離す
#   pve-maintenance.sh online [options] <host>   メンテ後: ノードを復帰させる
#
# drain:
#   HA メンテナンスモードを有効化して HA 管理ゲストを退避させ、非 HA の稼働
#   ゲストを他のオンラインノードへ移行する (VM は online、CT は restart 移行)。
#   退避先はオンラインの他ノードから自動で振り分ける。全ゲストの退避完了を待ち、
#   --shutdown 指定時はその後ノードを電源断する。
# online:
#   ノードのオンライン復帰と quorum 回復を確認し、HA メンテナンスモードを解除する
#   (HA ゲストは戻る。drain で手動移行したゲストは自動では戻らない)。
#
# Options:
#   -u, --user USER    SSH ユーザ (default: root)
#       --ssh CMD      ssh コマンドを上書きする (環境変数 SSH_COMMAND でも可)
#   -w, --wait SEC     退避/復帰待ちのタイムアウト秒 (default: 600)
#       --shutdown     drain 後にノードを電源断する
#   -y, --yes          確認プロンプトを省略する
#   -n, --dry-run      実行せず予定を表示する
#   -h, --help         このヘルプを表示する

set -euo pipefail

SSH_USER="root"
WAIT_TIMEOUT=600
SHUTDOWN=0
ASSUME_YES=0
DRY_RUN=0
SUBCMD=""
HOST=""

SSH_OVERRIDE="${SSH_COMMAND:-}"

# shellcheck source=scripts/lib/pve-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pve-common.sh"

usage() {
    sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)   SSH_USER="$2"; shift ;;
        --ssh)       SSH_OVERRIDE="$2"; shift ;;
        -w|--wait)   WAIT_TIMEOUT="$2"; shift ;;
        --shutdown)  SHUTDOWN=1 ;;
        -y|--yes)    ASSUME_YES=1 ;;
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help)   usage 0 ;;
        --) shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done; break ;;
        -*) err "不明なオプション: $1"; usage 1 ;;
        *)  POSITIONAL+=("$1") ;;
    esac
    shift
done

SUBCMD="${POSITIONAL[0]:-}"
HOST="${POSITIONAL[1]:-}"
case "$SUBCMD" in drain|online) ;; *) err "サブコマンドは drain か online"; usage 1 ;; esac
[[ -n "$HOST" ]] || { err "対象ホストを指定してください。"; usage 1; }

build_ssh_cmd

# 対象ノード上で実行する退避処理。HA ゲストはメンテナンスモードに任せ、
# 非 HA の稼働ゲストのみ他ノードへ振り分けて移行する。
# 環境変数: DRY (非空で予定表示のみ), WAIT (退避待ちタイムアウト秒)
remote_drain() {
    rssh "$1" "DRY='${2}' WAIT='${WAIT_TIMEOUT}' bash -s" <<'REMOTE'
set -u
node=$(hostname)
echo "[node ${node}] 切り離しを開始"
[ -n "${DRY:-}" ] && echo "  (dry-run: 実際の移行・電源操作は行いません)"

mapfile -t targets < <(pvecm nodes 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $3}' | grep -vx "$node")
if [ ${#targets[@]} -eq 0 ]; then echo "  退避先のオンラインノードがありません" >&2; exit 1; fi
echo "  退避先候補: ${targets[*]}"

ha_ids=$(ha-manager status 2>/dev/null | sed -n 's/^service [a-z]\+:\([0-9]\+\).*/\1/p' | sort -u)
is_ha() { printf '%s\n' "$ha_ids" | grep -qx "$1"; }

if [ -z "${DRY:-}" ]; then
    if ha-manager crm-command node-maintenance enable "$node" 2>/dev/null; then
        echo "  HA メンテナンスモードを有効化 (HA ゲストを退避)"
    else
        echo "  HA 未構成または有効化失敗、続行"
    fi
else
    echo "  [plan] HA メンテナンスモードを有効化"
fi

i=0
for vmid in $(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}'); do
    if is_ha "$vmid"; then echo "  VM ${vmid}: HA 管理のため自動退避に任せる"; continue; fi
    t=${targets[$((i % ${#targets[@]}))]}; i=$((i + 1))
    if [ -n "${DRY:-}" ]; then echo "  [plan] VM ${vmid} → ${t} (online)"; else
        echo "  VM ${vmid} → ${t} (online migrate)"; qm migrate "$vmid" "$t" --online
    fi
done

for ctid in $(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}'); do
    if is_ha "$ctid"; then echo "  CT ${ctid}: HA 管理のため自動退避に任せる"; continue; fi
    t=${targets[$((i % ${#targets[@]}))]}; i=$((i + 1))
    if [ -n "${DRY:-}" ]; then echo "  [plan] CT ${ctid} → ${t} (restart)"; else
        echo "  CT ${ctid} → ${t} (restart migrate)"; pct migrate "$ctid" "$t" --restart
    fi
done

if [ -n "${DRY:-}" ]; then echo "  [plan] 全ゲストの退避完了まで待機 (最大 ${WAIT}s)"; exit 0; fi

echo "  全ゲストの退避を待機中..."
deadline=$((SECONDS + WAIT))
while :; do
    r=$(( $(qm list 2>/dev/null | awk 'NR>1 && $3=="running"' | wc -l) \
        + $(pct list 2>/dev/null | awk 'NR>1 && $2=="running"' | wc -l) ))
    [ "$r" -eq 0 ] && break
    if [ "$SECONDS" -ge "$deadline" ]; then echo "  タイムアウト: まだ ${r} 台が稼働中" >&2; exit 1; fi
    sleep 5
done
echo "  全ゲストの退避完了"
REMOTE
}

do_drain() {
    local host="$1" nodename; nodename="$(node_name "$host")"
    log "===== ノード ${nodename} (${host}) を切り離します ====="
    log "クラスタの quorum を確認します"
    cluster_quorate "$host" || { err "クラスタが quorate ではありません。中断します。"; return 1; }

    if [[ $ASSUME_YES -ne 1 && $DRY_RUN -ne 1 ]]; then
        local extra=""; [[ $SHUTDOWN -eq 1 ]] && extra="・電源断"
        read -r -p "ノード ${nodename} を切り離します (ゲスト退避${extra})。続行? [y/N] " reply
        case "$reply" in [yY][eE][sS]|[yY]) ;; *) warn "中止しました。"; return 0 ;; esac
    fi

    remote_drain "$host" "$([[ $DRY_RUN -eq 1 ]] && echo 1)"

    if [[ $SHUTDOWN -eq 1 ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            log "[plan] ノード ${nodename} を電源断"
        else
            log "ノード ${nodename} を電源断します"
            rssh "$host" 'systemctl poweroff' || true
            wait_for "ノード ${nodename} の停止" node_unreachable "$host"
            log "ノード ${nodename} は停止しました。物理メンテを実施してください。"
        fi
    fi
    log "===== 切り離し完了 ====="
}

do_online() {
    local host="$1"
    if [[ $DRY_RUN -eq 1 ]]; then
        log "[plan] ノードのオンライン復帰待ち → HA メンテナンスモード解除"
        return 0
    fi
    log "ノード (${host}) のオンライン復帰と quorum 回復を待ちます (最大 ${WAIT_TIMEOUT}s)"
    wait_for "ノード ${host} の復帰" cluster_quorate "$host"
    local nodename; nodename="$(node_name "$host")"
    log "HA メンテナンスモードを解除します"
    rssh "$host" "ha-manager crm-command node-maintenance disable ${nodename}" || \
        warn "解除に失敗。手動で確認してください: ha-manager crm-command node-maintenance disable ${nodename}"
    log "===== ノード ${nodename} を復帰しました (手動移行分は戻りません) ====="
}

[[ $DRY_RUN -eq 1 ]] && warn "dry-run モードです。実際の操作は行いません。"

case "$SUBCMD" in
    drain)  do_drain  "$HOST" ;;
    online) do_online "$HOST" ;;
esac
