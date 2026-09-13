---
title: "GuardDuty × EventBridge × Lambdaで組む、Organizationsクロスアカウント自動封じ込め ― 構築・検証編"
emoji: "🔧"
type: "tech"
topics: ["aws", "security", "guardduty", "lambda", "eventbridge"]
published: false
---

## この記事について

[設計編](#)で組んだ構成を、実際にCLIで一から構築し、検証した記録。設計判断や本番運用時の考察は設計編にまとめてあるので、この記事は「実際に何を打って、何が起きたか」を、手順として再現できる粒度で書く。

この記事は、次のような人を読者として想定している。

- 同じ構成を自分の検証環境で再現したいエンジニア
- GuardDuty・Organizations・IAMのクロスアカウント連携を初めて触る人
- 「設計は分かったが、実際どう作るのか」を知りたい人

コマンドは実際に実行した順番のまま載せている。詰まった箇所は「なぜ失敗したか」まで書いているので、同じ場所でつまずいても原因が分かるようにしてある。

### 構成のおさらい

- **Account A(111111111111)**: Organizations管理アカウント。GuardDutyのメンバーにも委任管理者にもしない
- **Account B(222222222222)**: GuardDuty委任管理者 兼 セキュリティ運用アカウント
- **Account C(333333333333)**: GuardDutyメンバー 兼 本番アカウント役。Findingを発生させ、封じ込めの対象になる

```
[Account C: 本番役]
  └─ GuardDuty Finding発生
       ↓ (自動集約)
[Account B: セキュリティ運用]
  ├─ GuardDuty(委任管理者、Cのメンバー含めて閲覧)
  ├─ EventBridge(Findingを捕捉、severity>=7でフィルタ)
  ├─ Lambda(AssumeRoleでC側を操作、封じ込め実行)
  └─ SNS(重大度High/Critical通知)

[Account A: 管理アカウント]
  └─ 委任管理者の登録操作にのみ関与。監視・封じ込め対象には含めない
```

### この記事での作業ルール

- **実行はCLI、コンソールは結果確認のみ**とする。理由は、コマンドと結果を両方テキストで残せるので、後から見返したときに再現性が高いため
- 作業中は**常に`aws sts get-caller-identity`で「今どのアカウントとして動いているか」を確認してから次のコマンドを打つ**。これを徹底していれば、環境変数のクリア・再設定は「本当に別アカウントへ切り替えるとき」だけでよい
- メンバーアカウント同士(B↔C)は直接AssumeRoleできない。**必ずAccount Aの認証情報に戻ってから**、目的のアカウントへAssumeRoleし直す(詳細はPart 3で説明する)

前提として、リージョンは全ステップで統一する(この記事ではap-northeast-1)。GuardDutyはリージョナルサービスのため、リージョンが揃っていないと集約もEventBridgeも機能しない。

---

## Part 0: アカウントの準備

### Organizationsの現状を確認する

作業を始める前に、Account AでOrganizationsコンソールを開き、現在の組織構造を確認しておく。

![Organizationsコンソールで組織構造を確認。管理アカウントとメンバーアカウントの一覧が見える](/images/organizations-console-overview0.png)

この画面で、既存のメンバーアカウント・OU構成を把握してから進める。今回は新たにAccount B・Cを作成するところから始める。

### Account B・Cの新規作成

Organizationsの管理アカウント(Account A)から`create-account`を実行すると、通常のAWSサインアップと違って**電話番号認証・クレジットカード登録が不要**でメンバーアカウントを作成できる。

```bash
# Account Aの認証情報で実行
aws organizations create-account \
  --email "<your-address>+secops@gmail.com" \
  --account-name "security-ops-account"

aws organizations create-account \
  --email "<your-address>+prodsim@gmail.com" \
  --account-name "prod-sim-account"
```

![Organizationsコンソールで組織構造を確認。管理アカウントとメンバーアカウントの一覧が見える](/images/organizations-console-overview.png)

**ここでハマった話**: 最初、上記のメールアドレスを別の適当な文字列で試したところ`EMAIL_ALREADY_EXISTS`で失敗した。

![EMAIL_ALREADY_EXISTSで失敗した様子](/images/pre-01-email-already-exists.png)

AWSアカウントに紐づくメールアドレスは**AWS全体でユニーク**である必要があり、既に別のAWSアカウントに使われているアドレスは使えない。Gmailなら`アドレス+任意の文字列@gmail.com`というプラスエイリアス機能を使うと、実質1つのGmailアカウントから複数のユニークなメールアドレスを作れる。確認メールなどは元のアドレス(`+`より前の部分)の受信箱にそのまま届く。

修正して再実行すると成功した。

![プラスエイリアスを使ってAccount B・Cの作成に成功した様子](/images/pre-02-account-created-success.png)

`create-account`は非同期処理なので、返ってきた`CreateAccountRequestId`を使ってポーリングする。

```bash
aws organizations describe-create-account-status \
  --create-account-request-id <request-id>
```

`"State": "SUCCEEDED"`になったら、レスポンスの`AccountId`を控える。この記事では以下の通りとする(実際の値は伏せ字にしている)。

- Account B: `222222222222`
- Account C: `333333333333`

### アクセスできるか確認する

作成したメンバーアカウントには、デフォルトで`OrganizationAccountAccessRole`というロールが作られており、管理アカウント(Account A)からこのロールにAssumeRoleすることでアクセスできる。

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::222222222222:role/OrganizationAccountAccessRole \
  --role-session-name verify-access

aws sts assume-role \
  --role-arn arn:aws:iam::333333333333:role/OrganizationAccountAccessRole \
  --role-session-name verify-access
```

**確認項目**:
- レスポンスに`Credentials`(AccessKeyId・SecretAccessKey・SessionToken・Expiration)が返ってくること。失敗時はこのブロック自体が存在せず、代わりにエラーメッセージが返る
- `AssumedRoleUser.Arn`に含まれるアカウントIDが、意図したアカウント(BまたはC)と一致していること

### PowerShellでの認証情報の切り替え方

この記事ではWindows PowerShellで作業している。アカウントを切り替える基本パターンは以下の通り。

```powershell
$creds = aws sts assume-role `
  --role-arn arn:aws:iam::<切り替え先のアカウントID>:role/OrganizationAccountAccessRole `
  --role-session-name <セッション名(任意)> | ConvertFrom-Json

$env:AWS_ACCESS_KEY_ID = $creds.Credentials.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $creds.Credentials.SecretAccessKey
$env:AWS_SESSION_TOKEN = $creds.Credentials.SessionToken

aws sts get-caller-identity
```

最後の`get-caller-identity`で、意図したアカウントに切り替わっているかを必ず確認する。

**補足: コンソール(GUI)でアカウントを切り替える場合**

この記事の作業ルールは「実行はCLI」だが、結果確認でコンソールを開く際も、同じ`OrganizationAccountAccessRole`を使ってロールを切り替えられる。コンソール右上のアカウント名 →「ロールを切り替え」から、アカウントIDとロール名を入力するだけでよい。

![コンソールでのロール切り替えダイアログ](/images/ops-03-switch-role-dialog.png)

**ハマった話1: メンバーアカウント同士は直接AssumeRoleできない**

Account CからAccount Bへ直接AssumeRoleしようとして失敗した。

```
AssumeRole operation: User: arn:aws:sts::333333333333:assumed-role/.../xxx
is not authorized to perform: sts:AssumeRole on resource:
arn:aws:iam::222222222222:role/OrganizationAccountAccessRole
```

![Account CからAccount Bへ直接AssumeRoleしようとして失敗した様子](/images/part3-01-chain-assumerole-failure.png)

`OrganizationAccountAccessRole`の信頼ポリシーは、デフォルトでOrganizations管理アカウント(Account A)のみをPrincipalとして許可している。メンバーアカウント同士(B↔C)を直接渡り歩くことはできず、**必ずAccount Aの認証情報を経由してAssumeRoleし直す**必要がある。

![一度Account Aの認証情報に戻ったことを確認する様子](/images/ops-02-back-to-account-a.png)

**ハマった話2: STSトークンの有効期限切れ**

作業が長引くと、取得した一時認証情報が期限切れになる。

![ExpiredTokenエラーの発生例](/images/ops-04-expiredtoken-error.png)

`ExpiredToken`が出たら、Account Aの認証情報からもう一度AssumeRoleし直せばよい。

---

## Part 1: 委任管理者の設定とメンバー登録

GuardDutyのマルチアカウント運用は、「委任管理者(delegated administrator)」というアカウントが、他のアカウント(メンバー)のFindingを集約して閲覧できる仕組みになっている。

### なぜ委任管理者をAccount Aにしないのか

AWSの一般的なガイダンスでは、GuardDutyの委任管理者をOrganizationsの管理アカウント自身にすることは推奨されていない。管理アカウントにはセキュリティサービスの管理権限以外を極力持たせない方が、影響範囲を限定できるためだ。一方、管理アカウント自体をGuardDutyの「メンバー」として組み込むことは正式にサポートされた構成であり、条件は事前にそのアカウントでGuardDutyを有効化しておくことだけだった(この点は最初の検証(2アカウント構成)で実機確認済み)。

今回はAccount Aを一切GuardDutyに関与させず、Account Bを委任管理者に、Account Cをメンバーに据える。

### 委任管理者を登録する

```bash
# Account Aの認証情報で実行
aws organizations enable-aws-service-access \
  --service-principal guardduty.amazonaws.com

aws guardduty enable-organization-admin-account \
  --admin-account-id 222222222222
```

両方とも成功時は空のレスポンスを返す仕様なので、エラーメッセージが表示されなければ成功と判断してよい。

この2つは役割が違う。`enable-aws-service-access`は、Organizationsが持つアカウント一覧をGuardDuty側から参照できるようにする設定で、これを実行した時点で、まだGuardDutyを有効化していないアカウントも含め、組織内の全アカウントがGuardDutyの管理画面に「メンバーではない」というステータスで並ぶようになる。`enable-organization-admin-account`のほうは、そのうちの1つを委任管理者として指名する操作になる。

![enable-organization-admin-accountが成功した様子(空レスポンス)](/images/part1-02b-enable-admin-account-blank-success.png)

### Account B側でGuardDutyが自動有効化されているか確認する

事前にドキュメントを読んだ時点では「各アカウントで個別にGuardDutyを有効化してから委任管理者・メンバー登録をする」つもりだったが、実際には**委任管理者登録の操作だけで、Account B自身のGuardDutyが自動的に有効化される**仕様だった。

```bash
# Account Bの認証情報で実行
aws guardduty list-detectors
```

![委任管理者登録だけでAccount B側のGuardDutyが自動有効化されている(list-detectors)](/images/part1-01-guardduty-auto-enabled.png)

検出器IDが1件返ってくれば、手動での`create-detector`は不要ということになる。もし返ってこない場合は、以下で手動作成する。

```bash
aws guardduty create-detector --enable
```

検出器はリージョンごとに作られる。以降のGuardDutyのCLI操作はすべてこの検出器IDを引数に取るので、Account B・C双方のIDを控えておく。別リージョンで同じ構成を組む場合は、そのリージョンで改めて検出器IDを取得することになる。

### Account CをGuardDutyメンバーとして追加する

```bash
# Account Bの認証情報で実行
aws guardduty create-members \
  --detector-id <Account_Bの検出器ID> \
  --account-details AccountId=333333333333,Email=<your-address>+prodsim@gmail.com
```

![create-membersがUnprocessedAccounts: []で成功](/images/part1-02-create-members-success.png)

`UnprocessedAccounts`が空配列(`[]`)であれば成功。失敗した場合はここに`AccountId`と`Result`(エラー理由)が入った要素が返ってくる。

### Account C側もGuardDutyが自動有効化されているか確認する

```bash
# Account Cの認証情報で実行
aws guardduty list-detectors
```

![Account C側でも検出器IDが自動的に返ってくる](/images/part1-04-account-c-detector-confirmed.png)

メンバーとして追加された時点で、Account C側もGuardDutyが自動有効化される。こちらも手動での`create-detector`は不要だった。

### 集約を実機で確認する(要件4)

ここまでで設定は完了しているはずだが、本当にFindingが集約されるのかを実際に確認する。

```bash
# Account Cの認証情報で実行
aws guardduty create-sample-findings --detector-id <Account_Cの検出器ID>
```

```bash
# Account Bの認証情報で実行
aws guardduty list-findings --detector-id <Account_Bの検出器ID>
```

![Account B側のlist-findingsに、Account Cで発生させたFindingが並んで返ってくる](/images/part1-05-list-findings-long.png)

Finding IDの一覧が返ってくるだけでは「本当にAccount C由来か」までは分からないので、1件の中身を見て`AccountId`フィールドを直接確認する。

```bash
aws guardduty get-findings \
  --detector-id <Account_Bの検出器ID> \
  --finding-ids <FindingId> \
  --query "Findings[0].AccountId"
```

![get-findingsでAccountIdがAccount C(333333333333)と確認できた](/images/part1-03-finding-accountid-verified.png)

`333333333333`(Account C)が返ってくれば、要件4(検出結果をすべてセキュリティ運用アカウントへ集める)の実機確認が取れたことになる。

コンソールで見ると、GuardDutyのアカウント一覧にAccount Cが「有効なメンバー」として表示される。

![GuardDutyのアカウント一覧。Account Cが有効なメンバーとして表示されている](/images/05-guardduty-accounts.png)

---

## Part 2: クロスアカウントの封じ込め用IAMロールを作る

封じ込めLambdaはAccount B(セキュリティ運用)側に置き、Account C(本番役)側のリソースを操作する。これを安全に行うために、2段階の信頼関係を持つIAMロールを作る。

### ファイル名は所属アカウントが分かるようにする

信頼ポリシーのJSONファイルを`trust-policy.json`という汎用的な名前で作り始めたところ、**ファイルの中身自体には「どのアカウントに配置するものか」という情報が一切含まれていない**ことに気づいた。AWSにどのアカウントのロールとして登録されるかは、コマンド実行時の認証情報のコンテキストで決まるのであって、ファイル名やファイルの中身には現れない。

対策として、ファイル名に`account-b-`・`account-c-`のプレフィックスを付け、さらにIAMポリシーの`Sid`フィールドに人が読んで分かる説明を入れることにした。`Sid`は正式なIAM構文で、コンソールの表示にも反映される。

ファイルを作成したら、`Get-Content`で中身を確認してからコマンドを実行する習慣をつけた。

![Get-Contentでtrust-policy.json・permission-policy.jsonの中身を確認](/images/part2-02-get-content-json-files.png)

### 作成順序を間違えて失敗した話

最初、Account C側の封じ込め用ロールから作ろうとした。

```
aws iam create-role \
  --role-name SecurityOpsContainmentRole \
  --assume-role-policy-document file://trust-policy.json

→ MalformedPolicyDocument: Invalid principal in policy:
  "AWS":"arn:aws:iam::222222222222:role/GuardDutyContainmentLambdaRole"
```

![MalformedPolicyDocumentエラーが発生した様子](/images/part2-01-malformed-policy-error.png)

原因は単純で、信頼ポリシーの`Principal`に指定したAccount B側のロールが、その時点でまだ存在していなかったこと。IAMはロール作成時に、信頼ポリシーで参照しているPrincipalの実在性をその場でチェックする。**信頼される側(Account BのLambda実行ロール)を先に作ってから、信頼する側(Account Cのロール)を作る**必要がある。

### 権限ポリシーは通るのに、信頼ポリシーは弾かれる

同じIAMポリシーでも、`Resource`に書いたARNと`Principal`に書いたARNでは扱いが違う。

- **権限ポリシーの`Resource`は実在チェックされない**。単なる文字列として保存される。この後Account B側に付ける権限ポリシーには`arn:aws:iam::333333333333:role/SecurityOpsContainmentRole`と書くが、この時点でAccount C側にそのロールは存在しない。それでも`put-role-policy`は成功する
- **信頼ポリシーの`Principal`は実在チェックされる**。「誰を信頼するか」の宣言なので、存在しない相手は登録させない。実在しないARNを書けば`MalformedPolicyDocument`で弾かれる

この非対称性を踏まえると、手動で組む場合の順序は3ステップに整理できる。

1. **実体が必要**: Account BにLambda実行ロールを作る
2. **実体が必要**: 1が実在するので、それを`Principal`に指定したAccount C側のロールを作れる
3. **文字列でよい**: Account Bのロールに、Account C側のロールをAssumeRoleする権限ポリシーを付ける

3は`Resource`が実在チェックされないため、1と2の間に入れても通る。今回は実際に1 → 3 → 2の順で実行した。順序を気にせず進めたいなら1 → 2 → 3が安全側になる。いずれにせよ、絶対に入れ替えられないのは1と2の関係で、ここだけは崩せない。

なお、Terraformのようなツールでコード化する場合、この依存関係は参照関係から自動的に解決されるので、人間が順番を計算する必要はなくなる。

### 正しい順序: まずAccount B側にLambda実行ロールを作る

**`account-b-lambda-trust-policy.json`**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowLambdaServiceToAssumeThisAccountBRole",
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**`account-b-lambda-permission-policy.json`**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudWatchLogsForThisLambda",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:*:222222222222:*"
    },
    {
      "Sid": "AllowAssumingAccountCContainmentRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::333333333333:role/SecurityOpsContainmentRole"
    },
    {
      "Sid": "AllowPublishingToThisAccountBAlertTopic",
      "Effect": "Allow",
      "Action": "sns:Publish",
      "Resource": "arn:aws:sns:*:222222222222:guardduty-high-severity-alerts"
    }
  ]
}
```

```bash
# Account Bの認証情報で実行
aws iam create-role \
  --role-name GuardDutyContainmentLambdaRole \
  --assume-role-policy-document file://account-b-lambda-trust-policy.json
```

![GuardDutyContainmentLambdaRoleの作成に成功](/images/part3-02-lambda-role-created-success.png)

```bash
aws iam put-role-policy \
  --role-name GuardDutyContainmentLambdaRole \
  --policy-name lambda-permissions \
  --policy-document file://account-b-lambda-permission-policy.json
```

![put-role-policyが成功した様子](/images/part3-03-lambda-role-putpolicy-success.png)

`put-role-policy`は成功時に空レスポンスを返す仕様なので、エラーが出なければ完了。コンソールで確認すると、ロールに`lambda-permissions`というインラインポリシーが1件付いている。

![GuardDutyContainmentLambdaRoleのロール概要(コンソール)](/images/part3-05-lambda-role-overview-gui.png)

「リソースの概要」タブでは、まだLambdaが一度も実行されていない段階ではCloudWatch Logsの権限しか表示されないことがある。これはコンソールのUIがCloudTrailの実行履歴を元に表示を補強しているためで、`sts:AssumeRole`や`sns:Publish`の権限自体は正しく設定されている(付与したポリシーのJSON自体は「許可」タブでいつでも確認できる)。

![リソースの概要タブ。実行前はCloudWatch Logsの権限しか表示されないことがある](/images/part3-04-lambda-role-resource-overview-gui.png)

### Account C側に封じ込め用ロールを作る

Account BのLambda実行ロールが存在する状態になったので、Account C側のロールを安全に作れる。

**`account-c-trust-policy.json`**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAccountBContainmentLambdaToAssumeThisAccountCRole",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::222222222222:role/GuardDutyContainmentLambdaRole" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "sts:ExternalId": "guardduty-containment-verify" }
      }
    }
  ]
}
```

`sts:ExternalId`は、Principalが正しくても合言葉を一緒に提示しないとAssumeRoleを許可しない、という追加の防御。今回は同じ所有者が管理する2アカウント間なので必須ではないが、将来的に外部のセキュリティベンダーに監視・対応を委託するような構成に発展した場合、この合言葉がないと「別の顧客のふりをして誤って侵入する」という事故(confused deputy問題)を防げない。今のうちから習慣化しておく意図で組み込んだ。

**`account-c-permission-policy.json`**(最小権限。テスト用ユーザー1人に限定):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowDisablingOnlyTheTestContainmentTargetKey",
      "Effect": "Allow",
      "Action": ["iam:UpdateAccessKey", "iam:ListAccessKeys"],
      "Resource": "arn:aws:iam::333333333333:user/test-containment-target"
    }
  ]
}
```

Resourceをワイルドカード(`user/*`)にせず特定の1ユーザーに絞ったのは、自動封じ込めが誤作動した場合の影響範囲(ブラストラディウス)を最小化するため。この判断は後述するPart 5で、実際に効果を発揮することになる。

```bash
# Account Cの認証情報で実行
aws iam create-role \
  --role-name SecurityOpsContainmentRole \
  --assume-role-policy-document file://account-c-trust-policy.json

aws iam put-role-policy \
  --role-name SecurityOpsContainmentRole \
  --policy-name containment-permissions \
  --policy-document file://account-c-permission-policy.json

# テスト対象のIAMユーザーも作っておく(アクセスキーも発行)
aws iam create-user --user-name test-containment-target
aws iam create-access-key --user-name test-containment-target
```

今回はエラーなく成功した。コンソールで確認すると、`Sid`を含む信頼ポリシーがそのまま信頼関係タブに表示される。

![SecurityOpsContainmentRoleの信頼関係。Sidを含む信頼ポリシーがそのまま表示されている](/images/01-securityops-role-trust-relationship.png)

ロールの概要タブでは、ARNや作成日時、最終アクティビティなども確認できる。

![SecurityOpsContainmentRoleの概要画面(コンソール)](/images/part4-02-account-c-role-overview-gui.png)

**確認項目**:
- `create-access-key`のレスポンスに`AccessKeyId`・`SecretAccessKey`・`Status: Active`が返ってくること
- 作成直後のアクセスキーの状態はもちろん`Active`

![test-containment-targetのアクセスキーがActive(封じ込め前の初期状態)](/images/part5-09-access-key-active-before-containment.png)

### Sidをあとから追加した話

実は、Account B側の`GuardDutyContainmentLambdaRole`は、`Sid`を導入する前に一度作ってしまっていた。中身は同じだが、コンソールで見比べたときに手順書のJSON(Sidあり)と実際のポリシー(Sidなし)が食い違って見えるのを避けるため、`put-role-policy`で同じ内容にSidを追加したバージョンに上書きした。

```bash
aws iam put-role-policy \
  --role-name GuardDutyContainmentLambdaRole \
  --policy-name lambda-permissions \
  --policy-document file://account-b-lambda-permission-policy.json
```

![put-role-policyでSid付きポリシーに上書きし、成功した様子](/images/part2-03-putrolepolicy-sid-update-success.png)

IAMのロールは、既存のインラインポリシー名(`lambda-permissions`)を指定して`put-role-policy`を再実行すると、中身がそのまま上書きされる。ロールを作り直す必要はない。

---

## Part 3: SNSトピックを作る

Lambda(Part 4で作る)が重大度の高いFindingを検知したときに通知する先として、先にSNSトピックを作っておく。Lambdaの環境変数として、このトピックのARNを渡す必要があるため、Lambdaより先に作る。

```bash
# Account Bの認証情報で実行
aws sns create-topic --name guardduty-high-severity-alerts
```

レスポンスの`TopicArn`を控える。

### サブスクリプションを登録する

通知の宛先としてメールアドレスを登録する。`--topic-arn`には`create-topic`のレスポンスで返ってきた`TopicArn`を指定する。

```bash
aws sns subscribe \
  --topic-arn "<create-topicで返ってきたTopicArn>" \
  --protocol email \
  --notification-endpoint "<your-address>+secops@gmail.com"
```

![subscribeが成功し、SubscriptionArnがpending confirmationで返ってきた様子](/images/part5-06-sns-subscribe-success.png)

`"SubscriptionArn": "pending confirmation"`はエラーではなく、メール確認待ちの正常な状態。届いた確認メールの「Confirm subscription」リンクをクリックすると購読が有効になる。ここだけはAWSにAPIが存在しないため、唯一の手作業になる。

![Subscription confirmedのWebページが表示された様子](/images/part5-07-sns-subscription-confirmed-page.png)

CLIでも購読状態を確認できる。

```bash
aws sns list-subscriptions-by-topic --topic-arn "<TopicArn>"
```

![list-subscriptions-by-topicでSubscriptionArnが実際のARN形式になっていることを確認](/images/part5-08-sns-list-subscriptions-confirmed.png)

`SubscriptionArn`が`pending confirmation`ではなく、実際のARN形式(末尾にUUID)になっていれば購読完了。コンソールでも確認できる。

![SNSトピックのサブスクリプションが確認済みになっている](/images/06-sns-topic-subscription.png)

**余談: メール内リンクの自動先読みについて**

確認メールの画面には「click here to unsubscribe」というリンクが常に表示されている。SNSの確認・解除リンクはどちらも単純なGETリクエストで処理される仕様なので、メールセキュリティ製品によるリンクの自動スキャン(先読みアクセス)が原因で、意図せず購読解除されることがあるとされている。今回は発生しなかったが、実運用でSNSメール通知を使う場合の落とし穴として知っておく価値がある。対策としては、Slack Webhookなど、GETリクエストだけで状態変更しないプロトコルを使う方法もある。

---

## Part 4: 封じ込めLambda関数を作る

### Lambdaのコード

```python
import boto3
import os
import json

STS = boto3.client("sts")
SNS = boto3.client("sns")

TARGET_ACCOUNT_ID = os.environ["TARGET_ACCOUNT_ID"]  # Account CのID
CONTAINMENT_ROLE_NAME = "SecurityOpsContainmentRole"
EXTERNAL_ID = "guardduty-containment-verify"
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

def lambda_handler(event, context):
    detail = event["detail"]
    finding_type = detail["type"]
    severity = detail["severity"]
    title = detail.get("title", "")
    account_id = detail["accountId"]

    # Account Cへスイッチ
    assumed = STS.assume_role(
        RoleArn=f"arn:aws:iam::{TARGET_ACCOUNT_ID}:role/{CONTAINMENT_ROLE_NAME}",
        RoleSessionName="guardduty-containment",
        ExternalId=EXTERNAL_ID,
    )
    creds = assumed["Credentials"]
    iam_c = boto3.client(
        "iam",
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )

    action_taken = "none"
    if "UnauthorizedAccess:IAMUser" in finding_type or "AccessKey" in finding_type:
        access_key_id = detail["resource"]["accessKeyDetails"]["accessKeyId"]
        user_name = detail["resource"]["accessKeyDetails"]["userName"]
        iam_c.update_access_key(
            AccessKeyId=access_key_id,
            Status="Inactive",
            UserName=user_name,
        )
        action_taken = f"disabled access key {access_key_id} for user {user_name}"

    message = {
        "findingType": finding_type,
        "severity": severity,
        "title": title,
        "sourceAccount": account_id,
        "actionTaken": action_taken,
    }
    SNS.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[GuardDuty] {finding_type} (severity={severity})",
        Message=json.dumps(message, ensure_ascii=False, indent=2),
    )

    return {"statusCode": 200, "body": json.dumps(message, ensure_ascii=False)}
```

`iam_c.update_access_key`の前段で、`finding_type`にIAMユーザーやアクセスキーに関連する文字列が含まれているかをチェックしている。それ以外のFindingタイプは`action_taken: "none"`のまま安全に素通りする(この設計が、後述のサンプルFinding大量生成のときに効いてくる)。

:::details コードの詳細解説

処理を5つのフェーズに分けて見ていく。

**1. 準備: クライアントと設定値**

```python
STS = boto3.client("sts")
SNS = boto3.client("sns")

TARGET_ACCOUNT_ID = os.environ["TARGET_ACCOUNT_ID"]  # Account CのID
CONTAINMENT_ROLE_NAME = "SecurityOpsContainmentRole"
EXTERNAL_ID = "guardduty-containment-verify"
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
```

モジュールの先頭で作るクライアントは2つ。認証情報を切り替えるためのSTSと、通知を送るためのSNS。どちらもこの時点ではAccount B側のコンテキストで動く。

設定値の扱いは意図的に分けている。Account CのアカウントIDとSNSトピックのARNは環境変数から読む。コードを書き換えずに宛先を差し替えられるので、同じzipを別環境でも使い回せる。一方、封じ込め先のロール名とExternalIdはコードに直書きにした。環境ごとに変える想定がないうえ、外から差し替えられるということは封じ込め先を付け替えられるということでもあるためだ。

**2. 受付: Findingの解析**

```python
def lambda_handler(event, context):
    detail = event["detail"]
    finding_type = detail["type"]
    severity = detail["severity"]
    title = detail.get("title", "")
    account_id = detail["accountId"]
```

`event`には、EventBridge経由でGuardDutyのFindingがそのまま入ってくる。必要な情報は`detail`の下にあり、ここではFindingタイプ、重大度、タイトル、発生元のアカウントIDを取り出している。

`title`だけ`get()`でデフォルト値を用意しているのは、Findingタイプによって存在しない場合があるため。他の4つは必須フィールドとして直接参照している。

**3. 越境: Account CへのAssumeRole**

```python
    assumed = STS.assume_role(
        RoleArn=f"arn:aws:iam::{TARGET_ACCOUNT_ID}:role/{CONTAINMENT_ROLE_NAME}",
        RoleSessionName="guardduty-containment",
        ExternalId=EXTERNAL_ID,
    )
    creds = assumed["Credentials"]
    iam_c = boto3.client(
        "iam",
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )
```

この構成の核心にあたる部分。

`assume_role`にExternalIdを添えて呼ぶと、Account C側の信頼ポリシーに書いた`Condition`と突き合わされ、一致したときだけ有効期限付きの一時認証情報が返る。Part 2で組んだ2段階の信頼構造が実際に効くのがここになる。

返ってきた`creds`で`boto3.client("iam")`を作り直している点が重要で、これ以降`iam_c`を使った操作はすべてAccount C側で実行される。一方、先頭で作った`STS`と`SNS`はAccount B側のままなので、フェーズ5の通知はAccount B側のトピックに飛ぶ。1つの関数の中で2つのアカウントのコンテキストが同時に生きていることになる。

`RoleSessionName`はAccount C側のCloudTrailに記録される。後からログを追うときに、この操作がどこから来たのかを名前で判別できるので、意味の分かる名前を付けておく。

**4. 封じ込め: アクセスキーの無効化**

```python
    action_taken = "none"
    if "UnauthorizedAccess:IAMUser" in finding_type or "AccessKey" in finding_type:
        access_key_id = detail["resource"]["accessKeyDetails"]["accessKeyId"]
        user_name = detail["resource"]["accessKeyDetails"]["userName"]
        iam_c.update_access_key(
            AccessKeyId=access_key_id,
            Status="Inactive",
            UserName=user_name,
        )
        action_taken = f"disabled access key {access_key_id} for user {user_name}"
```

`finding_type`で先に絞り込んでから、`detail.resource.accessKeyDetails`の下にあるアクセスキーIDとユーザー名を取り出す。

この分岐は「対象を選ぶ」以上の意味がある。`accessKeyDetails`はアクセスキー由来のFindingにしか存在しないため、絞らずに読みにいくと、他のタイプのFindingが届いた時点で`KeyError`になる。条件に合わないFindingは`action_taken`が`"none"`のまま通知だけが飛ぶ。

`update_access_key`で`Status="Inactive"`に変更するのがこの関数の本題にあたる。削除(`delete-access-key`)ではなく無効化を選んだのは、後から`Active`に戻せる可逆的な操作だからだ。人の確認を挟まずに動く処理で不可逆な操作を選ぶと、誤検知が起きたときに元に戻せなくなる。

**5. 報告: SNSへの通知**

```python
    message = {
        "findingType": finding_type,
        "severity": severity,
        "title": title,
        "sourceAccount": account_id,
        "actionTaken": action_taken,
    }
    SNS.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[GuardDuty] {finding_type} (severity={severity})",
        Message=json.dumps(message, ensure_ascii=False, indent=2),
    )
```

どのアカウントで何が起き、この関数が何をしたのかをJSONにまとめてSNSに送る。`actionTaken`を必ず含めているので、封じ込めが実行されたのか、条件に合わず素通りしたのかを、受け取った側が本文だけで判断できる。

`publish`は`update_access_key`の外側にあるため、封じ込めが実行されなかったFindingでも通知は届く。自動処理が「何もしなかった」ことを人間が把握できるようにするためで、黙って素通りさせない方がよい。

Subjectに`finding_type`と`severity`を入れているのは、メールの一覧画面で開かずに優先度を判断できるようにするため。SNSトピックの先をSlack連携(AWS Chatbot)に差し替えれば、同じ内容をチャンネルに流すこともできる。

:::

### Lambda関数を作成する

```bash
# ローカルでコードをzipにまとめる(PowerShellの例)
Compress-Archive -Path lambda_function.py -DestinationPath function.zip -Force

# Account Bの認証情報で実行
aws lambda create-function \
  --function-name guardduty-containment \
  --runtime python3.13 \
  --role arn:aws:iam::222222222222:role/GuardDutyContainmentLambdaRole \
  --handler lambda_function.lambda_handler \
  --zip-file fileb://function.zip \
  --environment "Variables={TARGET_ACCOUNT_ID=333333333333,SNS_TOPIC_ARN=<Part3で作成したトピックのARN>}"
```

![lambda create-functionが成功。Stateはまだ Pending](/images/part6-01-lambda-create-function-pending.png)

作成直後は`"State": "Pending"`(コードのプロビジョニング中)になっている。EventBridgeから起動する前に、`Active`になっているか確認しておく。

```bash
aws lambda get-function --function-name guardduty-containment --query "Configuration.State"
```

![lambda get-functionでStateがActiveになったことを確認](/images/part6-02-lambda-state-active.png)

`"Active"`が返ってくれば準備完了。

---

## Part 5: EventBridgeルールを作る

委任管理者アカウント(Account B)のデフォルトイベントバスには、メンバーアカウント(Account C)分も含めてGuardDutyのFindingイベントが自動的に集約される。**クロスアカウントのイベントバス許可設定は不要**というのがGuardDutyのマルチアカウント連携の便利な点だった。

### イベントパターン

重大度(severity)でフィルタする。すべてのFindingでLambdaを起動すると、低・中重大度の検出でも封じ込めが走ってしまう。人の確認を挟まずに動く処理である以上、自動で対応してよい範囲を先に絞っておく必要がある。ここでは`severity >= 7`(High以上)だけを通し、それ未満は人間の判断に回す前提にした。

```json
{
  "source": ["aws.guardduty"],
  "detail-type": ["GuardDuty Finding"],
  "detail": {
    "severity": [{ "numeric": [">=", 7] }]
  }
}
```

### ルールの作成とLambdaのターゲット設定

```bash
# Account Bの認証情報で実行
aws events put-rule \
  --name guardduty-high-severity-rule \
  --event-pattern file://event-pattern.json

aws events put-targets \
  --rule guardduty-high-severity-rule \
  --targets "Id=1,Arn=arn:aws:lambda:ap-northeast-1:222222222222:function:guardduty-containment"
```

CLIでEventBridgeルールにLambdaをターゲット設定する場合、コンソール操作と違って**EventBridgeからLambdaを起動する権限(リソースベースポリシー)を自分で付与する必要がある**。

```bash
aws lambda add-permission \
  --function-name guardduty-containment \
  --statement-id eventbridge-invoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn arn:aws:events:ap-northeast-1:222222222222:rule/guardduty-high-severity-rule
```

![put-rule・put-targets・add-permissionが順に成功した様子](/images/part4-01-eventbridge-lambda-cli-success.png)

これを忘れると、EventBridgeルールもLambda関数も正常に見えるのに、実際には起動しないという分かりにくい不具合になる。

### コンソールでの確認(結果確認のみ)

```
EventBridge → ルール → guardduty-high-severity-rule
```

![EventBridgeルールが有効な状態で登録されている](/images/03-eventbridge-rule-enabled.png)

```
Lambda → guardduty-containment → 設定 → トリガー
```

![Lambda関数のトリガー欄にEventBridgeルールが表示されている。これがadd-permissionの成功を示す](/images/04-lambda-trigger.png)

「トリガー」欄にEventBridgeルールが`ENABLED`で表示されていれば、`add-permission`が正しく効いている証拠になる。

---

## Part 6: 通しテストと、そこで見つかった落とし穴

ここまでで一通りの構成が組み上がった。いよいよ通しでテストする。

### サンプルFindingsは全種類が一括生成される

```bash
# Account Cの認証情報で実行
aws guardduty create-sample-findings --detector-id <Account_Cの検出器ID>
```

このコマンドは「1件のサンプルを試しに作る」ものだと思っていたが、実際には**対応する全Findingタイプ分が一括生成される**仕様だった。実行してみると、434件ものFindingが一度に生成された。

```bash
aws guardduty list-findings --detector-id <Account_Cの検出器ID> --query "length(FindingIds)"
```

![サンプルFindingが434件生成された(length(FindingIds))](/images/part5-01-sample-findings-434.png)

結果、EventBridgeのフィルタ条件(severity >= 7)を満たすFindingだけでも数十件が同時にマッチし、Lambdaが数十回起動、SNSメールも同数飛んだ。コスト面での実害はなかった(Lambda・SNS・EventBridgeいずれも無料枠の範囲内)が、想定外の量に驚いた。1件だけに絞りたい場合は`--finding-types`でFindingタイプを指定するとよい。

```bash
aws guardduty create-sample-findings \
  --detector-id <Account_Cの検出器ID> \
  --finding-types "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS"
```

### 封じ込め自体は動いたが、アクセスキーは無効化されなかった

CloudWatch Logsを確認すると、Lambdaは複数回正常に起動し、Account CへのAssumeRoleにも成功していた。ところが最後の`iam:UpdateAccessKey`でエラーになっていた。

```bash
aws logs tail /aws/lambda/guardduty-containment --since 30m
```

```
AccessDenied when calling the UpdateAccessKey operation:
User: arn:aws:sts::333333333333:assumed-role/SecurityOpsContainmentRole/guardduty-containment
is not authorized to perform: iam:UpdateAccessKey on resource: user GeneratedFindingUserName
```

![CloudWatch LogsでUpdateAccessKeyのAccessDeniedエラーを確認](/images/part5-02-updateaccesskey-accessdenied.png)

実際、Account C側でテスト用ユーザーのアクセスキーを見ても`Active`のままだった。

```bash
aws iam list-access-keys --user-name test-containment-target
```

一瞬「Lambdaにバグがあるのでは」と焦ったが、原因を調べると、GuardDutyのサンプルFindingが`accessKeyDetails.userName`に**実在しないダミー値**(`GeneratedFindingUserName`)を入れる仕様だったことが分かった。Part 2で書いた通り、封じ込め用のIAM権限は特定の1ユーザー(`test-containment-target`)だけに絞っていたため、このダミーユーザーへの操作は最小権限ポリシーによって正しく拒否された。**バグではなく、最小権限が意図通り機能した結果**だった。

言い換えると、GuardDutyのサンプルFinding機能は「検知〜通知までのパイプラインの配線確認」には使えるが、「実リソースに対する封じ込めアクションそのものの検証」には向いていない。

### 封じ込めロジック単体を検証する

そこで、GuardDutyを経由せず、実在するリソース識別子を含むテストイベントを自分で用意し、Lambdaを直接起動する方法に切り替えた。

```powershell
@'
{
  "detail": {
    "type": "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS",
    "severity": 8,
    "title": "Manual test event for containment verification",
    "accountId": "333333333333",
    "resource": {
      "accessKeyDetails": {
        "accessKeyId": "<test-containment-targetの実アクセスキーID>",
        "userName": "test-containment-target"
      }
    }
  }
}
'@ | Out-File -FilePath manual-invoke-containment-test-event.json -Encoding utf8
```

```bash
# Account Bの認証情報で実行
aws lambda invoke \
  --function-name guardduty-containment \
  --cli-binary-format raw-in-base64-out \
  --payload file://manual-invoke-containment-test-event.json \
  response.json
```

**ここでも1回失敗した**。認証情報がAccount Cのままになっていたため、Account Bにしか存在しないLambda関数が見つからないというエラーになった。

```
aws: [ERROR]: An error occurred (ResourceNotFoundException) when calling the Invoke operation:
Function not found: arn:aws:lambda:ap-northeast-1:333333333333:function:guardduty-containment:$LATEST
```

![Lambdaがない、と言われた(実は認証情報がAccount Cのままだった)](/images/part5-10-lambda-invoke-resourcenotfound-wrong-account.png)

Account Bに切り替え直して再実行すると成功した。

![lambda invokeが成功し、response.jsonにactionTakenが返ってきた様子](/images/part5-03-lambda-invoke-success.png)

`manual-invoke-containment-test-event.json`には、GuardDuty Findingの形式を模しつつ、`test-containment-target`ユーザーの実際のアクセスキーIDを含めた。結果、レスポンスに`"actionTaken": "disabled access key ... for user test-containment-target"`が返り、Account C側で確認すると、対象のアクセスキーが確かに`Inactive`になっていた。

```bash
# Account Cの認証情報で実行
aws iam list-access-keys --user-name test-containment-target
```

![list-access-keysでStatusがInactiveになっていることをCLIで確認](/images/part5-04-access-key-inactive-cli.png)

コンソールでも同じことが確認できる。

![test-containment-targetユーザーのアクセスキーがInactiveになっている。要件2(自動封じ込め)の実機での最終確認](/images/02-access-key-inactive.png)

要件2(自動封じ込め)を、GuardDutyのダミーデータの制約を切り分けた上で、最終的に実機で確認できた。

### 通しテストで確認できた連鎖

どこまでが自動で流れ、どこから手を入れたのかを整理しておく。

1. **GuardDutyがAccount Cの脅威を検知する** — サンプルFindingで確認
2. **EventBridgeが`severity >= 7`だけを拾い、Account BのLambdaを自動起動する** — CloudWatch Logsに複数回の起動を確認
3. **LambdaがExternalIdを添えてAccount Cの`SecurityOpsContainmentRole`をAssumeRoleする** — ログ上で成功を確認
4. **対象ユーザーのアクセスキーを`Inactive`にする** — サンプルFinding経由では実行されなかった。ダミーのユーザー名が最小権限ポリシーに拒否されたため。実在するアクセスキーIDを含むテストイベントでLambdaを直接起動して、`Inactive`への変更を確認した
5. **SNS経由で管理者に通知する** — サンプルFinding生成時に、条件を満たしたFinding数と同数のメールを受信

1から3まではサンプルFindingだけで通しで流れた。4だけは、サンプルFindingのダミーデータと最小権限ポリシーの組み合わせでは検証できないため、切り分けて別に確認している。5はサンプルFinding経由で確認できた。

なお、4を「サンプルFindingで通らないから権限を緩める」方向で解決するのは筋が悪い。緩めれば通るが、それは封じ込めの対象範囲を広げるということで、検証のために本番の安全性を下げることになる。対象を絞ったまま、テストデータの側を実データに寄せるほうが正しい。

---

## 検証結果まとめ

| 要件 | 確認方法 | 結果 |
|---|---|---|
| 1. 検知 | GuardDutyのFinding生成 | ○ |
| 2. 自動封じ込め | Lambda直接起動 + IAMコンソールでのStatus確認 | ○(サンプルFinding経由では要検証だが、直接テストで確認) |
| 3. SNS通知 | サブスクリプション確認・メール受信 | ○ |
| 4. 検出結果の集約 | `list-findings` + `AccountId`フィールドの裏取り | ○ |

## コスト

GuardDutyは新規アカウントの30日間無料トライアル対象、EventBridge・Lambda・SNSはいずれも無料枠の範囲内に収まった。実測で数百件規模のFinding・Lambda起動・SNS通知が発生しても、課金は事実上発生していない。

---

## 完成時点の構成

ここまでで作ったものを、アカウントとロールの対応関係として1枚にまとめておく。次のPart 7で削除するのは、この図に出てくるリソースがすべてになる。

![完成時点のアカウントとロールの関係図](/images/arch-01-final-architecture.png)

この図で確認しておきたいのは次の3点。

1. **封じ込めの権限は一本の細い線になっている**。`lambda.amazonaws.com` → Account BのLambda実行ロール → Account Cの封じ込めロール → IAMユーザー1人のアクセスキー、という順に、各段階で許可する相手と操作が絞り込まれている。どこか1段を突破されても、次の段でExternalIdなり`Resource`指定なりに阻まれる
2. **Account Aは経路上に一切いない**。委任管理者を指定した時点で役目が終わっており、Findingも権限も通っていない
3. **検知と実行が別アカウントに分かれている**。検知はC側、判断と実行はB側で、封じ込めだけが再びC側に戻る

アカウント別に、この検証で作成したリソースは以下の通り。

| アカウント | 作成したリソース |
|---|---|
| A | なし(委任管理者の登録操作のみ) |
| B | GuardDuty検出器(委任管理者)、EventBridgeルール、Lambda関数、IAMロール`GuardDutyContainmentLambdaRole`、SNSトピック |
| C | GuardDuty検出器(メンバー)、IAMロール`SecurityOpsContainmentRole`、IAMユーザー`test-containment-target`とそのアクセスキー |

---

## Part 7: 後片付け

検証環境を放置すると、無料トライアル終了後に課金対象になったり、孤立したリソースが残ったりする。必ず片付ける。

### Account B側

```bash
# Account Bの認証情報で実行
aws events remove-targets --rule guardduty-high-severity-rule --ids "1"
aws events delete-rule --name guardduty-high-severity-rule
aws lambda delete-function --function-name guardduty-containment
aws sns delete-topic --topic-arn <SNSトピックのARN>
aws iam delete-role-policy --role-name GuardDutyContainmentLambdaRole --policy-name lambda-permissions
aws iam delete-role --role-name GuardDutyContainmentLambdaRole
```

![Account B側の各種リソースが削除された様子](/images/cleanup-03-account-b-resources-deleted.png)

### Account C側

```bash
# Account Cの認証情報で実行
aws iam delete-role-policy --role-name SecurityOpsContainmentRole --policy-name containment-permissions
aws iam delete-role --role-name SecurityOpsContainmentRole
```

![SecurityOpsContainmentRoleが削除された様子](/images/cleanup-04-account-c-role-deleted.png)

```bash
aws iam list-access-keys --user-name test-containment-target
# 表示されたAccessKeyIdを使って削除
aws iam delete-access-key --user-name test-containment-target --access-key-id <AccessKeyId>
aws iam delete-user --user-name test-containment-target
```

![アクセスキーとIAMユーザーが削除された様子](/images/cleanup-05-access-key-user-deleted.png)

### GuardDutyのメンバー関係・委任管理者の解除

```bash
# Account Bの認証情報で実行
aws guardduty list-detectors

aws guardduty disassociate-members \
  --detector-id <Account_Bの検出器ID> \
  --account-ids 333333333333

aws guardduty delete-members \
  --detector-id <Account_Bの検出器ID> \
  --account-ids 333333333333
```

`<Account_Bの検出器ID>`は、直前の`list-detectors`で返ってきた実際の検出器ID(英数字の文字列)に置き換えて実行する。

![disassociate-members・delete-membersが成功した様子](/images/part1-06-disassociate-delete-members-success.png)

`UnprocessedAccounts`が空配列であれば成功。

続けて、Account A側で委任管理者の登録そのものを解除する。メンバー解除だけでは、Account Bが委任管理者として指定された状態が残ってしまう。

```bash
# Account Aの認証情報で実行
aws guardduty disable-organization-admin-account --admin-account-id 222222222222
```

![disable-organization-admin-accountが成功した様子](/images/cleanup-06-disable-admin-account-success.png)

### 検出器の削除

最後に、Account B・Cそれぞれで検出器を削除する。

```bash
aws guardduty delete-detector --detector-id <検出器ID>
```

Account B・Cそれぞれで実行後、`list-detectors`が空配列を返すことを確認する。

![Account B側でlist-detectorsが空配列を返し、GuardDuty無効化を確認](/images/cleanup-01-detectors-empty-b.png)

![Account C側でも同様にlist-detectorsが空配列を返した](/images/cleanup-02-detectors-empty-c.png)

これで、両アカウントのGuardDutyが無効化されたことが確認できた。

Account B・Cのアカウント自体(器)をクローズするかどうかは、また別の判断になる。Organizations配下から「独立アカウント化」する場合は電話番号認証が必要になる点に注意。単なるメンバーアカウントの閉鎖であれば別フロー(実施時に最新のAWS公式ドキュメントで確認すること)。

---

## この記事で得られた気づきのまとめ

実際に手を動かしてみて、ドキュメントを読むだけでは分からなかったことがいくつもあった。

1. **委任管理者登録・メンバー追加の操作だけで、GuardDutyが自動有効化される**。手動での`create-detector`は不要
2. **IAMロールの信頼関係には作成順序の依存がある**。信頼される側を先に作る必要がある。権限ポリシーの`Resource`は実在チェックされないのに、信頼ポリシーの`Principal`はチェックされる、という非対称性が理由だった
3. **メンバーアカウント同士は直接AssumeRoleできない**。必ず管理アカウントを経由する
4. **CLIでEventBridge→Lambda連携を組む場合、`lambda add-permission`を自分で叩く必要がある**。コンソール操作と違って自動付与されない
5. **サンプルFinding機能は全種類を一括生成し、ダミーのリソース識別子を含む**。検知パイプラインの確認には使えるが、実際の封じ込めアクションの検証には向いていない
6. **最小権限ポリシーは、意図しない対象への操作を「正しく」拒否してくれる**。今回のダミーユーザーへの操作拒否は、まさにこの設計が効いた場面だった

いずれも、設計編で立てた構成そのものを覆すものではなかったが、実装の細部では想定と異なる挙動がいくつもあり、実機検証の価値を改めて感じた。

## 次にやること: コード化

今回はすべてCLIで手作業で組んだ。おかげで、どのコマンドが何を返すか、どこで順序の制約に当たるかを一つずつ確認できた。手順・JSON・Pythonコードは確定したので、素材としては揃っている。

一方で、手作業のままでは割に合わない部分もはっきりした。

- Account B → Account C → Account Bと認証情報を行き来する手間が、そのまま作業ミスの温床になる
- 信頼ポリシーと権限ポリシーの作成順序を、人間が毎回計算している
- 後片付け(Part 7)で消し忘れると、リソースが孤立して残る

いずれもTerraformのようなIaCツールで解消できる範囲にある。リソース間の参照関係から依存グラフが作られるので、順序は自動で解決される。作成と削除が同じ定義から実行できるので、消し忘れも起きにくい。同じ構成を別リージョン・別アカウントで再現するときの再現性も上がる。

検証環境を何度も作り直す前提であれば、手で組むのは最初の1回だけで十分だと思う。次はこの構成をコードに落とすところをやる。
