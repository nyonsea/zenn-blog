---
title: "Proxmox VE (Proliant Gen10)に Proxmox Datacenter Manager を導入してみた"
emoji: "🗄️"
type: "tech"
topics: ["proxmox", "homelab", "自宅サーバー", "仮想化"]
published: false
---

## はじめに

HPE ProLiant Gen10 に構築した Proxmox VE 上に、複数の Proxmox 環境を一元管理できる **Proxmox Datacenter Manager（以下 PDM）** を導入しました。本記事では、VM作成からインストール、PVEノードの登録までの手順を実際のキャプチャ付きでまとめます。

## Proxmox Datacenter Manager とは

PDM は、複数の独立した（スタンドアロンの）Proxmox VE 環境をひとつのダッシュボードで横断的に監視・管理できるツールです。VMwareでいう vCenter に近い位置づけで、PVEクラスターのようにバージョン統一や常時接続によるクォーラム維持を必要としないため、**「1台構築 → 後日もう1台追加」という段階的な拡張と相性が良い構成**です。

![Proxmox公式サイトのDatacenter Manager紹介ページ](/images/01-pdm-official-site.png)
*Proxmox公式サイトのPDM紹介ページ*

必要スペックは非常に軽量です。

- CPU: 2コア
- メモリ: 2GiB
- ディスク: 32GB程度

## 環境

- ホスト: HPE ProLiant Gen10（Proxmox VE 構築済み）
- 導入対象: Proxmox Datacenter Manager（PVE上のVMとしてインストール）

## 導入手順

### 1. ISOをダウンロードしてPVEにアップロード

Proxmox公式サイトのダウンロードページから PDM の ISO イメージを取得し、PVEの「ISOイメージ」ストレージ（local など）にアップロードします。

### 2. PDM用のVMを作成

PVE上で「VMを作成」から、ウィザードの各タブを順に設定していきます。

**全般タブ**：VM ID・名前を入力します。今回はVM ID `100`、名前 `pdm` としました。

![VM作成ウィザードの全般タブ](/images/02-vm-create-general.png)
*ノードは `pve`、VM ID `100`、名前 `pdm`*

**OSタブ**：「CD/DVDイメージファイル(iso)を使用」を選択し、事前にアップロードしたPDMのISOを指定します。ゲストOSの種別は `Linux`、バージョンは `7.x - 2.6 Kernel` のままでOKです。

![VM作成ウィザードのOSタブ](/images/02b-vm-create-os.png)
*ISOイメージに `proxmox-datacenter-ma...`（PDMのISO）を指定*

**システムタブ**：グラフィックカード・マシン・BIOS・SCSIコントローラーはすべてデフォルト（既定）のままで問題ありません。

![VM作成ウィザードのシステムタブ](/images/02c-vm-create-system.png)
*BIOSは既定のSeaBIOS、SCSIコントローラーはVirtIO SCSI single*

**ディスクタブ**：ディスクサイズを32〜40GiB程度に設定します。今回はストレージ `local-zfs`、サイズ `40GiB` としました。

![VM作成ウィザードのディスクタブ](/images/02d-vm-create-disk.png)
*ストレージ `local-zfs`、ディスクサイズ `40GiB`*

**CPUタブ**：コア数を `2` に設定します。

![VM作成ウィザードのCPUタブ](/images/02e-vm-create-cpu.png)
*ソケット1、コア2（合計コア数2）*

**メモリタブ**：メモリを `2048MiB`（2GB）に設定します。

![VM作成ウィザードのメモリタブ](/images/03-vm-create-memory.png)
*メモリは2048MiB（2GB）を割り当て*

**ネットワークタブ**：デフォルトの `vmbr0` ブリッジのままで進めます。

![VM作成ウィザードのネットワークタブ](/images/02f-vm-create-network.png)
*ブリッジは `vmbr0`、モデルはVirtIO（準仮想化）*

**確認タブ**：これまでの設定内容が一覧で表示されるので、間違いがないか確認して「完了」をクリックします。

![VM作成ウィザードの確認タブ](/images/02g-vm-create-confirm.png)
*cores: 2、memory: 2048、scsi0: local-zfs:40 など設定内容の最終確認*

設定内容をまとめると以下のとおりです。

| 項目 | 設定値 |
|---|---|
| 名前 | pdm など |
| OS | アップロードしたPDMのISO |
| ディスク | 32〜40GiB程度 |
| CPU | 2コア |
| メモリ | 2048MiB |
| ネットワーク | デフォルト（vmbr0） |

「完了」を押すとVMが作成されます。

![作成直後のVM 100 (pdm) サマリー画面](/images/04-vm-created-summary.png)
*作成直後のVM「100 (pdm)」*

### 3. グラフィカルインストーラーでセットアップ

VMを起動してコンソールを開き、「Graphical Installer」でインストールを進めます。

![EULA（使用許諾契約）画面](/images/05-installer-eula.png)
*EULAを確認し「I agree」で次へ*

ライセンス同意、インストール先ディスクの確認、タイムゾーン（Japan）、rootパスワードなどを設定した後、**Management Network** の項目でホスト名・固定IP・ゲートウェイ・DNSを入力します。

![Management Network Configuration画面](/images/06-installer-management-network.png)
*ホスト名、IPアドレス（CIDR）、ゲートウェイ、DNSサーバーを設定する*

設定内容を確認し、インストールを実行します。数分で完了します。

![Installation successful画面](/images/07-installer-success.png)
*インストール完了。表示されたURL（`https://<IPアドレス>:8443`）にブラウザでアクセスする*

### 4. 管理画面にログイン

再起動後、コンソールにアクセス用URLが表示されます。

![コンソールに表示されるログインURL](/images/08-console-login-url.png)
*`pdm login:` プロンプトの上に管理画面のURLが表示される*

このURL（`https://<IPアドレス>:8443/`）にブラウザでアクセスし、`root` と設定したパスワードでログインします。PVE本体の管理画面（ポート `8006`）とはポート番号が異なる点に注意してください。

### 5. PVEノードのフィンガープリントを取得

PDMからPVEを登録するには、PVE側のSSL証明書のフィンガープリントが必要です。以下の手順で取得します。

1. PVEの管理画面で、左メニューの対象ノード（例: `pve`）をクリック
2. 「システム」→「証明書」を開く
3. 一覧の `pve-ssl.pem` をダブルクリック（または選択して「証明書を表示」）
4. ポップアップ内の **SHA256 フィンガープリント** をコピー

![PVEの「システム」→「証明書」画面](/images/09-pve-certificates-menu.png)
*「システム」→「証明書」から `pve-ssl.pem` をダブルクリックする*

![証明書ポップアップに表示されるフィンガープリント](/images/10-pve-fingerprint-popup.png)
*「指紋」の欄に表示されるSHA256フィンガープリントをコピーする*

### 6. PDMにリモート（PVE）を追加

PDMの「リモート」→「追加」→「Proxmox VE」を開きます。

![PDMの「追加」メニュー](/images/11-pdm-add-remote-menu.png)
*「Proxmox VE」を選択してリモート追加を開始*

「remoteを調査」タブで、サーバーアドレスとフィンガープリントを入力します。サーバーアドレスは `<PVEのIPアドレス>:8006` のようにポート番号まで指定します。

![サーバーアドレスと指紋の入力画面](/images/12-pdm-remote-address-fingerprint.png)
*サーバーアドレスとフィンガープリントを入力*

続く「設定」タブで、以下の内容を入力します。

- **リモートID**: 任意の分かりやすい名前（例: `proliant`）
- **ユーザー**: `root`
- **パスワード**: PVEのrootパスワード
- **レルム**: `pam`

:::message
「ユーザー」欄には `root` のみを入力してください。`root@pam` のように入力すると、別欄の「レルム」で選択している `pam` と重複し、認証エラー（`could not login: authentication failed`）になります。
:::

「次へ」で接続テストが通れば「エンドポイント」「サマリー」タブへ進みます。サマリー画面で内容を確認し、「完了」を押します。

![リモート追加の最終確認（サマリー）画面](/images/15-pdm-remote-summary.png)
*Remote ID・Auth ID・接続先の最終確認画面*

## 完成後のダッシュボード

登録が完了すると、PDMのダッシュボードで ProLiant（PVE）のリモート接続状況・稼働ノード数・CPU/メモリ/ストレージ使用率・稼働中の仮想マシンが一画面に集約されて表示されます。

![PDMダッシュボードにProLiantの情報が反映された最終画面](/images/16-pdm-dashboard-final.png)
*「全てのremoteに接続中」「1ノードがオンライン」の表示とともに、CPU・メモリ・ストレージ使用率がリアルタイムに可視化されている*

右上に表示される「有効なサブスクリプションがありません」という警告は、個人利用の無償運用では気にする必要がない標準表示です。

## まとめ

Proxmox Datacenter Manager は非常に軽量なVMとして導入でき、複数のスタンドアロンPVE環境を統合監視するのに手軽な選択肢です。フィンガープリントの取得場所（「システム」→「証明書」）と、リモート登録時のユーザー欄の指定（`root@pam` ではなく `root` のみ）さえ押さえておけば、導入自体は難しくありません。

今後、別のマシンにもProxmox VEを追加導入し、同じPDMから登録することで、段階的にホームラボを拡張していく予定です。
