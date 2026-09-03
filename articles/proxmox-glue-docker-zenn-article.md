---
title: "オフラインProxmox環境にAWS Glueのローカル開発コンテナを構築する"
emoji: "🐳"
type: "tech"
topics: ["docker", "aws", "proxmox", "lxc", "glue"]
published: false
---

## はじめに

AWSのGlue/PySparkを使ったETLのハンズオンを、課金を最小限に抑えつつ「実務に近い環境」で試したいと考えました。目指したゴールはシンプルです。

- ローカル（Proxmox上のLXC）で `amazon/aws-glue-libs:5`（Spark 3.5.4 + Iceberg/Hudi/Delta同梱）を動かす
- AWS側はS3のみを使い、計算はすべてローカルで完結させる
- ただし、**Proxmoxホスト自体がインターネットに接続されていない**という制約がある

構成自体は「ネットに繋がったWindows PCでイメージを落とし、オフラインのProxmoxへ転送する」というシンプルなものですが、実際にやってみるとネットワーク・SSH・コンテナのセキュリティ機構など、複数レイヤーにまたがる原因切り分けが必要になりました。本記事では、各所で発生した事象に対して**何を根拠に仮説を立て、どう検証し、どう解決したか**を、実際のログ・スクリーンショットとともに記録します。同じ構成を組む方の切り分けの参考になれば幸いです。

## 全体構成

```
[ ネット接続ありのWindows PC ]         [ オフラインのProxmoxホスト ]
 docker pull / docker save    --scp-->  pct push / LXC (docker load)
```

Windows側でDockerイメージをpullし、`docker save`でtarファイル化、`scp`でProxmox側に転送、LXC内で`docker load`する、という流れです。

Windows側の`docker pull amazon/aws-glue-libs:5`は完走。

![docker pull成功](/images/07_docker_pull_success.png)
*`Status: Downloaded newer image for amazon/aws-glue-libs:5`*

`docker images`でも、CONTENT SIZE 5.13GBのイメージが確認できます。

![docker imagesでイメージを確認](/images/08_docker_images_list.png)

`docker save`でtar化し、Proxmoxホストへ`scp`転送。

![docker save & scpでProxmoxホストへ転送](/images/09_docker_save_scp_host.png)
*4897MB を 96.6MB/s で転送*

ここから、Proxmox側でLXCを構築し、イメージを流し込んでいく作業に入ります。

---

## LXCコンテナの作成とネットワーク構成

まず、Ubuntu 26.04のテンプレートを使ってLXCコンテナ（CT200）を作成しました。ProxmoxのWeb UIの操作ログでも作成成功が確認できます。

![Web UIでCT200作成成功](/images/12_proxmox_webui_ct_created.png)

## DHCPが存在しない環境でのIP割り当て

コンテナ起動後、`ip a`で確認するとIPv4アドレスが振られておらず、`ping`も`Network is unreachable`で失敗しました。

![DHCP未割当でネットワーク到達不能](/images/13_no_ipv4_dhcp_fail.png)
*`inet6 fe80::...`のみで、IPv4アドレスがない*

コンテナ作成時に`ip=dhcp`を指定していたため、まず環境にDHCPサーバーが存在するかどうかを疑いました。今回の検証環境ではDHCPを用意していなかったため、DHCPに頼らず**ブリッジ（vmbr0）と同じセグメントの固定IPを明示的に割り当てる**方針に切り替えます。

```bash
pct stop 200
pct set 200 --net0 name=eth0,bridge=vmbr0,ip=x.x.x.200/24,gw=x.x.x.151(ProxmoxホストIP)
pct start 200
```

意図した通りIPが付与されたことを確認できました。

![固定IPの割り当てに成功](/images/14_static_ip_assigned.png)
*`eth0`に`x.x.x.x.200/24`が付与された*

---

## SSHホスト鍵アルゴリズムの不一致

Windows PCから直接LXCへ`scp`を試すと、鍵交換の時点で接続が拒否されました。

![no matching host key typeエラー](/images/15_scp_hostkey_error.png)
*`Their offer: ssh-rsa,ssh-dss` に対し、Windows側のOpenSSHクライアントが標準では受け付けない*

エラーメッセージに提示されているアルゴリズム（`ssh-rsa`, `ssh-dss`）と、クライアント側のデフォルト許可リストが噛み合っていないことが読み取れたため、`scp`のオプションで明示的に許可アルゴリズムを追加して接続を確立しました。

```powershell
scp -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa ...
```

## SSHパスワード認証を段階的に切り分ける

ホスト鍵の問題を解消した後も`Permission denied`が続いたため、ここでは複数の仮説を一つずつ検証していきました。

**仮説1：`sshd_config`のroot許可設定**

設定ファイルを確認すると、コメントアウトされているように見えて実は**Ubuntu 24.04以降のデフォルト値として有効になっている**設定を発見しました。

![PermitRootLogin prohibit-passwordを発見](/images/16_sshd_config_permitrootlogin.png)
*`#PermitRootLogin prohibit-password`（デフォルトは`prohibit-password`＝パスワードでのroot SSHログイン拒否）*

`PermitRootLogin yes`に修正し再起動しましたが、症状は変わりませんでした。この時点で「他にも要因がある」と判断し、次の仮説に進みます。

**仮説2：PAM設定・アカウントロック**

`/etc/pam.d/sshd`や`passwd -S root`を確認しましたが、いずれも問題のある設定は見当たりませんでした。ここまでで表面的な設定はすべて確認済みだったため、**実際に何が起きているかをsshd自身のログから直接確認する**方針に切り替えます。

**仮説3：sshd自体の初期化失敗**

`sshd -d`で詳細ログ付きにフォアグラウンド起動したところ、根本原因を特定できました。

![Missing privilege separation directory](/images/17_missing_privsep_dir.png)
*`Missing privilege separation directory: /run/sshd`*

LXC環境では`/run`がtmpfsとして扱われるため、SSHの特権分離に必要なディレクトリが起動時に存在しない状態になっていました。ディレクトリを作成して再起動すると、サービスは正常化しました。

```bash
mkdir -p /run/sshd
chmod 755 /run/sshd
systemctl restart ssh
```

![/run/sshd作成でSSH正常化](/images/18_run_sshd_fixed.png)
*`active (running)`かつポート22でリッスン*

LXC自身から`ssh root@localhost`でログインできることを確認し、この課題は解決としました。

> **ポイント**：設定ファイル（`sshd_config`）を追うだけでは見つからない問題は、デーモン自身をデバッグモードで動かしてログを直接見るのが最も確実でした。

## ホスト鍵変更に伴う警告への対処

コンテナを作り直した影響で、Windows側の`known_hosts`に記録済みのホスト鍵と実際の鍵が一致しなくなり、警告が出ました。

![ホストキー変更の警告](/images/19_hostkey_changed_warning.png)
*`WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`*

これは中間者攻撃の可能性を知らせる警告ですが、今回はコンテナの再作成が原因であることが明確だったため、該当ホストの古い記録だけを削除して対応しました。

```powershell
ssh-keygen -R x.x.x.200
```

再接続後、本命のtarファイル転送に成功しました。

![tarファイルの転送に成功](/images/20_scp_success_tar_transfer.png)
*4897MBを100.6MB/sで転送完了*

---

## ネットワーク到達範囲の見極め

ここで、ICMPリダイレクトのメッセージから「別経路でインターネットに出られる可能性」に気づき、ゲートウェイを`x.x.x.1`（Windows PC）に向けて疎通確認を行いました。

![ゲートウェイ変更後、Windows PCへの疎通は成功](/images/21_gateway_change_ping_success.png)

Windows PCへの到達は確認できたものの、外部（`8.8.8.8`）への疎通は失敗という結果でした。

![8.8.8.8への疎通は100%失敗](/images/22_internet_unreachable.png)

この検証によって「LXCは完全にオフラインである」という前提を確定させることができ、以降はオフライン専用の手順に絞って作業を進めることにしました。

## オフライン環境でのDockerインストール

LXC内にはDockerが入っておらず、`apt`も使えないため、Windows側でDocker公式の静的バイナリを取得し、`scp`で転送、手動でsystemdサービス化する方針を取りました。

```bash
tar xzvf docker-29.7.2.tgz
cp docker/* /usr/bin/

cat > /etc/systemd/system/docker.service << 'EOF'
[Unit]
Description=Docker Application Container Engine
After=network.target

[Service]
ExecStart=/usr/bin/dockerd
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now docker
```

![Dockerバイナリの手動配置とサービス化](/images/23_docker_manual_install.png)

`systemctl status docker`で`active (running)`を確認しました。

![dockerサービスがactiveに](/images/24_docker_service_active.png)
*nftables周りの警告は出るが、LXC環境では想定内で機能に影響しない*

## 転送済みファイルの再現性を確保する

`docker load`を実行したところ、直前に転送したはずのtarファイルが見当たりませんでした。

![docker loadでファイルが見つからないエラー](/images/25_docker_load_file_not_found.png)

作業ログを振り返ると、途中でIP設定変更のため`pct stop`→`pct start`を挟んでおり、その際に`/tmp`の中身がクリアされていたことが原因と特定できました。これは`/tmp`がコンテナ再起動でリセットされる、というLinuxの一般的な仕様通りの挙動です。Windows側から再度scpで転送し直すことで、`docker load`は問題なく成功しました。

![docker load成功](/images/26_docker_load_success.png)
*`Loaded image: amazon/aws-glue-libs:5`、`docker images`にも表示*

> **ポイント**：以降は作業用ファイルの置き場所を`/tmp`ではなく永続化されるパス（例：`/root/work`）に変更し、同種の再現待ちを防ぐようにしました。

## ネストされたコンテナでのAppArmor制約

最後に、`docker run`でSparkコンテナを起動しようとしたところ、AppArmor関連のエラーに直面しました。

![AppArmorプロファイルのロードエラー](/images/27_apparmor_error.png)
*`AppArmor enabled on system but the docker-default profile could not be loaded`*

これは、LXC（ネストされたコンテナ）環境の特性上、内側のDockerがAppArmorプロファイルを管理する権限を持てないために起きる、既知の制約です。今回は検証目的のローカル環境であることを踏まえ、`--security-opt apparmor=unconfined`を指定してAppArmorの適用をスキップする方針を取りました。

```bash
docker run -it --rm --security-opt apparmor=unconfined amazon/aws-glue-libs:5 pyspark --version
```

Spark 3.5.4-amzn-0が無事起動しました。

![pysparkの起動に成功](/images/28_pyspark_success.png)
*Spark 3.5.4-amzn-0、Scala 2.12.18、OpenJDK 17.0.20*

これで、Proxmox上のオフラインLXC環境にAWS Glueのローカル開発コンテナを構築するという当初の目標を達成できました。

---

## 発生した課題と解決策の一覧

| # | 事象 | 切り分けの根拠 | 対処 |
|---|------|----------------|------|
| 1 | LXCにIPが振られない | DHCP環境の有無を確認 | 固定IPを`pct set`で明示的に指定 |
| 2 | `no matching host key type` | エラーが提示するアルゴリズムとクライアント設定を比較 | `-oHostKeyAlgorithms=+ssh-rsa`等を指定 |
| 3 | scp/sshで`Permission denied` | 設定ファイル→PAM→sshdログの順に仮説を検証 | `mkdir -p /run/sshd`で特権分離ディレクトリを補完 |
| 4 | ホストキー変更警告 | コンテナ再作成という直近の変更と紐付け | `ssh-keygen -R <IP>`で該当記録のみ削除 |
| 5 | 外部への疎通不可 | ICMPリダイレクトを手がかりに経路を実地検証 | オフライン前提に方針転換 |
| 6 | Dockerが入っていない | オフラインという前提条件から逆算 | 静的バイナリを転送し手動でsystemd化 |
| 7 | tarファイルが消えている | 直前の操作履歴（`pct stop/start`）から原因を推定 | 永続パスの利用、再転送で解決 |
| 8 | AppArmorエラー | LXCのネスト構造という環境特性から原因を特定 | `--security-opt apparmor=unconfined`で回避 |

## おわりに

今回は「オフライン環境」「LXCというネストされたコンテナ環境」という2つの制約条件のもとで、ネットワーク・SSH認証・コンテナのセキュリティ機構など、レイヤーの異なる複数の課題に直面しました。いずれも、エラーメッセージや直近の操作履歴を手がかりに仮説を立て、ログや設定ファイルを直接確認しながら一つずつ切り分けていくことで解決できています。

こうした環境依存の制約は、次回同じ構成を組む際の指針として役立つはずです。次は、このLXC環境からS3と連携させたPySparkのETLハンズオン（マスキング処理＋Icebergでの書き出し）に進む予定です。
