---
title: "自宅VMware(ESXi/vCenter)環境をProxmox VEに移行した話 - HPE MicroServer Gen10 Plusへのインストール手順"
emoji: "🖥️"
type: "tech"
topics: ["proxmox", "vmware", "esxi", "自宅サーバー", "仮想化"]
published: false
---

## はじめに

自宅でESXi・vCenter・vSphereを使って仮想化環境を構築していましたが、ブロードコムによる買収後、サブスクリプション化とライセンス体系の変更によって「個人の自宅ラボ」には非常に使いづらい製品になってしまいました。

そこで本記事では、自宅の検証機である **HPE ProLiant MicroServer Gen10 Plus** に、無料で使えるオープンソースの仮想化基盤 **Proxmox VE** を新規インストールするまでの手順を、実際にハマったポイントも含めてまとめます。

:::message
記事中のスクリーンショットは、IPアドレス・MACアドレス・シリアル番号・メールアドレスなど個人を特定しうる情報を黒塗りでマスクしています。
:::

## 移行前の環境

移行前は以下の2台でESXiを個別運用していました(vCenterには未接続の状態)。

- HPE ProLiant MicroServer Gen10 Plus (ESXi 7.0 Update 3)
- MinisForum HM90 (ESXi 8.0 Update 3)

![移行前のMicroServer側ESXiホスト画面](./images/01_before_esxi_microserver.png)
*MicroServer側のESXiホストクライアント画面*

![移行前のMinisForum側ESXiホスト画面](./images/02_before_esxi_minisforum.png)
*MinisForum側のESXiホストクライアント画面*

いずれも無償版ライセンス時代から使い続けていたものですが、Broadcomによる買収後の方針転換により、この環境を維持するモチベーションがなくなり、Proxmox VEへの移行を決意しました。

## 全体の構成方針

検討の結果、以下の構成に落ち着きました。

| 機器 | 役割 |
|---|---|
| MinisForum Elite | Windows作業・開発機(仮想化基盤には含めない) |
| HPE MicroServer Gen10 Plus | Proxmox VE本番機(検証用Kubernetes/Docker、Terraform/Ansible検証など) |

MicroServer Gen10 Plusは筐体が小さく、PCIeスロットや電源容量に制約があるため、GPUを積んだ本格的な用途(AIサーバー等)は諦め、**単体ノードでのProxmox VE運用**とすることにしました。クラスタは組まず、シンプルに1台構成としています。

## インストールISOのダウンロード

Proxmoxの[公式ダウンロードページ](https://www.proxmox.com/en/downloads)から、Proxmox VEのISOイメージを取得します。

![Proxmoxダウンロードページ](./images/03_download_top.png)
*Proxmox公式ダウンロードページ*

ページ下部の一覧から対象のバージョンを選びます。ここで注意が必要なのは、**ARM64版とx86_64版が並んで表示される**点です。HPE MicroServerのようなIntel/AMD系サーバーには、x86_64版(通常上から2番目に表示される、ファイルサイズが少し大きい方)を選ぶ必要があります。

![Proxmoxダウンロード一覧、ARM64版とx86_64版が並んでいる](./images/04_download_list.png)
*ARM64版と間違えないよう注意*

ダウンロードしたISOは、Windows PCから**Rufus**を使ってUSBメモリに書き込みました(手順は割愛します)。ただし今回は結局、後述のiLO仮想メディア機能を使ったため、USBメモリは使わずに済みました。

## iLO5経由でのリモートインストール

HPE ProLiantシリーズには**iLO(Integrated Lights-Out)**というリモート管理機能が搭載されています。今回は物理USBメモリを本体に挿しに行く代わりに、iLOの「仮想メディア」機能でISOをリモートマウントし、インストールを進めました。

iLOのWeb管理画面にアクセスすると、いくつかメニューがあります。最初、目的のページと違う「iLO Federation」ページを開いてしまいました。

![iLO Federation設定画面(目的のページではない)](./images/05_ilo_federation_wrong_page.png)
*これは複数のiLOをグループ管理するための画面。今回の作業には不要*

目的の操作は左メニューの **「Remote Console & Media」** から行います。ここでHTML5コンソール(ブラウザだけで完結するリモートコンソール)を起動し、ダウンロード済みのISOファイルを仮想CD/DVDとしてマウントしました。

その後、サーバーを起動して**F9キー**でBoot Menuを呼び出し、UEFIのシステムユーティリティ画面からハードウェア情報を確認できました。

![iLO経由のシステムユーティリティ画面、MicroServer Gen10 Plusの情報が表示されている](./images/06_ilo_system_utilities.png)
*UEFIのシステムユーティリティ(RBSU)画面。日本語表示にも対応している*

ここから「ワンタイムブートメニュー」→マウント済みのVirtual CD/DVDを選択して起動すると、Proxmox VEのインストーラが立ち上がります。

## Proxmox VEインストーラでのセットアップ

### インストーラの起動

![Proxmox VEインストーラのウェルカム画面](./images/07_installer_welcome.png)
*「Install Proxmox VE (Graphical)」を選択してEnter*

### ディスク構成の確認 - 実は2枚搭載されていた

インストーラが自動検出したディスクを確認したところ、当初は1枚(465.76GiB, Samsung SSD 860)しか表示されていませんでした。

![インストーラのディスク選択画面(1枚のみ表示)](./images/08_disk_select_1disk.png)
*最初は/dev/sdaのみが表示されていた*

ファイルシステムのデフォルトはext4でした。

![Harddisk optionsダイアログ、デフォルトのext4設定](./images/09_diskoptions_ext4.png)
*デフォルトはext4、ディスク全容量が自動的に割り当てられる*

念のため「Target Harddisk」のドロップダウンを開いてみると、**搭載していたもう1台の同容量SSD(/dev/sdb)が見えました**。

![Target Harddiskドロップダウンに2枚目のディスクが表示された](./images/10_disk_dropdown_2disks.png)
*465.76GiBのSamsung SSD 860が2枚とも見えている状態*

2枚同容量のディスクが揃っているため、**ZFSミラー(RAID1)**を構成することにしました。

![誤ってRAIDZ-1を選択してしまった状態](./images/11_zfs_raidz1_wrong.png)
*RAIDZ-1は3台以上のディスクが必要なので2台構成では不適切*

正しくは**RAID1(ミラーリング)**を選択します。

![正しくZFS RAID1を選択した状態](./images/12_zfs_raid1_correct.png)
*ZFS RAID1(ミラー)。片方のディスクが故障してもデータを保護できる*

### タイムゾーン・キーボード設定

Countryに「Japan」を指定すると、Time Zoneも自動的に「Asia/Tokyo」に切り替わりました。

![Location and Time Zone selection画面](./images/13_timezone.png)
*Country: Japan, Timezone: Asia/Tokyo*

### rootパスワードとメールアドレス

Proxmox Web UIへのログインに使うrootパスワードと、バックアップ失敗などの通知先メールアドレスを設定します。

![Administration Password and Email Address画面](./images/14_password_email.png)
*このパスワードは後でWeb UI(https://IP:8006)へのログインに使う*

### ネットワーク設定 - 何度もつまずいたポイント

今回、一番手間取ったのがこのネットワーク設定でした。

まず、iLOへのリモート接続にノートPCのモバイルホットスポット機能(インターネット接続の共有)を使っていたため、iLO自体は`192.168.137.x`というプライベートなセグメントに繋がっていました。一方でProxmox本体(nic0)を将来的に自宅Wi-Fiのセグメントに参加させる予定だったため、最初はそちらに合わせた値(仮のホスト名・IPアドレス)を入力していました。

![Management Network Configuration画面(仮の値を入力した状態)](./images/15_network_config_placeholder.png)
*一旦、自宅LANのセグメントに合わせた仮設定を入力*

自宅LANのセグメントを確認するために、ノートPCの`ipconfig /all`の結果を確認しました。

![ipconfig /allの実行結果、Wi-Fiアダプタの情報](./images/16_ipconfig_wifi.png)
*ノートPCのWi-Fiアダプタが使っているセグメントを確認*

これを元に、最終的なIPアドレス・ゲートウェイ・DNSサーバーを入力しました。

![Management Network Configuration画面(実際の値を入力)](./images/17_network_config_filled.png)
*ホスト名、IPアドレス、ゲートウェイ、DNSサーバーを入力*

### 最終確認画面(Summary)

これまでの設定内容がすべて一覧表示されるので、最終確認します。

![Summary画面、これまでの全設定が一覧表示される](./images/18_summary.png)
*Filesystem: zfs (RAID1)、Disk(s): /dev/sda \| /dev/sdb など、想定通りの内容になっているか確認*

問題なければ「Install」ボタンでインストールを開始します。数分でインストールが完了し、自動的に再起動されました。

## インストール完了、そしてネットワークで再びハマる

再起動後のコンソールには、Web UIへのアクセスURLが表示されました。

![インストール完了後のコンソール、Web UIへのアクセスURLが表示されている](./images/19_console_boot_complete.png)
*`https://(設定したIPアドレス):8006/` にアクセスすればよいのだが...*

ここで問題が発生しました。**MicroServerのnic0ポート(本体用の物理LANポート)は、まだ自宅Wi-Fiルーターに接続されていない**状態だったのです。iLOポートはノートPCの共有回線に繋がっていましたが、nic0は別ポートであり、当初設定したIPアドレス(自宅LANのセグメント)ではまだ到達できませんでした。

無線LAN中継器(TP-Linkのイーサネットコンバーター機能付き製品など)を購入して物理的に有線化する方針も検討しましたが、届くまでの間、**「iLOが使っているノートPCの共有回線(`192.168.137.x`)に、nic0も一時的に接続してしまう」**という方法で応急的に疎通を確保することにしました。

コンソールから直接rootでログインし、ネットワーク設定ファイルを書き換えます。

![コンソールでrootログインした状態](./images/20_console_login.png)
*`pve login:` プロンプトでrootログイン*

`/etc/network/interfaces` を編集し、`address`と`gateway`の値を、ノートPC共有回線のセグメントに書き換えます。

![nanoエディタで/etc/network/interfacesを編集している状態](./images/21_nano_interfaces.png)
*address/gatewayの行をノートPC共有回線のセグメントに変更*

保存後、`systemctl restart networking` でネットワークサービスを再起動すると、無事にリンクアップしました。

![systemctl restart networkingの実行結果、nic0がリンクアップしたログ](./images/22_console_networking_restart.png)
*`igb: nic0 NIC Link is Up 1000 Mbps Full Duplex` のログが確認できる*

## Web UIへのアクセス成功

ノートPCのブラウザから、変更後のIPアドレスで`https://(IPアドレス):8006`にアクセスすると、無事にProxmox VEのWeb管理画面が表示されました。

![Proxmox VE Web管理画面、Datacenter画面が表示されている](./images/23_webui_dashboard.png)
*Proxmox VE 9.2.2のDatacenter画面。ノード`pve`が正常稼働中、ZFSストレージ(local-zfs)も認識されている*

ストレージ一覧には `local` と `local-zfs` の2つが表示されており、ディスク2枚によるZFS RAID1構成が正しく認識されていることも確認できました。

## まとめ・今後の課題

今回はインストール自体よりも、**ネットワーク周りの試行錯誤**に一番時間がかかりました。振り返ると以下の点が学びになりました。

- iLOのIPセグメントと、Proxmox本体(nic0)が使うIPセグメントは別物であり、混同しやすい
- ノートPCのモバイルホットスポット(ICS)は、複数の有線ポートに同じセグメントを配ることができるため、一時的な疎通確保に応用できる
- ディスク構成は「見えている情報を鵜呑みにせず、ドロップダウンなどで他の選択肢がないか確認する」ことが大事(今回は1枚だと思っていたディスクが実は2枚あった)

今後は以下を進めていく予定です。

- 無線LAN中継器(イーサネットコンバーター)を使った本恒久的なネットワーク接続への切り替え
- `no-subscription`リポジトリへの切り替えと`apt update`
- Terraform(bpg/proxmoxプロバイダー)+ Ansibleによる、VM作成〜k3s/Docker環境構築の自動化

続編として、Terraform/Ansibleによる自動プロビジョニングの記事も書く予定です。
