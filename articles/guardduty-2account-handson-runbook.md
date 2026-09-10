# GuardDuty委任管理者 + 自動封じ込め検証 実行手順書(2アカウント構成 v2)

前提: リージョンは全ステップで統一する(例: ap-northeast-1)。GuardDutyはリージョナルサービスのため、リージョンが揃っていないと集約もEventBridgeも機能しない。

## 構成(ベストプラクティスに合わせた役割)

- **Account A(既存アカウント) = Organizations管理アカウント 兼 本番アカウント役(GuardDutyのメンバー)**
- **Account B(新規作成) = GuardDuty委任管理者 兼 セキュリティ運用アカウント**

Organizationsの管理アカウント自体をGuardDutyの委任管理者にすることはAWSのベストプラクティス上非推奨(最小権限の原則に反するため)。一方、管理アカウントをGuardDutyの「メンバー」として追加することは正式にサポートされた構成で、条件は事前に管理アカウント側でGuardDutyを有効化しておくことだけ。

**この構成で生じる重要な論点**: 封じ込めLambda(Account B側)がAssumeRoleでAccount A(=Organizations管理アカウント)のリソースを操作することになる。本番運用では管理アカウントに実ワークロードを置かず、自動封じ込めの対象にもならないのが通例だが、今回は2アカウントという制約上、管理アカウントに「本番アカウント役」を兼務させている。この歪みは記事内で明示的に断っておくこと。

---

## Part 1. Account B(のちのセキュリティ運用アカウント)作成

1. Account AでAWS Organizationsコンソールを開く(未有効なら先に「組織を作成」)。
2. 「アカウント」→「AWSアカウントを追加」→「AWSアカウントを作成」を選択。
3. 以下を入力:
   - アカウント名: 例 `security-ops-account`
   - メールアドレス: 手持ちの別メールアドレス
   - IAMロール名: デフォルトの `OrganizationAccountAccessRole` のままでよい
4. ステータスがSUCCEEDEDになるまで数分待つ。
5. Account BのアカウントID(12桁)を控える。

**確認**: Account Aのコンソール右上「ロールを切り替え」で、Account BのアカウントID + `OrganizationAccountAccessRole` によりアクセスできることを確認する。

---

## Part 2. 両アカウントでGuardDuty有効化

Account A、Account Bそれぞれで:

1. GuardDutyコンソールを開く(統一したリージョンで)。
2. 「GuardDutyを有効にする」を実行。
3. Account A側は、後でAccount Bのメンバーとして追加されるための前提条件なので、ここで必ず有効化しておく。

---

## Part 3. 委任管理者の設定とメンバー登録

1. Account A(管理アカウント)で、GuardDutyの委任管理者としてAccount Bを登録する。GuardDutyコンソールの「設定」→「委任管理者」相当の画面、またはOrganizations経由での委任設定を行う(コンソール導線は変更されることがあるため実機で確認: 要確認)。
2. Account B(委任管理者)のGuardDutyコンソール →「アカウント」を開く。Organization配下のアカウント一覧にAccount Aが表示されるはず。
3. Account Aにチェックを入れ、「メンバーとして追加」を実行。Account A側はすでにGuardDutyを有効化済みなのでそのままメンバー化できる。
4. Account BのGuardDutyコンソールでAccount Aが「メンバー」としてステータス表示されることを確認する。

**確認方法**: Account Aで「サンプル検出結果の生成」を実行し、Account BのGuardDuty Findingsタブに同じFindingが集約されることを確認する(要件4の実機確認)。

---

## Part 4. クロスアカウントの封じ込め用IAMロール(Account A側 = 操作される側)

封じ込めLambdaはAccount B(セキュリティ運用)側に置き、Account A(本番役)側のリソースを操作する。そのためAccount Aに「Account BのLambda実行ロールからAssumeできるロール」を作る。

Account Aで以下のロールを作成(ロール名: `SecurityOpsContainmentRole`):

**信頼ポリシー**(Account BのLambda実行ロールに限定):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<Account_BのID>:role/GuardDutyContainmentLambdaRole"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "guardduty-containment-verify"
        }
      }
    }
  ]
}
```

**権限ポリシー**(最小権限。IAMアクセスキー無効化を例にする):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:UpdateAccessKey",
        "iam:ListAccessKeys"
      ],
      "Resource": "arn:aws:iam::<Account_AのID>:user/*"
    }
  ]
}
```

Account Aは管理アカウントでもあるため、この権限は「特定のテスト用IAMユーザーのみ」に絞るなど、Resource指定をできるだけ狭くすることを強く推奨する(`user/*`ではなく`user/test-containment-target`のように)。管理アカウント全体に対して自動封じ込めが誤爆する余地を作らないため。

---

## Part 5. Lambda実行ロール(Account B側)

Account Bで `GuardDutyContainmentLambdaRole` を作成:

- 信頼ポリシー: `lambda.amazonaws.com` からAssume可能にする
- 権限ポリシー:
  - `logs:CreateLogGroup` / `logs:CreateLogStream` / `logs:PutLogEvents`
  - `sts:AssumeRole` を `arn:aws:iam::<Account_AのID>:role/SecurityOpsContainmentRole` に対して許可
  - `sns:Publish` を後述のSNSトピックARNに対して許可

---

## Part 6. EventBridgeルール(Account B側、GuardDuty Findingの捕捉)

Account BのEventBridgeコンソールで、デフォルトイベントバスにルールを作成する。委任管理者アカウントのデフォルトイベントバスには、メンバーアカウント分も含めてGuardDutyのFindingイベントが自動的に集約される(クロスアカウントのイベントバス許可設定は不要)。

**イベントパターン**(重大度でフィルタする例。数値の閾値は実際にFindingを生成して`detail.severity`を確認した上で調整すること):
```json
{
  "source": ["aws.guardduty"],
  "detail-type": ["GuardDuty Finding"],
  "detail": {
    "severity": [{ "numeric": [">=", 7] }]
  }
}
```

ターゲット: Part 5で作成したLambda関数を指定する。コンソールでターゲットを設定すると、EventBridgeがこのLambda関数を起動できるようリソースベースポリシー(`lambda:AddPermission`相当)が自動的に付与される。CLIやIaCで構築する場合はこの許可を明示的に追加しないとLambdaが起動しないので注意。

---

## Part 7. 封じ込めLambda関数(Account B側)

```python
import boto3
import os
import json

STS = boto3.client("sts")
SNS = boto3.client("sns")

TARGET_ACCOUNT_ID = os.environ["TARGET_ACCOUNT_ID"]  # Account AのID
CONTAINMENT_ROLE_NAME = "SecurityOpsContainmentRole"
EXTERNAL_ID = "guardduty-containment-verify"
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

def lambda_handler(event, context):
    detail = event["detail"]
    finding_type = detail["type"]
    severity = detail["severity"]
    title = detail.get("title", "")
    account_id = detail["accountId"]

    # Account Aへスイッチ
    assumed = STS.assume_role(
        RoleArn=f"arn:aws:iam::{TARGET_ACCOUNT_ID}:role/{CONTAINMENT_ROLE_NAME}",
        RoleSessionName="guardduty-containment",
        ExternalId=EXTERNAL_ID,
    )
    creds = assumed["Credentials"]
    iam_a = boto3.client(
        "iam",
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )

    action_taken = "none"
    if "UnauthorizedAccess:IAMUser" in finding_type or "AccessKey" in finding_type:
        access_key_id = detail["resource"]["accessKeyDetails"]["accessKeyId"]
        user_name = detail["resource"]["accessKeyDetails"]["userName"]
        iam_a.update_access_key(
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

環境変数: `TARGET_ACCOUNT_ID`(Account AのID)、`SNS_TOPIC_ARN`

---

## Part 8. SNSトピック(Account B側)

1. SNSトピックを作成(例: `guardduty-high-severity-alerts`)。
2. 自分のメールアドレスでサブスクリプション登録し、確認メールのリンクをクリックして有効化する。
3. Part 5のLambda実行ロールに、このトピックARNへの`sns:Publish`権限があることを確認。

---

## Part 9. 通しテスト

**事前に把握しておくこと**: GuardDutyの「サンプル検出結果の生成」は、対応する全Findingタイプ分のサンプルを一括で生成する仕様。severity>=7でフィルタしていても、High/Critical相当のサンプルが同時に何十件も発生し、Lambdaがその数だけ起動し、SNSメールも同数届く可能性がある。Part 7のLambdaコードはIAMアクセスキー系以外のFindingでは`actionTaken: "none"`で安全に処理を素通りするため実害はないが、「1件だけ発火する」という想定で臨むと挙動に驚くので先に知っておくとよい。1件ずつ確認したい場合は、EventBridgeのイベントパターンに`"type": ["対象のFindingタイプ名"]`を追加して絞り込むとよい。

1. Account AのGuardDutyコンソールで「サンプル検出結果の生成」を実行(Account Aが本番役なので、ここで検知対象になる)。
2. Account BのGuardDuty Findingsタブに同じFindingが集約されることを確認(要件4)。
3. EventBridgeのイベントパターンにマッチしていれば、Lambda(Account B側)が起動する。CloudWatch Logsでログを確認。
4. Account A側の対象リソース(テスト用IAMユーザーのアクセスキー等)が実際に無効化されたか確認(要件2)。
5. SNSメール通知が届くか確認(要件3)。
6. Account AのCloudTrailで、Account BのLambda実行ロールがAssumeRoleした記録と、UpdateAccessKeyが実行された記録が残っていることを確認する。管理アカウントに対して外部(Account B)から操作が入った記録が残る、という点自体が監査上の重要な確認ポイントになる。

**注意**: サンプルFindingは`isSample: true`を持つ合成イベント。EventBridgeのイベントパターンには通常マッチするが、`detail`の構造は実データ前提で書かれていることがあるため、一度そのままCloudWatch Logsに出力して構造を確認してから本実装するのが安全。

---

## Part 10. 後片付け

1. EventBridgeルール削除(Account B)
2. Lambda関数削除(Account B)
3. SNSトピック・サブスクリプション削除(Account B)
4. Account AのIAMロール `SecurityOpsContainmentRole` 削除
5. Account BのIAMロール `GuardDutyContainmentLambdaRole` 削除
6. Account B(委任管理者)側でAccount Aのメンバー登録を解除
7. Account A(管理アカウント)側で、GuardDutyの委任管理者登録そのものを解除する(`DisableOrganizationAdminAccount`相当の操作)。メンバー解除だけでは、Account Bが委任管理者として指定された状態が残ってしまう。
8. 両アカウントでGuardDuty無効化
9. Account Bを完全にクローズするかどうかを判断する。Organizations配下から「独立アカウント化」する場合は電話番号認証が必要になる点に注意。単なるメンバーアカウントの閉鎖であれば別フロー(要確認: 実施時に最新のAWS公式ドキュメントで確認)。

---

---

## 付録: 実行コマンド一覧(CLI版)

役割分担: **実行はCLI、コンソールは結果確認のみ**(GuardDuty Findings画面、CloudTrailイベント履歴、SNSメール受信の目視確認)。SNSのメールサブスクリプション確認リンクのクリックだけは、AWSにAPIが存在しないため唯一の手作業として残る。

### Part 1. Account B作成
```bash
# Account Aの認証情報で実行
aws organizations create-account \
  --email "<Account_B用メールアドレス>" \
  --account-name "security-ops-account"

# 戻り値のCreateAccountRequestIdでポーリング
aws organizations describe-create-account-status \
  --create-account-request-id <request-id>
# State: SUCCEEDED になったらAccountIdを控える
```

**確認(結果確認のみコンソール、または以下のCLIでも可)**:
```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<Account_BのID>:role/OrganizationAccountAccessRole \
  --role-session-name verify-access
```

### Part 2. 両アカウントでGuardDuty有効化
```bash
# Account A、Account Bそれぞれの認証情報で実行
aws guardduty create-detector --enable
# 戻り値のDetectorIdを両アカウント分控える
```

### Part 3. 委任管理者の設定とメンバー登録
```bash
# Account Aの認証情報で実行(要確認: 先にEnableAWSServiceAccessが必要になるケースがある)
aws organizations enable-aws-service-access \
  --service-principal guardduty.amazonaws.com

aws guardduty enable-organization-admin-account \
  --admin-account-id <Account_BのID>

# Account Bの認証情報で実行(Account Bの検出器IDを使う)
aws guardduty create-members \
  --detector-id <Account_Bの検出器ID> \
  --account-details AccountId=<Account_AのID>,Email=<Account_Aのメールアドレス>
```

**確認(要件4の実機確認)**:
```bash
# Account Aの認証情報で実行
aws guardduty create-sample-findings \
  --detector-id <Account_Aの検出器ID>

# Account Bの認証情報で実行、Account AのFindingが見えるか確認
aws guardduty list-findings --detector-id <Account_Bの検出器ID>
```

### Part 4. クロスアカウント封じ込め用IAMロール(Account A側)
```bash
# Account Aの認証情報で実行
aws iam create-role \
  --role-name SecurityOpsContainmentRole \
  --assume-role-policy-document file://trust-policy.json

aws iam put-role-policy \
  --role-name SecurityOpsContainmentRole \
  --policy-name containment-permissions \
  --policy-document file://permission-policy.json
```

### Part 5. Lambda実行ロール(Account B側)
```bash
# Account Bの認証情報で実行
aws iam create-role \
  --role-name GuardDutyContainmentLambdaRole \
  --assume-role-policy-document file://lambda-trust-policy.json

aws iam put-role-policy \
  --role-name GuardDutyContainmentLambdaRole \
  --policy-name lambda-permissions \
  --policy-document file://lambda-permission-policy.json
```

### Part 6. EventBridgeルール(Account B側)
```bash
# Account Bの認証情報で実行
aws events put-rule \
  --name guardduty-high-severity-rule \
  --event-pattern file://event-pattern.json

aws events put-targets \
  --rule guardduty-high-severity-rule \
  --targets "Id"="1","Arn"="<Lambda関数のARN>"

# CLIの場合はEventBridgeからの起動許可を自分で付与する必要がある(コンソールと異なり自動付与されない)
aws lambda add-permission \
  --function-name <Lambda関数名> \
  --statement-id eventbridge-invoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn arn:aws:events:<region>:<Account_BのID>:rule/guardduty-high-severity-rule
```

### Part 7. Lambda関数(Account B側)
```bash
# Account Bの認証情報で実行(function.zipにコードを固めておく)
aws lambda create-function \
  --function-name guardduty-containment \
  --runtime python3.13 \
  --role arn:aws:iam::<Account_BのID>:role/GuardDutyContainmentLambdaRole \
  --handler lambda_function.lambda_handler \
  --zip-file fileb://function.zip \
  --environment "Variables={TARGET_ACCOUNT_ID=<Account_AのID>,SNS_TOPIC_ARN=<SNSトピックARN>}"
```

### Part 8. SNSトピック(Account B側)
```bash
# Account Bの認証情報で実行
aws sns create-topic --name guardduty-high-severity-alerts

aws sns subscribe \
  --topic-arn <トピックARN> \
  --protocol email \
  --notification-endpoint <自分のメールアドレス>
# ここだけ手動: 届いた確認メールのリンクをクリック
```

### Part 9. 通しテスト
```bash
# Account Aの認証情報で実行(本番役、ここでFindingを発生させる)
aws guardduty create-sample-findings --detector-id <Account_Aの検出器ID>

# 1件だけに絞りたい場合はfinding-typesを指定
aws guardduty create-sample-findings \
  --detector-id <Account_Aの検出器ID> \
  --finding-types "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration"

# CloudWatch Logsでの確認
aws logs tail /aws/lambda/guardduty-containment --follow

# CloudTrailでの確認(Account A側、AssumeRoleとUpdateAccessKeyの記録)
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=UpdateAccessKey
```

### Part 10. 後片付け
```bash
# Account B側
aws events remove-targets --rule guardduty-high-severity-rule --ids "1"
aws events delete-rule --name guardduty-high-severity-rule
aws lambda delete-function --function-name guardduty-containment
aws sns delete-topic --topic-arn <トピックARN>
aws iam delete-role-policy --role-name GuardDutyContainmentLambdaRole --policy-name lambda-permissions
aws iam delete-role --role-name GuardDutyContainmentLambdaRole

# Account A側
aws iam delete-role-policy --role-name SecurityOpsContainmentRole --policy-name containment-permissions
aws iam delete-role --role-name SecurityOpsContainmentRole

# Account B側でメンバー解除
aws guardduty disassociate-members --detector-id <Account_Bの検出器ID> --account-ids <Account_AのID>
aws guardduty delete-members --detector-id <Account_Bの検出器ID> --account-ids <Account_AのID>

# Account A側で委任管理者登録の解除
aws guardduty disable-organization-admin-account --admin-account-id <Account_BのID>

# 両アカウントでGuardDuty無効化
aws guardduty delete-detector --detector-id <各アカウントの検出器ID>
```

---

## 記事化するときのメモ

- 「検証環境(Organizations配下の2アカウント)で実施」であることを明記し、12アカウント規模の本番運用との差分(展開の自動化、OU単位のSCP、Findingsのチューニング、誤爆時のブラストラディウス制御)は「設計として検討したが未検証」と分けて書く。
- **管理アカウントを本番役として兼務させたことによる歪み**(本来なら自動封じ込めの対象にすべきでないアカウントに封じ込めロールを置いている)は、正直に限界として記述する。これは「12アカウント構成なら、この歪みは発生しない(管理アカウントは監視対象に含めない設計にできる)」という考察につなげられる。
- CloudTrailのログ画面・SNSメール・GuardDuty Findings画面のスクリーンショットは、実際に自分の環境で取得したものだけを使う。
- severityの数値閾値、委任管理者設定の正確なコンソール導線など「要確認」とマークした箇所は、実施時の実際の画面に基づいて記事の記述を修正する。
