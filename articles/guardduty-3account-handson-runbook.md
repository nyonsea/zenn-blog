# GuardDuty委任管理者 + 自動封じ込め検証 実行手順書(3アカウント構成 v3)

前提: リージョンは全ステップで統一する(例: ap-northeast-1)。GuardDutyはリージョナルサービスのため、リージョンが揃っていないと集約もEventBridgeも機能しない。役割分担は「実行はCLI、コンソールは結果確認のみ」を基本とする。

## 構成

- **Account A(既存) = Organizations管理アカウント**。GuardDutyのメンバーにも委任管理者にもしない。委任管理者を登録する起点としてのみ関与する
- **Account B(新規作成) = GuardDuty委任管理者 兼 セキュリティ運用アカウント**
- **Account C(新規作成) = GuardDutyメンバー 兼 本番アカウント役**。Findingを発生させ、封じ込めの対象になる

2アカウント構成(v2)では管理アカウント(A)がGuardDutyメンバーを兼務し、封じ込めLambdaのAssumeRole対象になっていた。これは「管理アカウントは本来監視・自動操作の対象に含めない」という原則から外れる歪みだった。3アカウント構成ではAが完全に監視対象・封じ込め対象から外れるため、この歪みが解消される。

---

## Part 1. Account B・Account Cの作成

Account Aの認証情報で実行する。

```bash
aws organizations create-account \
  --email "<Account_B用メールアドレス>" \
  --account-name "security-ops-account"

aws organizations create-account \
  --email "<Account_C用メールアドレス>" \
  --account-name "prod-sim-account"

# それぞれのCreateAccountRequestIdでポーリング
aws organizations describe-create-account-status \
  --create-account-request-id <request-id>
# State: SUCCEEDED になったらAccountIdを控える(B、Cそれぞれ)
```

**確認**:
```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<Account_BのID>:role/OrganizationAccountAccessRole \
  --role-session-name verify-access

aws sts assume-role \
  --role-arn arn:aws:iam::<Account_CのID>:role/OrganizationAccountAccessRole \
  --role-session-name verify-access
```

---

## Part 2. 委任管理者の設定とメンバー登録

**要確認**: 以下は「委任管理者に登録するとB自身のGuardDutyが自動有効化され、Bがメンバーとして追加したアカウントも自動でGuardDutyが有効化される」というAWSの標準動作を前提にしている。個別に`create-detector`を叩く手順は原則不要という想定だが、実機で期待通りに動くかは要確認。動かない場合は各アカウントで`aws guardduty create-detector --enable`を個別に実行する。

```bash
# Account Aの認証情報で実行
aws organizations enable-aws-service-access \
  --service-principal guardduty.amazonaws.com

aws guardduty enable-organization-admin-account \
  --admin-account-id <Account_BのID>

# Account Bの認証情報で実行、GuardDutyが自動有効化されているか確認
aws guardduty list-detectors
# 検出器IDが既に存在すればOK。存在しなければ以下で手動作成
# aws guardduty create-detector --enable

# Account Bの認証情報で実行、Cをメンバーとして追加
aws guardduty create-members \
  --detector-id <Account_Bの検出器ID> \
  --account-details AccountId=<Account_CのID>,Email=<Account_Cのメールアドレス>

# Account Cの認証情報で実行、GuardDutyが自動有効化されているか確認
aws guardduty list-detectors
```

**確認方法(要件4の実機確認)**:
```bash
# Account Cの認証情報で実行
aws guardduty create-sample-findings --detector-id <Account_Cの検出器ID>

# Account Bの認証情報で実行、CのFindingが見えるか確認
aws guardduty list-findings --detector-id <Account_Bの検出器ID>
```

---

## Part 3. クロスアカウントの封じ込め用IAMロール(Account C側 = 操作される側)

封じ込めLambdaはAccount B(セキュリティ運用)側に置き、Account C(本番役)側のリソースを操作する。そのためAccount Cに「Account BのLambda実行ロールからAssumeできるロール」を作る。

**信頼ポリシー**(`trust-policy.json`、Account BのLambda実行ロールに限定):
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

**権限ポリシー**(`permission-policy.json`、最小権限。テスト用IAMユーザー1つに限定):
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
      "Resource": "arn:aws:iam::<Account_CのID>:user/test-containment-target"
    }
  ]
}
```

```bash
# Account Cの認証情報で実行
aws iam create-role \
  --role-name SecurityOpsContainmentRole \
  --assume-role-policy-document file://trust-policy.json

aws iam put-role-policy \
  --role-name SecurityOpsContainmentRole \
  --policy-name containment-permissions \
  --policy-document file://permission-policy.json

# テスト対象のIAMユーザーも作っておく(アクセスキーも発行しておく)
aws iam create-user --user-name test-containment-target
aws iam create-access-key --user-name test-containment-target
```

---

## Part 4. Lambda実行ロール(Account B側)

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

権限ポリシーの中身:
- `logs:CreateLogGroup` / `logs:CreateLogStream` / `logs:PutLogEvents`
- `sts:AssumeRole` を `arn:aws:iam::<Account_CのID>:role/SecurityOpsContainmentRole` に対して許可
- `sns:Publish` を後述のSNSトピックARNに対して許可

---

## Part 5. EventBridgeルール(Account B側、GuardDuty Findingの捕捉)

委任管理者アカウント(B)のデフォルトイベントバスには、メンバーアカウント(C)分も含めてGuardDutyのFindingイベントが自動的に集約される(クロスアカウントのイベントバス許可設定は不要)。

**イベントパターン**(`event-pattern.json`。数値の閾値は実際にFindingを生成して`detail.severity`を確認した上で調整すること):
```json
{
  "source": ["aws.guardduty"],
  "detail-type": ["GuardDuty Finding"],
  "detail": {
    "severity": [{ "numeric": [">=", 7] }]
  }
}
```

```bash
# Account Bの認証情報で実行
aws events put-rule \
  --name guardduty-high-severity-rule \
  --event-pattern file://event-pattern.json

aws events put-targets \
  --rule guardduty-high-severity-rule \
  --targets "Id"="1","Arn"="<Lambda関数のARN>"

# CLIの場合はEventBridgeからの起動許可を自分で付与する必要がある
aws lambda add-permission \
  --function-name guardduty-containment \
  --statement-id eventbridge-invoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn arn:aws:events:<region>:<Account_BのID>:rule/guardduty-high-severity-rule
```

---

## Part 6. 封じ込めLambda関数(Account B側)

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

```bash
# Account Bの認証情報で実行(function.zipにコードを固めておく)
aws lambda create-function \
  --function-name guardduty-containment \
  --runtime python3.13 \
  --role arn:aws:iam::<Account_BのID>:role/GuardDutyContainmentLambdaRole \
  --handler lambda_function.lambda_handler \
  --zip-file fileb://function.zip \
  --environment "Variables={TARGET_ACCOUNT_ID=<Account_CのID>,SNS_TOPIC_ARN=<SNSトピックARN>}"
```

環境変数: `TARGET_ACCOUNT_ID`(Account CのID)、`SNS_TOPIC_ARN`

---

## Part 7. SNSトピック(Account B側)

```bash
# Account Bの認証情報で実行
aws sns create-topic --name guardduty-high-severity-alerts

aws sns subscribe \
  --topic-arn <トピックARN> \
  --protocol email \
  --notification-endpoint <自分のメールアドレス>
# ここだけ手動: 届いた確認メールのリンクをクリック(AWSにAPIが存在しないため唯一の手作業)
```

---

## Part 8. 通しテスト

**事前に把握しておくこと**: GuardDutyの「サンプル検出結果の生成」は、対応する全Findingタイプ分のサンプルを一括で生成する仕様。severity>=7でフィルタしていても、High/Critical相当のサンプルが同時に何十件も発生し、Lambdaがその数だけ起動し、SNSメールも同数届く可能性がある。Lambdaコードの`action_taken`分岐はIAMアクセスキー系以外を安全に素通りするため実害はないが、1件ずつ確認したい場合は`finding-types`で絞り込む。

```bash
# Account Cの認証情報で実行(本番役、ここでFindingを発生させる)
aws guardduty create-sample-findings --detector-id <Account_Cの検出器ID>

# 1件だけに絞りたい場合
aws guardduty create-sample-findings \
  --detector-id <Account_Cの検出器ID> \
  --finding-types "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration"

# CloudWatch Logsでの確認(Account B側)
aws logs tail /aws/lambda/guardduty-containment --follow

# CloudTrailでの確認(Account C側、AssumeRoleとUpdateAccessKeyの記録)
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=UpdateAccessKey
```

確認ポイント:
1. Account BのGuardDuty Findingsに、Account Cで発生させたFindingが集約される(要件4)
2. EventBridge→Lambdaが起動し、Account C側の`test-containment-target`ユーザーのアクセスキーが無効化される(要件2)
3. SNSメール通知が届く(要件3)
4. Account CのCloudTrailに、Account BのLambda実行ロールからのAssumeRoleとUpdateAccessKeyの記録が残る。Account Aはこの一連の流れに一切登場しないことも合わせて確認する(設計上の歪み解消の裏取り)

---

## Part 9. 後片付け

```bash
# Account B側
aws events remove-targets --rule guardduty-high-severity-rule --ids "1"
aws events delete-rule --name guardduty-high-severity-rule
aws lambda delete-function --function-name guardduty-containment
aws sns delete-topic --topic-arn <トピックARN>
aws iam delete-role-policy --role-name GuardDutyContainmentLambdaRole --policy-name lambda-permissions
aws iam delete-role --role-name GuardDutyContainmentLambdaRole

# Account C側
aws iam delete-role-policy --role-name SecurityOpsContainmentRole --policy-name containment-permissions
aws iam delete-role --role-name SecurityOpsContainmentRole
aws iam delete-access-key --user-name test-containment-target --access-key-id <キーID>
aws iam delete-user --user-name test-containment-target

# Account B側でCのメンバー解除
aws guardduty disassociate-members --detector-id <Account_Bの検出器ID> --account-ids <Account_CのID>
aws guardduty delete-members --detector-id <Account_Bの検出器ID> --account-ids <Account_CのID>

# Account A側で委任管理者登録の解除
aws guardduty disable-organization-admin-account --admin-account-id <Account_BのID>

# Account B、Cそれぞれで検出器を削除
aws guardduty delete-detector --detector-id <各アカウントの検出器ID>
```

Account B・Cを完全にクローズするかどうかは別途判断する。Organizations配下から「独立アカウント化」する場合は電話番号認証が必要になる点に注意。単なるメンバーアカウントの閉鎖であれば別フロー(要確認: 実施時に最新のAWS公式ドキュメントで確認)。

---

## 記事化するときのメモ

- 「検証環境(Organizations配下の3アカウント)で実施」であることを明記し、12アカウント規模の本番運用との差分(展開の自動化、OU単位のSCP、Findingsのチューニング、誤爆時のブラストラディウス制御)は「設計として検討したが未検証」と分けて書く。
- v2(2アカウント)からv3(3アカウント)への変更理由、つまり「管理アカウントを監視・封じ込め対象から外した」という設計判断の過程は、記事の「③設計判断」「⑨問題点・制約」「⑩本番環境ならどう改善するか」にそのまま使える。試行錯誤の過程自体がポートフォリオ価値を持つ。
- CloudTrailのログ画面・SNSメール・GuardDuty Findings画面のスクリーンショットは、実際に自分の環境で取得したものだけを使う。
- 「要確認」とマークした箇所(GuardDuty自動有効化の実際の挙動、委任管理者設定の正確なコンソール導線、severityの数値閾値、アカウントクローズ方法)は、実施時の実際の結果に基づいて記事の記述を修正する。
