# pveutils

Proxmox VE の運用ユーティリティ集。

## scripts

| script | 実行場所 | 用途 |
|---|---|---|
| `scripts/rolling-update-pve.sh` | 運用端末 | クラスタを 1 ノードずつローリング更新 |
| `scripts/pve-maintenance.sh` | 運用端末 | 物理メンテのためノードを切り離す / 復帰させる |

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

### pve-maintenance.sh

物理メンテのため、運用端末から SSH 経由で 1 ノードをクラスタから切り離し、作業後に
復帰させる。`drain` / `online` のサブコマンドで操作する。

```sh
# 切り離し前に予定を確認 (dry-run)
./scripts/pve-maintenance.sh drain -n pve02

# ゲストを退避して切り離す
./scripts/pve-maintenance.sh drain pve02

# 退避後にそのまま電源断する
./scripts/pve-maintenance.sh drain --shutdown pve02

# 物理メンテ後に復帰させる (ノード起動後に実行)
./scripts/pve-maintenance.sh online pve02
```

`drain` は HA メンテナンスモードで HA ゲストを退避させ、非 HA の稼働ゲストを他の
オンラインノードへ自動で振り分けて移行する (VM は online、CT は restart 移行)。
`online` は HA メンテナンスモードを解除する。drain で手動移行したゲストは自動では
戻らない (メンテ後の再配置は別途行う)。

| オプション | 既定 | 説明 |
|---|---|---|
| `drain` / `online` | — | 切り離し / 復帰のサブコマンド |
| `<host>` | — | 対象ノードの SSH ホスト |
| `-u, --user USER` | `root` | SSH ユーザ |
| `--ssh CMD` | `ssh ...` | ssh コマンドを上書きする (環境変数 `SSH_COMMAND` でも可) |
| `-w, --wait SEC` | `600` | 退避/復帰待ちのタイムアウト秒 |
| `--shutdown` | — | drain 後にノードを電源断する |
| `-y, --yes` | — | 確認プロンプトを省略する |
| `-n, --dry-run` | — | 実行せず予定を表示する |
