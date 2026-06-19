# pveutils

Proxmox VE の運用ユーティリティ集。

## scripts

| script | 実行場所 | 用途 |
|---|---|---|
| `scripts/rolling-update-pve.sh` | 運用端末 | クラスタを 1 ノードずつローリング更新 |

### rolling-update-pve.sh

運用端末から SSH 経由で、クラスタを 1 ノードずつ順番に更新する。ノードを 1 つだけ
渡せば単体ノードの更新にも使える。ノードごとに
quorum 確認 → HA メンテナンスモードで退避 → 更新 → 再起動と復帰待ち → 退避解除
を実施し、1 ノードでも失敗したら以降は中断する。

```sh
# 順序を明示してドライラン (まず確認)
./scripts/rolling-update-pve.sh -n pve1 pve2 pve3

# 順に実行 (ノードごとに y/N 確認)
./scripts/rolling-update-pve.sh pve1 pve2 pve3

# 構成を自動検出して無人実行、必要時のみ再起動
./scripts/rolling-update-pve.sh -y --entry pve1
```

| オプション | 既定 | 説明 |
|---|---|---|
| `host...` | — | 対象ノードの SSH ホストをこの順で処理する |
| `-e, --entry HOST` | — | host 引数省略時、起点ノードから `pvecm` で構成を自動検出する |
| `-u, --user USER` | `root` | SSH ユーザ |
| `--ssh CMD` | `ssh ...` | ssh コマンドを上書きする (環境変数 `SSH_COMMAND` でも可)。既定の接続オプションは無効化される |
| `--reboot MODE` | `required` | `required` (reboot-required 時のみ) / `always` / `never` |
| `--drain MODE` | `maintenance` | `maintenance` (HA メンテナンスモードで退避) / `none` |
| `-w, --wait SECONDS` | `900` | ノード復帰待ちのタイムアウト秒 |
| `-y, --yes` | — | ノードごとの確認を省略する |
| `-v, --verbose` | — | apt の出力もコンソールに流す (既定は進捗のみ。出力は常に `./logs/` に保存) |
| `-n, --dry-run` | — | 実行内容を表示するだけで更新・再起動しない |
| `-h, --help` | — | ヘルプを表示する |

#### 前提

- 運用端末から各ノードへ鍵認証で SSH できること (`BatchMode=yes` で実行)。
- 退避 (`--drain maintenance`) を活かすには HA が構成済みであること。HA 未構成の場合は
  退避されず、再起動時に当該ノードのゲストが停止する (その場合は `--drain none` を指定)。
