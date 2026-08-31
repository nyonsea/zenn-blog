---
title: "Dockerコンテナの正体を理解する — ネットワーク・プロセスモデルからAWS/オンプレ運用まで"
emoji: "🐳"
type: "tech"
topics: ["docker", "kubernetes", "aws", "podman", "terraform"]
published: true
---

## はじめに

「コンテナってDockerさえ叩けば動くけど、実際のところ中で何が起きているのか説明できますか？」

この記事は、そう聞かれて言葉に詰まった経験のあるエンジニア向けに書いています。`docker run` が一瞬で終わる理由、コンテナ間通信でIPを直書きしなくていい理由、そしてECS・EKS・Fargateという似た名前のサービス群がなぜ乱立しているのか——。これらは個別には知っていても、**一本の線でつながった理解**になっていないケースが多いのではないでしょうか。

本記事では、以下の順に「コンテナの正体」を掘り下げ、最後は実務でよくある要件（オンプレRHEL上でPodmanコンテナを100台規模でIaC展開する）まで一気に接続します。対象読者は、コンテナをある程度触ったことがあり、次のレベルの理解を求めているエンジニアです。「とりあえず動かしてみた」系の内容は扱いません。

## 1. コンテナがホストを経由して外部と通信する経路

コンテナ内のアプリケーションが外部（インターネット）と通信するとき、何が起きているのかを最初に整理します。

![コンテナが外部と通信する経路](/images/fig01-network-path.png)
*図1: コンテナから外部ネットワークに至る通信経路*

ポイントは、コンテナは最初から「独立した仮想IP」を持つ孤立した存在だという点です。そこから外の世界に出るまでに、以下の変換を経由します。

| ステップ | 役割 |
|---|---|
| veth ペア | コンテナのネットワーク名前空間とホストを繋ぐ、両端がある仮想ケーブル |
| docker0 ブリッジ | 同一ホスト上の複数コンテナが接続される仮想スイッチ |
| iptables NAT（SNAT） | プライベートIP（`172.17.0.x`）をホストの実IPに書き換える |
| ホストNIC | 変換後のパケットを実際に送出する |

ここで最も重要なのは **iptablesによるSNAT（送信元IP変換、いわゆるMASQUERADE）** です。コンテナのプライベートIPはインターネット上では意味を持たないため、外部から見ると「ホストマシン自身が通信している」ように見える形に変換されます。

逆方向（外部からコンテナへの通信）はこの経路が自動では通らないため、`docker run -p 8080:80` のような**ポートマッピング**を明示する必要があります。これはiptablesの**DNAT**ルールとして実装されており、「ホストの特定ポート宛のパケットを、特定コンテナの特定ポートへ転送する」という変換です。

## 2. コンテナ起動は「ミニLinuxの起動」ではない

コンテナに関する最もよくある誤解が、「コンテナを起動するたびに軽量なLinuxカーネルが起動している」というものです。結論から言えば、これは誤りです。

![VMとコンテナの起動方式の違い](/images/fig02-vm-vs-container-boot.png)
*図2: 仮想マシンとコンテナの起動方式の対比*

仮想マシン（VM）は、各インスタンスが独自の**ゲストOSカーネル**をハイパーバイザー上で新規に起動します。これに対しコンテナは、**ホストのLinuxカーネルを共有する、隔離されたプロセス**に過ぎません。`docker run` の実体は、大まかに次の3ステップです。

1. ホストカーネルに対し、プロセスを名前空間（namespace）で隔離するよう要求する
2. cgroupsでCPU・メモリの利用上限を設定する
3. その隔離された箱の中で、イメージに含まれるプログラムを1つのプロセスとして実行する

新しいカーネルは一切起動しません。マンションの各部屋（コンテナ）が、建物全体の電気・水道インフラ（ホストカーネル）を共有しているイメージに近いです。これが、コンテナの起動が数百ミリ秒で終わり、イメージが数MBで済む理由の本質です。VMのように「ゲストOSまるごと」を積む必要がないため、1台のホストに大量のコンテナを詰め込めます。

なお、Linuxコンテナは基本的にLinuxカーネルの機能に依存しているため、**Linuxホスト上でしか直接動きません**。Windows上のDocker Desktopがコンテナを動かせているように見えるのは、裏側でWSL2などの軽量Linux VMをこっそり1つ起動し、その中で「本物のLinuxカーネルを使ったコンテナ」を動かしているためです。

## 3. 同梱ライブラリは「別プロセス」として起動するわけではない

もう一つ誤解されやすいのが、コンテナイメージに含まれるライブラリ群の扱いです。「アプリと一緒にパッケージされたライブラリも、それぞれ起動してカーネルと通信しているのか」という疑問は自然ですが、答えは「NO」です。

![プロセス内のライブラリとシステムコールの関係](/images/fig03-library-syscall.png)
*図3: アプリコードとライブラリは同一プロセスのメモリ空間に存在する*

アプリのコードも、動的リンクされたライブラリ（`libc`、`openssl`など）も、**同じ1つのプロセスのメモリ空間に同居しているだけ**です。カーネルとやり取りする窓口（システムコール）は、プロセス全体でただ1つしかありません。

- **動的リンク（一般的）**：実行時に、動的リンカが共有ライブラリ（`.so`）をプロセスのメモリにマッピングする
- **静的リンク**（Go言語のバイナリなどでよく使われる）：ビルド時点で、ライブラリのコードを実行ファイルに埋め込んでしまう

どちらの方式でも、ライブラリのコードが実行されるのはあくまで同一プロセスのコンテキスト内であり、独立したプロセスとしてカーネルと個別にやり取りすることはありません。

## 4. 「1コンテナ1プロセス」は技術的制約ではなく設計原則

コンテナは独立した**PID名前空間**を持ちます。そのため、最初に起動するプロセス（PID 1、通常はENTRYPOINT）が、その中でさらに子プロセスをforkすること自体は技術的に何の問題もありません。

![コンテナのPID名前空間の中のプロセス構造](/images/fig04-pid-namespace.png)
*図4: コンテナ内のPID名前空間とプロセスツリー*

nginxのマスタープロセスがworkerを複数生成するように、1コンテナ内で複数プロセスが動くこと自体はよくある構成です。しかし、以下の理由から「1コンテナに1つの責務（多くの場合1メインプロセス）」が強く推奨されます。

- **スケーリング単位が濁る**：Webサーバーだけ増やしたいのに、同居する別プロセスまで一緒に増えてしまう
- **障害影響範囲が広がる**：1プロセスが落ちただけでコンテナ全体を再起動する必要が出る
- **ログ収集がしにくい**：Dockerは「標準出力＝そのコンテナのログ」という前提で設計されており、複数プロセスが混在すると出力が混ざる
- **PID 1問題**：Linuxにおいて、PID 1には孤児プロセスを回収する特別な責任があるが、通常のアプリケーションはその責務を想定して作られていないため、ゾンビプロセスが溜まりやすい

どうしても複数プロセスを1コンテナで動かす必要がある場合は、`tini` のような軽量initプロセスをPID 1として使い、シグナル処理とゾンビ回収を正しく行わせるのが定石です（`docker run --init` で有効化できます）。

## 5. 複数アプリを連携させる場合：ネットワーク分離と名前解決

複数のアプリケーションを連携させる際は、1つのコンテナに詰め込むのではなく、**それぞれ別コンテナとしてパッケージングし、ネットワーク経由で通信させる**のが標準的な設計です。ここで実務上問題になるのが「起動時にどうやって相手（IPとポート）を知るのか」です。

![コンテナ間通信と内蔵DNSによる名前解決](/images/fig05-container-dns.png)
*図5: ユーザー定義ブリッジネットワークと内蔵DNSによる名前解決*

**IPアドレスの解決は、Dockerが提供する内蔵DNSが担当します。** `docker network create` で作成したユーザー定義ネットワークに複数のコンテナを接続すると、コンテナ名（またはCompose上のサービス名）をそのままホスト名として使えるようになります。コンテナは再起動のたびに内部IPが変わり得ますが、名前は変わらないため、これはIP直書きよりも堅牢です。

```
# アプリ側コードのイメージ
db_connection = connect("app-b", 5432)
```

一方で **ポート番号はDockerが自動検出してくれるものではありません**。Dockerfileの`EXPOSE`命令もあくまでドキュメント的なメモであり強制力はなく、実際には環境変数や設定ファイルを通じて開発者間の「お約束」として明示的に共有する必要があります。

### 異なるシステムをDBごと個別管理したい場合

複数の独立したシステム（例：システムA、システムB）をそれぞれ専用のDBと組で運用したい場合は、**ネットワークごと分離**します。デフォルトでは、異なるユーザー定義ネットワークに属するコンテナ同士は互いに見えません。これにより、両システムで同じ`db`という名前のコンテナを使っていても名前が衝突せず、意図せず混線する事故を防げます。`docker-compose.yml`をプロジェクトごとに分けるだけで、Composeがこの専用ネットワークを自動的に作成します。

## 6. DockerとKubernetesは対立ではなく役割分担

ここまではDocker単体（1ホスト内）の話でした。ここからはスケールの話に移ります。

Dockerは「1つのコンテナをどう作り、どう動かすか」を担当する技術です。これに対しKubernetesは、**コンテナが何十〜何百個にもなったとき、複数サーバーにまたがってその数・配置・生死をどう自動管理するか**を担当します。両者は競合関係ではなく、Kubernetesの内部でも実際にコンテナを動かす部分にはコンテナランタイム（containerdなど）が使われているという、上下の関係です。

## 7. ECSとEKSは「兄弟関係」であり、包含関係ではない

AWSにはECSとEKSという2つのコンテナオーケストレーションサービスがあり、しばしば「どちらが上位互換か」という誤解を生みます。結論としては、**EKSがECSを包含しているわけではなく、両者は対等な選択肢**です。

![ECSとEKSの関係を示す図](/images/fig06-ecs-vs-eks.png)
*図6: 同じコンテナイメージに対するECSとEKSという2つの選択肢*

| | ECS | EKS |
|---|---|---|
| 位置づけ | AWS独自のオーケストレーションサービス | 本家Kubernetesのマネージドサービス |
| 強み | IAM・ALB・CloudWatchなどAWSサービス群とのシームレスな統合 | コントロールプレーンの運用をAWSが代行しつつ、他クラウドへの移植性が高い |
| 学習コスト | 比較的低い（AWS独自だが単純） | Kubernetesの知識がそのまま活きる、業界標準のエコシステム |

さらに図の下段にある「実行基盤（コンピュート）」も独立した軸です。ECS・EKSどちらの場合も、コンテナが実際にどこで動くかは**EC2（自分で管理）**か**Fargate（サーバーレス）**かを別途選択します。つまり実際には「ECS on EC2」「ECS on Fargate」「EKS on EC2」「EKS on Fargate」という2×2の組み合わせが存在し、**「何で管理するか（ECS/EKS）」と「どこで動かすか（EC2/Fargate）」は独立した軸**だと理解すると全体像が整理できます。

## 8. Fargateは「同一ホスト」という概念自体を消す

EC2ベースの構成に慣れていると、「Fargateでも、各コンテナから見れば結局は共有ホストの上で動いているのでは」と考えがちですが、これは誤りです。

![Fargateタスクの隔離とサービスディスカバリ](/images/fig07-fargate-isolation.png)
*図7: Fargateにおけるタスクの隔離とサービスディスカバリ*

Fargate上の各タスク（ECS）・各Pod（EKS）は、Firecrackerという軽量仮想化技術によって、それぞれ**独立した実行環境（マイクロVM）**として動作します。従来のDockerで説明してきた「1台のホストの中にdocker0ブリッジがあり、複数コンテナがぶら下がる」という構造とは異なり、**タスクAとタスクBは物理的にも別モノ**であり、それぞれに専用のENI（仮想NIC）とプライベートIPがVPCから直接割り当てられます。

ここで実務者からよく出る疑問が「Fargateの内部DNSは1つなのか」というものですが、これも誤解です。**DNS・名前解決はFargate自体の機能ではなく、その上に乗るオーケストレーション層（ECSまたはEKS）が提供します。**

- **ECS**：AWS Cloud Mapと連携する「ECS Service Discovery」を明示的に有効化する必要がある
- **EKS**：Kubernetes標準のCoreDNSが、クラスタ内で自動的に名前解決を担当する

つまり「Fargate全体で共通の1つのDNS」が存在するのではなく、**利用するクラスタ・オーケストレーターごとにスコープが閉じたDNSが別々に存在する**、というのが正確な理解です。

## 9. EC2上でコンテナを複数動かす場合のDNSと、オートスケールの実態

「EC2上で複数コンテナを動かす場合は内部DNSを使う」という理解は概ね正しいですが、条件が3パターンに分かれます。

| 構成 | DNSの扱い |
|---|---|
| Dockerを直接（オーケストレーターなし） | Docker内蔵DNSがそのまま使われる |
| ECS on EC2 | 自動ではない。AWS Cloud Mapで明示的に有効化する必要がある |
| EKS on EC2 | 自動。CoreDNSが標準コンポーネントとして動く |

つまり **DNSの自動有無を決めるのは「EC2かFargateか」という横軸ではなく、「Dockerか、ECSか、EKSか」という縦軸** です。

### EC2ノードグループ・キャパシティプロバイダーは何をしているか

ECS/EKSでEC2を使う場合、素朴なAuto Scaling Group（ASG）は「CPU使用率」のようなインスタンス単位の指標でしか判断できず、コンテナ特有の事情（メモリは余っているがタスクを配置しきれない、など）を汲み取れません。ECSの**キャパシティプロバイダー**とEKSの**マネージドノードグループ**は、この「コンテナのスケジューリング事情」と「EC2インスタンスの増減」を橋渡しする翻訳レイヤーです。

スケールアウトの流れは概ね以下の通りです。

1. 新しいタスク／Podが「保留中（Pending）」になる（既存ノードのリソース不足）
2. ECSはキャパシティ予約率、EKSは`Cluster Autoscaler`/`Karpenter`が未スケジュールPodを検知し、背後のASGにインスタンス追加を依頼する
3. ASGが起動テンプレートに従い、新しいEC2インスタンスを起動する
4. ブートストラップスクリプトによって、ECSエージェント／kubeletが自動的にクラスタへノード登録する
5. スケジューラーが保留中のタスク／Podを新ノードに配置する
6. 縮小時は、稼働中のタスクがないノードが優先的に削除される（終了保護／Pod Disruption Budgetにより優雅に退避）

なお、EKSのマネージドノードグループ自体は「ASGでノードを管理する仕組み」に過ぎず、**Pod不足の検知そのものは`Cluster Autoscaler`や`Karpenter`という別コンポーネントの仕事**です。ECSのキャパシティプロバイダーがAWS標準機能として一体化しているのとは対照的な点なので、構築時に見落としやすいポイントです。

### クラスタは動的に生成されるのか

「クラスタ」という言葉は2つの異なるものを指している点に注意が必要です。

- **クラスタ自体（コントロールプレーン／論理グループ）**：ECS・EKSいずれも、ユーザーが明示的に作成する必要があります。ECSはほぼ即時・無料に近い軽量な操作ですが、EKSはAWSがKubernetesのコントロールプレーンを構築するため10〜15分程度かかり、稼働中は時間課金が発生します。
- **コンピュート容量（EC2かFargateか）**：ここが実際に「動的」かどうかの分かれ目です。EC2ノードグループはASGにより半自動で増減しますが、実体はEC2インスタンスであり最低台数分は起動し続けます。Fargateを選んだ場合のみ、EC2という概念自体が消え、使う瞬間だけリソースが生成される**真の意味での動的**な挙動になります。

## 10. Dockerはインフラの種類を意識しない

ここまでAWSの話をしてきましたが、重要な補足として、**Dockerというソフトウェア自体は、自分がEC2上にいるのか、オンプレのVM上にいるのか、物理サーバー上にいるのかを一切区別していません**。

`docker0`ブリッジ、iptablesによるNAT、名前空間による隔離、内蔵DNSといった仕組みは、すべて**Linuxカーネルの機能**を使って実現されています。EC2インスタンスの正体は「AWSが管理しているだけの、ただのLinux仮想マシン」であり、VMware ESXiやKVMで作ったオンプレのLinux VMと、カーネルの機能を使うという一点においてDockerからは区別がつきません。

ただし、以下の2点は環境によって明確に異なります。

- **ホストの外側のネットワーク管理**：EC2はセキュリティグループ・VPC・ENIなどAWS独自のレイヤーで管理されるのに対し、オンプレは従来型のファイアウォールやVLANで管理する
- **ゲストOSがWindowsの場合**：そのままではLinux用コンテナを動かせず、Docker Desktopなどが裏で軽量Linux VM（WSL2など）を起動し、その中で本物のLinuxカーネルを使ったコンテナを動かすという二重構造になる

「Linux OSが動いているVM（または物理サーバー）である」という条件さえ満たしていれば、AWSかオンプレかを問わず、これまで説明してきたDockerの挙動はそのまま当てはまります。

## 11. 実践編：オンプレRHEL + Podmanを100台規模でIaC構築する

最後に、ここまでの理解を踏まえた実務ケースとして、**オンプレの仮想化基盤（VMware vSphereまたはRed Hat Virtualization）上にRHELサーバーを100台用意し、それぞれでPodmanコンテナを起動する**構成を、IaCで実現します。

### 採用する組み合わせ

| 役割 | ツール | 採用理由 |
|---|---|---|
| VM作成（100台） | Terraform / OpenTofu | `count`/`for_each`で台数管理が容易。vSphere・oVirt双方に対応するプロバイダーが存在する |
| OS設定・Podman導入 | Ansible | RHELエコシステムとの親和性が高く、エージェントレスで100台へ並列適用できる |
| コンテナ定義・起動 | Podman Quadlet（RHEL 9 / Podman 4系以降） | `.container`ユニットファイルを配置するだけでsystemdサービス化される、宣言的かつRHELの通常運用にそのまま乗る仕組み |

「VMの器を作る（Terraform）→ 中身を整える（Ansible）→ コンテナを起動する（Quadlet）」と責務を分離することで、100台規模でも見通しの良い構成になります。

### Terraform：VMware vSphereの場合

```hcl
terraform {
  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = "~> 2.7"
    }
  }
}

provider "vsphere" {
  user                 = var.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = true
}

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_datastore" "datastore" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

# 事前にRHELのテンプレートVM（cloud-init対応済み推奨）を作成しておく
data "vsphere_virtual_machine" "template" {
  name          = var.template_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

resource "vsphere_virtual_machine" "podman_host" {
  count            = var.vm_count
  name             = format("podman-host-%03d", count.index + 1)
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastore.id

  num_cpus = var.cpu_count
  memory   = var.memory_mb
  guest_id = data.vsphere_virtual_machine.template.guest_id

  network_interface {
    network_id = data.vsphere_network.network.id
  }

  disk {
    label = "disk0"
    size  = data.vsphere_virtual_machine.template.disks.0.size
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id

    customize {
      linux_options {
        host_name = format("podman-host-%03d", count.index + 1)
        domain    = var.domain
      }

      network_interface {
        ipv4_address = cidrhost(var.subnet_cidr, var.ip_start + count.index)
        ipv4_netmask = var.netmask_bits
      }

      ipv4_gateway    = var.gateway
      dns_server_list = var.dns_servers
    }
  }
}

# Ansibleが使う静的インベントリを自動生成
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.ini"
  content = join("\n", concat(
    ["[podman_hosts]"],
    [for vm in vsphere_virtual_machine.podman_host : "${vm.name} ansible_host=${vm.default_ip_address}"]
  ))
}
```

`vm_count`のデフォルト値を`100`にしておくことで、`terraform apply`一発で100台分のクローン作成・IP割り当て・Ansibleインベントリ生成までが完結します。

### Terraform：RHV/oVirtの場合

```hcl
terraform {
  required_providers {
    ovirt = {
      source  = "oVirt/ovirt"
      version = "~> 1.0"
    }
  }
}

provider "ovirt" {
  url           = var.ovirt_url
  username      = var.ovirt_username
  password      = var.ovirt_password
  tls_ca_bundle = file(var.ca_file)
}

data "ovirt_clusters" "cluster" {
  name_regex = var.cluster_name
}

data "ovirt_templates" "template" {
  name_regex = var.template_name
}

resource "ovirt_vm" "podman_host" {
  count       = var.vm_count
  name        = format("podman-host-%03d", count.index + 1)
  cluster_id  = data.ovirt_clusters.cluster.clusters.0.id
  template_id = data.ovirt_templates.template.templates.0.id

  cpu_cores  = var.cpu_cores
  cpu_socket = 1
  memory     = var.memory_bytes

  initialization {
    host_name = format("podman-host-%03d.%s", count.index + 1, var.domain)
    custom_script = <<-EOT
      #cloud-config
      network:
        version: 2
        ethernets:
          eth0:
            addresses: [${cidrhost(var.subnet_cidr, var.ip_start + count.index)}/${var.netmask_bits}]
            gateway4: ${var.gateway}
            nameservers:
              addresses: [${join(", ", var.dns_servers)}]
    EOT
  }
}

resource "ovirt_vm_start" "start_all" {
  count = var.vm_count
  vm_id = ovirt_vm.podman_host[count.index].id
}
```

vSphere版との違いは、クローン方式（`clone`ブロック vs `initialization`のcloud-init注入）とプロバイダー特有のデータソースのみで、**「100台をループで作り、Ansibleに引き渡す」という設計思想は共通**です。

### Ansible：Podmanのセットアップと100台への並列適用

```yaml
---
- name: RHEL上にPodman + Quadletでアプリコンテナを展開する
  hosts: podman_hosts
  become: true
  vars:
    app_image: "registry.example.com/myapp:latest"
    app_port: 8080

  tasks:
    - name: Podman一式をインストール
      ansible.builtin.dnf:
        name:
          - podman
          - podman-compose
        state: present

    - name: Quadletユニット配置ディレクトリを作成
      ansible.builtin.file:
        path: /etc/containers/systemd
        state: directory
        mode: "0755"

    - name: Quadletユニットファイル（app.container）を配置
      ansible.builtin.template:
        src: templates/app.container.j2
        dest: /etc/containers/systemd/app.container
        mode: "0644"
      notify: systemdをリロードしてコンテナを起動

    - name: firewalldでアプリのポートを開放
      ansible.posix.firewalld:
        port: "{{ app_port }}/tcp"
        permanent: true
        immediate: true
        state: enabled

  handlers:
    - name: systemdをリロードしてコンテナを起動
      ansible.builtin.systemd:
        daemon_reload: true
      listen: systemdをリロードしてコンテナを起動

    - name: app.serviceを起動
      ansible.builtin.systemd:
        name: app.service
        state: started
        enabled: true
      listen: systemdをリロードしてコンテナを起動
```

`app.container.j2`（Quadletユニットテンプレート）：

```ini
[Unit]
Description=My Application Container
After=network-online.target
Wants=network-online.target

[Container]
Image={{ app_image }}
PublishPort={{ app_port }}:8080
AutoUpdate=registry
Environment=APP_ENV=production

[Service]
Restart=always
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
```

Podman QuadletはRHEL 9 / Podman 4系以降で標準搭載されている、systemdネイティブな仕組みです。`.container`ファイルを`/etc/containers/systemd/`に置くだけで、systemdが自動的に`.service`ユニットを生成し、`systemctl start app.service` / `journalctl -u app.service`という、他のRHELサービスと全く同じ操作で管理できます。本記事の前半で述べた「1コンテナ1プロセス」の原則を、1ホストにつき1つの`.container`ファイル＝1つの責務という形でそのまま体現できる点も、この構成を選んだ理由です。

`ansible.cfg`では、並列実行数（forks）を台数に合わせて引き上げておく点も重要です。

```ini
[defaults]
inventory = inventory.ini
host_key_checking = False
forks = 100
remote_user = ansible-svc

[privilege_escalation]
become = True
become_method = sudo
```

デフォルトの`forks=5`のままだと、100台に対して実質的に20回の逐次バッチ処理になってしまうため、規模に応じた明示的な調整が必須です。

### スケールする際の注意点

- `terraform apply`は内部的に並列でVMを作成しますが、vSphere/oVirt側のAPIやストレージI/Oが詰まりやすいため、`-parallelism=10`のように同時実行数を絞ると安定します
- Ansibleの`forks`は、管理ノードのリソースに応じて調整します（目安：管理ノードのCPUコア数 × 10〜20程度）
- テンプレートVM側で事前に`cloud-init`を有効化しておくことが前提です
- Satellite等でサブスクリプション管理をしている場合は、Ansible側で`redhat_subscription`モジュールを使い、RHELのサブスクリプション登録も自動化できます

## まとめ

本記事で扱った内容を1枚にまとめると、以下のようになります。

- コンテナは「ミニLinux」ではなく、ホストカーネルを共有する隔離されたプロセスである
- ライブラリはプロセスの一部であり、独立して起動・通信するわけではない
- 「1コンテナ1プロセス」は技術的制約ではなく、運用上の設計原則である
- コンテナ間通信は内蔵DNSによる名前解決が基本だが、ポート番号は開発者間の取り決めである
- ECSとEKSは対等な選択肢であり、EC2/Fargateという実行基盤の軸とは独立している
- Fargateは「ホスト」という概念自体をなくす仕組みであり、DNSはオーケストレーション層の責務である
- Dockerの挙動自体はインフラの種類（クラウド／オンプレ）を問わず共通であり、Linuxカーネルの機能に依存している

これらは個別の知識としては断片的に見えますが、「コンテナの正体はLinuxカーネルの機能を使った隔離プロセスである」という一点を軸に理解すると、AWSのマネージドサービス群やオンプレ運用まで、驚くほど一貫した説明が可能になります。
