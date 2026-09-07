---
title: "金融機関の電算部門を想定した、監査に耐えるデータ基盤の作り方(S3×Iceberg実践) (3) 実装編"
emoji: "🛠️"
type: "tech"
topics: ["aws", "iceberg", "spark", "pyspark", "s3"]
published: false
---

## 前回までのおさらい

```mermaid
flowchart LR
    R1["第1回<br/>アーキテクチャ選定編"] --> R2["第2回<br/>権限設計と<br/>データガバナンス編"]
    R2 --> R3["第3回<br/>実装編<br/>(本記事)"]
    R3 --> R4["第4回<br/>障害対応訓練編"]
    R4 --> R5["第5回<br/>本番移行<br/>ギャップ分析編"]

    style R3 fill:#e8f0fe,stroke:#4285f4
```

第1回でS3バケットを、第2回で最小権限のIAMユーザー(`glue-etl-handson-user`)を作成しました。今回はいよいよ、設計してきた内容を実際のPySparkスクリプトに落とし込みます。

> ✅ **この記事(第3回)を読み終えると、こうなります**
> - Icebergテーブルを扱うPySparkスクリプトを、**Hadoopカタログの設定込みで**自分で書ける
> - `customer_id`のマスキング処理を、**ソルトをハードコードしない形で**実装できる
> - `docker run`で、**運用専用の最小権限プロファイルを使って**、Glueジョブと同一構成のコンテナからETL処理を実行できる
>
> **前提知識**: 第1回・第2回のハンズオンを完了していること(バケット・IAMユーザーが作成済みであること)。

## この回でやること

```mermaid
flowchart LR
    T1["① ダミーCSVを準備し<br/>S3にアップロード"] --> T2["② PySparkスクリプトを実装"]
    T2 --> T3["③ dockerコンテナから<br/>glue-etl-handsonプロファイルで実行"]
    T3 --> T4["④ Icebergテーブルの中身を検証"]

    style T1 fill:#e8f0fe,stroke:#4285f4
    style T4 fill:#e6f4ea,stroke:#34a853
```

## Step 1: ダミーデータの準備

銀行の取引明細を模したデータを用意します。**手打ちで数十行のCSVを作ることもできますが、それではパーティション設計の効果(日付ごとにファイルが分かれること)や、`customer_id`の重複によるハッシュ値の一致を確認しづらいため、ある程度まとまった件数を、再現可能な形で生成します。**

以下のPythonスクリプトを`generate_dummy_data.py`として保存してください(Windows PCにPython 3が入っていれば、追加のライブラリは不要です)。

```python
import random
import csv
from datetime import date, timedelta

random.seed(42)  # 固定シードで再現性を担保(誰が実行しても同じデータになる)

NUM_TRANSACTIONS = 500
NUM_CUSTOMERS = 50
START_DATE = date(2026, 1, 1)
NUM_DAYS = 60
BRANCHES = ["001", "002", "003", "004", "005"]
TRANSACTION_TYPES = ["振込", "引出", "入金", "振替"]

customers = [f"CUST-{i:05d}" for i in range(1, NUM_CUSTOMERS + 1)]

rows = []
for i in range(1, NUM_TRANSACTIONS + 1):
    txn_id = f"TXN-{i:06d}"
    txn_date = START_DATE + timedelta(days=random.randint(0, NUM_DAYS - 1))
    customer_id = random.choice(customers)
    txn_type = random.choice(TRANSACTION_TYPES)
    if txn_type == "入金":
        amount = random.randint(10000, 3000000)
    elif txn_type == "引出":
        amount = random.randint(1000, 500000)
    else:
        amount = random.randint(1000, 1000000)
    branch = random.choice(BRANCHES)
    rows.append([txn_id, txn_date.isoformat(), customer_id, amount, branch, txn_type])

rows.sort(key=lambda r: (r[1], r[0]))

with open("transactions.csv", "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    writer.writerow(["transaction_id", "transaction_date", "customer_id", "amount", "branch_code", "transaction_type"])
    writer.writerows(rows)

print(f"{len(rows)}件のダミーデータを transactions.csv に生成しました。")
print(f"期間: {START_DATE} 〜 {START_DATE + timedelta(days=NUM_DAYS-1)}")
print(f"顧客数: {NUM_CUSTOMERS}名")
```

```powershell
python generate_dummy_data.py
```

![Fig: generate_dummy_data.pyの実行結果と、生成されたtransactions.csvの中身](/images/20260905_03_1_generate-dummy-data.png)

**乱数のシード(`random.seed(42)`)を固定しているため、誰の環境で実行しても同じ`transactions.csv`が生成されます。** これにより、記事の読者全員が同じ検証結果を再現できます(実務のテストデータ生成でも、再現性のために固定シードを使うのは一般的な手法です)。

- 60日間に500件を分散させているため、1日あたり平均8〜9件、多い日でも14〜15件程度になります(数十行で1日1〜2件しかない状態と比べ、パーティションごとにある程度のファイルサイズが確保されます)。
- 顧客数を50名に絞っているため、1人あたり平均10件、多い顧客で15件の取引が発生します。**同じ`customer_id`が複数回登場する**ため、マスキング後に同じハッシュ値になっているかどうかを、Step 4で実際に確認できます。

「1人あたり最大15件」という分布は、`generate_dummy_data.py`の実行結果メッセージには表示されません。実際に手元で確認してみましょう。

```powershell
Import-Csv .\transactions.csv | Group-Object customer_id | Sort-Object Count -Descending | Select-Object -First 5
```

![Fig: 顧客ごとの取引件数を多い順に確認した結果。上位2名が15件で並んでいる](/images/20260905_03_1_customer-distribution-check.png)

`Count`が多い順に上位5名の`customer_id`と件数が表示されます。乱数のシードを固定しているため、**このコマンドの実行結果は誰の環境でも同じ**になるはずです。この上位の顔ぶれと件数を控えておくと、Step 4で`customer_id_hash`ごとの集計結果と突き合わせて確認できます。

### S3へのアップロード

**アップロード作業自体は、`raw/`へのデータ配置という「データ投入」の作業なので、管理者プロファイル(`default`)ではなく、日常運用プロファイル(`glue-etl-handson`)で行います。** ここは実務でも見落としがちなポイントで、「環境構築(管理者)」と「日常のデータ授受(運用)」を区別する良い練習になります。

```powershell
aws s3 cp ./transactions.csv "s3://$bucket/raw/transactions.csv" --profile glue-etl-handson
```

第2回で設計したポリシーの通り、`raw/*`への`PutObject`は許可されているはずなので、これは成功します。

```powershell
aws s3 ls "s3://$bucket/raw/" --profile glue-etl-handson
```

![Fig: aws s3 cpとaws s3 lsの実行結果。transactions.csvがアップロードされている](/images/20260905_03_1_s3-upload-cli.png)

コンソールでも、アップロードされたオブジェクトを確認できます。

![Fig: S3コンソールでのtransactions.csvのオブジェクト詳細画面(所有者IDは黒塗り済み)](/images/20260905_03_1_s3-console-object.png)

> 📸 **証跡として残すもの**: `aws s3 cp`と`aws s3 ls`の実行結果を保存してください。

## Step 2: PySparkスクリプトの実装

### 2-0. マスキングソルトを用意する

コードを書く前に、**ソルトの値そのものをどう用意し、どう扱うか**を決めておきます。ここが曖昧なまま進めると、実行のたびに違うソルトを使ってしまい、「同じ顧客は毎回同じハッシュ値になる」という前提が崩れてしまいます。**ソルトは一度決めたら、このハンズオンを通して使い回してください。**

第1回のバケット名と同じ要領で、ランダムな文字列を1回だけ生成し、**Gitやリポジトリには絶対にコミットしない場所**に保存します。

```powershell
# ランダムな32文字のソルトを生成する(このコマンドは1回だけ実行する)
$salt = -join ((48..57) + (97..122) | Get-Random -Count 32 | ForEach-Object {[char]$_})

# Gitの管理対象外のフォルダに保存する(例: D:\work\AWS\secrets\ 配下)
New-Item -ItemType Directory -Force -Path D:\work\AWS\secrets | Out-Null
$salt | Out-File -FilePath D:\work\AWS\secrets\masking_salt.txt -Encoding utf8 -NoNewline

Write-Output "ソルトを生成しました(値はmasking_salt.txtに保存済みです)"
```

![Fig: ソルト生成コマンドの実行結果と、保存されたmasking_salt.txtの中身(値は黒塗り済み)](/images/20260905_03_2-0_masking-salt-generated.png)

> ⚠️ **証跡取得時の注意**: この画面をそのまま証跡にする場合、生成されたソルトの値自体が写り込みます。`SecretAccessKey`と同じ扱いとして、**値の部分は必ず黒塗りしてから保存してください。**

> ⚠️ **`secrets`フォルダは`.gitignore`に必ず追加してください。** リポジトリを作る場合、`masking_salt.txt`を誤ってコミットしてしまうと、ソルトを環境変数化した意味がなくなります。
>
> 💡 **本番であれば**: このソルトはAWS Secrets ManagerやSSM Parameter Store(SecureString)に保存し、ジョブの実行時にAPI経由で取得するのが基本です。ローカルファイルへの保存は、あくまで個人検証における簡略化です。

以降、`docker run`のたびに、このファイルからソルトを読み込んで環境変数として渡します。

```powershell
$salt = Get-Content D:\work\AWS\secrets\masking_salt.txt -Raw
```

### 2-1. マスキング処理:ソルトをハードコードしない

第2回で決めた通り、`customer_id`はSHA-256ハッシュ化します。**ソルトの値はスクリプトに直接書き込まず、環境変数から読み込みます。**

```python
import os
import hashlib

# ソルトは環境変数から取得する。本番ではAWS Secrets Manager等から取得すべきだが、
# このハンズオンでは環境変数への切り出しまでを「最低限のセキュリティ意識」として実装する。
MASKING_SALT = os.environ.get("MASKING_SALT")
if not MASKING_SALT:
    raise ValueError("環境変数 MASKING_SALT が設定されていません。docker run時に -e MASKING_SALT=... を指定してください。")

def mask_customer_id(customer_id: str) -> str:
    """customer_id をソルト付きSHA-256でハッシュ化する(不可逆)"""
    return hashlib.sha256((customer_id + MASKING_SALT).encode("utf-8")).hexdigest()
```

### 2-2. Sparkセッションの構築(Hadoopカタログの設定)

第1回で決めた通り、カタログはHadoopカタログを使います。`local`という名前でカタログを定義し、S3上の`warehouse/`をカタログの実体として指定します。

```python
from pyspark.sql import SparkSession

BUCKET = os.environ.get("BUCKET_NAME")
if not BUCKET:
    raise ValueError("環境変数 BUCKET_NAME が設定されていません。")

spark = (
    SparkSession.builder
    .appName("transactions-masking-etl")
    .config("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
    .config("spark.sql.catalog.local", "org.apache.iceberg.spark.SparkCatalog")
    .config("spark.sql.catalog.local.type", "hadoop")
    .config("spark.sql.catalog.local.warehouse", f"s3a://{BUCKET}/warehouse")
    .getOrCreate()
)
```

### 2-3. 読み込み → マスキング → 書き出し

```python
from pyspark.sql.functions import udf, col
from pyspark.sql.types import StringType, StructType, StructField, DateType, DecimalType

mask_udf = udf(mask_customer_id, StringType())

# ① S3から読み込み
# inferSchema(型の自動推測)には頼らず、明示的にスキーマを定義する。
# transaction_dateやamountが意図しない型(STRING/INTなど)と推測されてしまうと、
# 後続のIcebergテーブル書き込み時に型不一致でエラーになるため。
csv_schema = StructType([
    StructField("transaction_id", StringType(), nullable=False),
    StructField("transaction_date", DateType(), nullable=False),
    StructField("customer_id", StringType(), nullable=False),
    StructField("amount", DecimalType(15, 2), nullable=False),
    StructField("branch_code", StringType(), nullable=False),
    StructField("transaction_type", StringType(), nullable=False),
])

df = (
    spark.read
    .option("header", True)
    .schema(csv_schema)
    .csv(f"s3a://{BUCKET}/raw/transactions.csv")
)

# ② customer_idをマスキングし、元の列は削除する
masked_df = (
    df.withColumn("customer_id_hash", mask_udf(col("customer_id")))
      .drop("customer_id")
)

# ③ Icebergテーブルとして書き出す(パーティション: transaction_dateのdays変換)
spark.sql("CREATE NAMESPACE IF NOT EXISTS local.db")

spark.sql("""
    CREATE TABLE IF NOT EXISTS local.db.transactions (
        transaction_id      STRING,
        transaction_date    DATE,
        amount              DECIMAL(15,2),
        branch_code         STRING,
        transaction_type    STRING,
        customer_id_hash    STRING
    )
    USING iceberg
    PARTITIONED BY (days(transaction_date))
    TBLPROPERTIES ('format-version' = '2')
""")

masked_df.select(
    "transaction_id", "transaction_date", "amount",
    "branch_code", "transaction_type", "customer_id_hash"
).writeTo("local.db.transactions").append()

print(f"書き込み完了。件数: {masked_df.count()}")
```

このスクリプトを`transactions_etl.py`として、ローカルPC上のわかりやすい場所(例: `D:\work\AWS\scripts\`)に保存してください。

> ⚠️ **`customer_id`列を`drop`していることに注目してください。** マスキング後のハッシュ値だけを残し、元の`customer_id`はSpark上のメモリにも、書き出し先のS3にも一切残しません。「マスキングした列を追加しただけで、元の列も一緒に書き出してしまう」というミスは実務でも起こりがちなので、意識的にチェックすべきポイントです。

## Step 3: dockerコンテナからの実行

**ここまでの作業(S3操作、IAM操作、スクリプトの編集)はすべてWindows PC上で行ってきましたが、`docker run`自体は、Dockerがインストールされている Proxmox上のLXCコンテナ(`docker-etl`, `<LXCのIPアドレス>`)側で実行する必要があります。** Windows PCにはDockerが入っていないためです。

```mermaid
flowchart LR
    subgraph Win["Windows PC"]
        Script["transactions_etl.py"]
        Cred["glue-etl-handsonの<br/>認証情報"]
    end
    subgraph LXC["LXC: docker-etl (<LXCのIPアドレス>)"]
        Docker["Docker: amazon/aws-glue-libs:5"]
    end

    Script -->|"① scpで転送"| LXC
    Cred -->|"② export-credentialsで払い出し、<br/>SSH経由で環境変数として設定"| LXC
    LXC -->|"③ docker runで実行"| Docker

    style Win fill:#e8f0fe,stroke:#4285f4
    style LXC fill:#fef7e0,stroke:#f9ab00
```

以降のコマンド中の`etl-operator`は、LXC上に作成する運用専用ユーザー名です(次のStep 3-0で作成します)。

> 💡 **改行記法の違いに注意してください**: これまでのWindows PC(PowerShell)のコマンドは、行末にバックティック(`` ` ``)を付けて改行していました。これに対し、LXCに入った後のシェル(Bash)では、**行末にバックスラッシュ(`\`)を使います**。この後の`docker run`コマンドをコピーする際、今どちら側のシェルを操作しているかによって書式が変わる点に気をつけてください。

### 3-0. LXC側に、日常操作用の非rootユーザーを作成する(初回のみ)

**日常のscp・docker run操作にrootを使い回すのは避けます。** ここは正直に前提を共有しておきます。Dockerはその仕組み上、`docker`グループに所属するユーザーは実質的にroot相当の操作が可能です(ホストのファイルシステムを丸ごとマウントしたコンテナを起動できてしまうため)。**完全な権限分離にはrootless Docker等の仕組みが必要ですが、それは本シリーズの範囲を超えるため、第5回(本番移行ギャップ分析編)の課題として扱います。**

その前提を踏まえたうえで、**最低限の統制**として、「rootは初期設定専用」「日常操作は専用ユーザー」という区別だけは入れておきます。この作業は初回の1回だけ、Proxmoxホスト経由でrootとして行います。

Proxmoxホストにログインし(Web UIのコンソール、または`pct enter 200`)、LXCコンテナ内で以下を実行してください。

```bash
# 運用専用ユーザーを作成する
useradd -m -s /bin/bash etl-operator

# dockerグループを作成する
# (オフラインで静的バイナリからDockerをインストールした環境では、
#  パッケージ管理経由のインストールと異なり、dockerグループが自動的には作成されないことがある)
groupadd docker

# ソケットの所有グループにdockerが反映されるよう、デーモンを再起動する
systemctl restart docker

# dockerグループに所属させる(前述の通り、これは実質rootに近い権限であることに注意)
usermod -aG docker etl-operator

# パスワードを設定する(もしくは、SSH鍵認証を別途設定する)
passwd etl-operator

# 作業用ディレクトリを作成し、所有者を変更する
mkdir -p /home/etl-operator/etl
chown etl-operator:etl-operator /home/etl-operator/etl
```

`groupadd`・`systemctl restart docker`によって、`docker.sock`の所有グループが正しく`docker`になっていることを確認できます。

![Fig: /var/run/docker.sockの所有グループがdockerになっていることの確認](/images/20260905_03_3-0_docker-socket-group.png)

`usermod`と`id`コマンドで、`etl-operator`が`docker`グループに正しく所属していることも確認します。

```bash
id etl-operator
```

![Fig: id etl-operatorの実行結果。groupsにdockerが含まれている](/images/20260905_03_3-0_usermod-id-result.png)

以降、本記事のコマンドはすべてこの`etl-operator`ユーザーで実行します。**rootでのSSHログインは、この後の手順では一切使いません。** Windows PC側から、`etl-operator`としてSSH接続できることを確認しておいてください。

```powershell
ssh etl-operator@<LXCのIPアドレス>
```

![Fig: etl-operatorとしてSSHログインに成功した画面](/images/20260905_03_3-0_ssh-login-success.png)

> 📸 **証跡として残すもの**: `id etl-operator`の実行結果と、SSHログイン成功後のプロンプト(`etl-operator@docker-etl:~$`になっていること)を保存してください。

### 3-1. スクリプトをLXCに転送する

Windows PCのPowerShellから、`scp`でスクリプトをLXCに転送します(Windows 10/11には標準でOpenSSHクライアントが入っているため、追加インストールは不要です)。

```powershell
scp D:\work\AWS\scripts\transactions_etl.py etl-operator@<LXCのIPアドレス>:/home/etl-operator/etl/transactions_etl.py
```

転送先の`/home/etl-operator/etl/`ディレクトリが存在しない場合は、先にLXC側で作成しておいてください。

![Fig: scpによるtransactions_etl.pyの転送結果](/images/20260905_03_3-1_scp-script-transfer.png)

### 3-2. 認証情報をLXCに安全に払い出す

**Windows PC上の`~/.aws`ファイルをまるごとLXCにコピーするのは避けます。** それでは`glue-etl-handson`だけでなく`default`(管理者)の認証情報までLXC上に残ってしまい、意図しない権限のコピーが発生するためです。代わりに、AWS CLI公式の`export-credentials`コマンドで、**`glue-etl-handson`プロファイル1つ分の認証情報だけ**を一時的に取り出します。

```powershell
aws configure export-credentials --profile glue-etl-handson --format env
```

実行すると、以下のような出力が得られます(値は実際のものに読み替えてください)。

```
export AWS_ACCESS_KEY_ID=AKIAXXXXXXXXXXXXXXXX
export AWS_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

> 🔴 **この出力も`SecretAccessKey`と同じ扱いです。** 画面の値をそのまま証跡として貼らないでください。次のステップですぐに使い、控えたりコピーしたテキストは使い終わったら破棄してください。

### 3-3. LXCにSSHログインし、環境変数を設定する

```powershell
ssh etl-operator@<LXCのIPアドレス>
```

LXCにログインしたら、3-2で表示された2行(`export AWS_ACCESS_KEY_ID=...`と`export AWS_SECRET_ACCESS_KEY=...`)をそのまま貼り付けて実行します。続けて、残りの環境変数も設定します。

```bash
export AWS_REGION=ap-northeast-1
export BUCKET_NAME=glue-etl-handson-x7f3k9pw   # ご自身のバケット名に置き換えてください
```

![Fig: export-credentialsの実行、SSHログイン、4つの環境変数設定までの一連の流れ(認証情報・ホスト名・バケット名は黒塗り済み)](/images/20260905_03_3-2_3-3_export-credentials-ssh.png)

`MASKING_SALT`はWindows PC上のファイル(`masking_salt.txt`)にしか存在しないため、これもscpでLXCに転送してから読み込みます。

```powershell
# Windows PC側で実行
scp D:\work\AWS\secrets\masking_salt.txt etl-operator@<LXCのIPアドレス>:/home/etl-operator/etl/masking_salt.txt
```

```bash
# LXC側で実行
export MASKING_SALT=$(cat /home/etl-operator/etl/masking_salt.txt)
```

![Fig: masking_salt.txtの転送と、MASKING_SALT環境変数への読み込み(ホスト名は黒塗り済み)](/images/20260905_03_3-3_salt-transfer-and-export.png)

### 3-4. `docker run`で実行する

LXC上のシェルで、以下を実行します。`-e 変数名`のように値を付けずに指定すると、**今設定したシェルの環境変数の値がそのままコンテナに引き継がれます**(コマンド自体に値を書かずに済むため、コマンド履歴に認証情報が残りにくくなります)。

```bash
docker run --rm -it \
  --security-opt apparmor=unconfined \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e AWS_REGION \
  -e BUCKET_NAME \
  -e MASKING_SALT \
  -v /home/etl-operator/etl:/home/glue_user/workspace \
  amazon/aws-glue-libs:5 \
  spark-submit /home/glue_user/workspace/transactions_etl.py
```

実行にはSparkの起動を含めて数十秒かかります。ログの大半はSparkの内部処理(JVM起動、リソース割り当てなど)に関するもので、実際に**確認すべきなのは以下の3箇所**です。

**① CSVの読み込みとテーブルスキーマの確認**

```
26/09/05 14:43:36 INFO SparkTable: Table local.db.transactions loaded Spark schema: StructType(StructField(transaction_id,StringType,true),StructField(transaction_date,DateType,true),StructField(amount,DecimalType(15,2),true),StructField(branch_code,StringType,true),StructField(transaction_type,StringType,true),StructField(customer_id_hash,StringType,true))
```

`transaction_date`が`DateType`、`amount`が`DecimalType(15,2)`になっていることを確認してください。ここが`StringType`や`IntegerType`になっていた場合、Step 2-3で修正した明示的スキーマ定義が反映されていません。

**② Icebergへのコミット(書き込み)**

```
26/09/05 14:43:47 INFO SparkWrite: Committing append with 60 new data files to table local.db.transactions
26/09/05 14:43:49 INFO HadoopTableOperations: Committed a new metadata file s3a://(バケット名)/warehouse/db/transactions/metadata/v2.metadata.json
26/09/05 14:43:49 INFO SnapshotProducer: Committed snapshot 298233760807595217 (MergeAppend)
26/09/05 14:43:50 INFO LoggingMetricsReporter: Received metrics report: ... addedDataFiles=CounterResult{unit=COUNT, value=60} ... addedRecords=CounterResult{unit=COUNT, value=500} ...
```

**60個のデータファイルが作成され、500件のレコードが追加された**ことが確認できます。60というファイル数は、60日分のダミーデータが1日1ファイルの粒度でパーティション分割されたことを示しており、第2回で設計した`days(transaction_date)`のパーティション設計が意図通りに機能している証拠です。また、`Committed snapshot 298233760807595217`のスナップショットIDは、**第4回のタイムトラベル演習で実際に使うことになる識別子**です。

**③ 最終的な完了メッセージ**

```
書き込み完了。件数: 500
```

これがスクリプト自身の`print`文による出力です。①〜③がすべて確認できれば成功です。

> 📸 **証跡として残すもの**: 上記①〜③の3箇所を保存してください。ログ全体は数百行にわたるため、全文を証跡にする必要はありません。ただし、この画面より前のステップ(3-2、3-3実行直後)で認証情報が表示されている場合は、そちらは証跡にしないでください。

> ⚠️ **後片付け**: 検証が終わったら、LXC上に残した`transactions_etl.py`・`masking_salt.txt`や、シェルの環境変数(`AWS_ACCESS_KEY_ID`等)は、そのセッションを閉じれば環境変数は消えますが、ファイルは明示的に削除してください。LXCは複数人がアクセスしうる共有環境である可能性もあるため、「使い終わった認証情報の痕跡を残さない」という意識が実務でも重要です。

## Step 4: Icebergテーブルの検証

**Step 4以降のコマンドは、引き続きLXC上のシェルで実行します。** Step 3-3で設定した環境変数(`BUCKET_NAME`等)は同じシェルセッション内であればそのまま使えます。

### 4-1. S3上に書き出されたファイルを確認する

Windows PC側に戻って、`aws s3 ls`で確認することもできます。

```powershell
aws s3 ls "s3://$bucket/warehouse/db/transactions/" --recursive --profile glue-etl-handson
```

`metadata/`(スナップショット・スキーマ等のメタデータ)と`data/`(実際のParquetファイル)が作成されているはずです。`data/`配下が`transaction_date`の日付ごとにディレクトリ分割されていれば、パーティション設計が意図通りに機能している証拠です。実際の出力は60ファイル分と長いため、**先頭・末尾を抜粋**します。

```
2026-09-05 23:43:40       2819 warehouse/db/transactions/data/transaction_date_day=2026-01-01/00000-1-...-00008.parquet
2026-09-05 23:43:41       2430 warehouse/db/transactions/data/transaction_date_day=2026-01-02/00000-1-...-00043.parquet
                                                          ...(2026-01-03 〜 2026-02-27まで、日付ごとに1ファイルずつ続く)...
2026-09-05 23:43:48       2438 warehouse/db/transactions/data/transaction_date_day=2026-03-01/00000-1-...-00007.parquet
2026-09-05 23:43:49      10823 warehouse/db/transactions/metadata/3afb15b4-...-m0.avro
2026-09-05 23:43:49       4482 warehouse/db/transactions/metadata/snap-298233760807595217-1-...-m0.avro
2026-09-05 23:43:36       1623 warehouse/db/transactions/metadata/v1.metadata.json
2026-09-05 23:43:49       2914 warehouse/db/transactions/metadata/v2.metadata.json
2026-09-05 23:43:50          1 warehouse/db/transactions/metadata/version-hint.text
```

`transaction_date_day=2026-01-01/`から`2026-03-01/`まで、**60日分がディレクトリとして分割されている**こと、そして`metadata/`配下に`v1.metadata.json`(テーブル作成時)と`v2.metadata.json`(今回の書き込み後)の2つのバージョンが存在することを確認してください。`snap-298233760807595217-...`というファイル名は、Step 3-4で確認したスナップショットIDと一致しているはずです。

### 4-2. テーブルの中身を確認する

引き続きLXC上のシェルで、対話的にSparkシェルを起動して確認します。Step 3-3で設定した環境変数(`AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY`、`AWS_REGION`、`BUCKET_NAME`)がまだ有効な同じシェルセッションで実行してください。

```bash
docker run --rm -it \
  --security-opt apparmor=unconfined \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e AWS_REGION \
  -e BUCKET_NAME \
  amazon/aws-glue-libs:5 \
  pyspark \
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
  --conf spark.sql.catalog.local=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.local.type=hadoop \
  --conf spark.sql.catalog.local.warehouse=s3a://$BUCKET_NAME/warehouse
```

![Fig: PySparkシェルの起動画面(環境変数の値は黒塗り済み)](/images/20260905_03_4-2_pyspark-shell-start.png)

`>>> `という対話プロンプトが表示されれば起動成功です。以下を実行します。

```python
spark.sql("SELECT * FROM local.db.transactions ORDER BY transaction_date").show(truncate=False)
```

`customer_id`列が存在せず、代わりに`customer_id_hash`列にハッシュ値が入っていることを確認してください。**同じ`customer_id`(例: `CUST-00001`)を持つ複数行が、同じハッシュ値になっている**ことも確認してください。これは、第2回で選んだ「ハッシュ化(同じ入力→同じ出力)」が正しく機能している証拠です。実際の出力(先頭数行を抜粋)は以下のようになります。

```
+--------------+----------------+----------+-----------+----------------+----------------------------------------------------------------+
|transaction_id|transaction_date|amount    |branch_code|transaction_type|customer_id_hash                                                 |
+--------------+----------------+----------+-----------+----------------+----------------------------------------------------------------+
|TXN-000047    |2026-01-01      |241062.00 |001        |振込            |1e686ce644aafd4b64cfb7a3e3a735b5ee08fc1c662878dd99c7d90bedc48325 |
|TXN-000061    |2026-01-01      |1918443.00|003        |入金            |20cb407d4c7962a0dd12a2e63ddfd2e4ee3f79bb6e10a592dedcad9a8bcc3372 |
...(中略)...
|TXN-000092    |2026-01-02      |1736850.00|002        |入金            |13383a0ec50eac34fec18738858253c71621ebe8bb7a12a2f0f00c392394dc0c|
|TXN-000139    |2026-01-02      |89025.00  |004        |振込            |3cd7c4f29cce4b2290923926fbd4733bb0f080c26b1db6ebf89d391b831ce92c|
|TXN-000282    |2026-01-02      |1031601.00|002        |入金            |14fa3e31297e1b8e72d6a0124c9507e3cda3b4cc4dd888bca590f71b9d6163ed|
|TXN-000314    |2026-01-02      |2957332.00|003        |入金            |13383a0ec50eac34fec18738858253c71621ebe8bb7a12a2f0f00c392394dc0c|
+--------------+----------------+----------+-----------+----------------+----------------------------------------------------------------+
```

**`TXN-000092`と`TXN-000314`(いずれも`2026-01-02`)の`customer_id_hash`が、両方とも`13383a0ec50eac...`で完全に一致しています。** これが、同じ顧客が複数回取引した際に、同じハッシュ値になっている実例です。`amount`が`241062.00`のように小数点付きで表示されている点も、Step 2-3で明示的スキーマ定義(`DecimalType(15,2)`)を適用した効果です(`inferSchema`のままなら整数表示になっていたはずです)。

今回は50名の顧客に対して500件のデータを生成しているため、以下のクエリで**「同じ顧客は必ず同じハッシュ値になっているか」を集計で確認**できます。

```python
spark.sql("""
    SELECT customer_id_hash, COUNT(*) AS txn_count
    FROM local.db.transactions
    GROUP BY customer_id_hash
    ORDER BY txn_count DESC
    LIMIT 10
""").show(truncate=False)
```

```
+----------------------------------------------------------------+---------+
|customer_id_hash                                                |txn_count|
+----------------------------------------------------------------+---------+
|95b83476e10608ac8733f5d5f42376e3f9127f6c8c81013bac674d910dec74f6|15       |
|113318d7914dff70dc5a496cdf57c4fe65257c1210ccc99195b741d755de56ae|15       |
|a3de36407cdc61582528c25e7d3b07473a33854c1c225019a576df1de1ffed99|14       |
...(中略、上位10件を表示)...
+----------------------------------------------------------------+---------+
```

上位の件数(`15, 15, 14...`)が、**Step 1で`Import-Csv | Group-Object`によって実際にご自身で確認した、顧客ごとの取引件数の分布と一致しているはずです。** `customer_id_hash`ごとの件数を合計すると500件になり、かつ**ユニークなハッシュ値の数がちょうど50件になっている**はずです。これが確認できれば、「異なる顧客が同じハッシュ値になってしまう(衝突)」「同じ顧客なのに毎回違うハッシュ値になってしまう(ソルトの不整合)」のどちらも起きていない、という証拠になります。

```python
spark.sql("SELECT COUNT(DISTINCT customer_id_hash) AS unique_customers FROM local.db.transactions").show()
```

```
+----------------+
|unique_customers|
+----------------+
|              50|
+----------------+
```

`unique_customers`が`50`と表示され、実際のダミーデータの顧客数と完全に一致しました。

```python
spark.sql("SELECT * FROM local.db.transactions.snapshots").show(truncate=False)
```

こちらでは、今回の書き込みで作られたスナップショット(コミット履歴)を確認できます。**このスナップショット一覧こそが、第4回で扱うタイムトラベルの土台になります。**

> 📎 **FISC安全対策基準との対応**:今回実装したマスキング処理(ソルトの環境変数化)は、第1回・第2回で整理した「実務基準(情報の保護)」の実装にあたります。また、スナップショットという形で書き込み履歴が自動的に残ることは、「監査基準(証跡の確保)」の技術的な裏付けになります。

## この回のまとめ

- `customer_id`のマスキングを、**ソルトをハードコードしない形で**実装し、**ソルト自体の生成・保管・使い回し方**まで明記した
- **固定シードで再現可能な500件・60日・50顧客分のダミーデータ**を用意し、パーティション設計・マスキングの効果が確認できる規模にした
- Icebergテーブルを、**Hadoopカタログ・パーティション設計込みで**PySparkから作成した
- `docker run`時にも、**`AWS_PROFILE`を明示して最小権限ユーザーとして実行する**という一貫した権限分離を維持した
- Windows PC(認証情報の発行元)とLXC(Dockerの実行環境)が別のマシンであることを踏まえ、**`aws configure export-credentials`で必要な認証情報だけを最小限のコピーとしてLXCに払い出す**方式を採用した
- LXC側でも**rootを初期設定専用にとどめ、日常操作は非rootの運用ユーザー(`etl-operator`)に分離**した。ただし「dockerグループ所属 = 実質root相当」というDockerの構造的な限界は正直に明記し、完全な解決(rootless Docker等)は第5回に送った
- 書き込み後のスナップショットを確認し、**第4回のタイムトラベル演習への橋渡し**とした

## 次回予告

第4回では、今回作成したテーブルに対して**わざと誤ったデータで上書きし、タイムトラベル機能を使って復旧する**という、実務でありがちな障害対応シナリオを再現します。今回確認したスナップショット一覧が、まさにその復旧の手がかりになります。
