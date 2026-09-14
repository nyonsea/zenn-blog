---
title: "AWSアカウントを全リージョン棚卸しする ― 「消したつもり」が残る3つのパターン"
emoji: "🧹"
type: "tech"
topics: ["aws", "securityhub", "guardduty", "powershell", "security"]
published: false
---

## この記事について

検証用のAWSアカウントで、使っていない12リージョンのGuardDutyと13リージョンのSecurity Hubが動き続けていた。気づいたきっかけは、Cost Explorerに出ていた月1ドル程度の課金だった。

この記事は、その棚卸しの記録である。主題はコスト削減ではない。**AWSアカウントの中で今何がどこで動いているかを、どうやって確認するか**のほうにある。

作業を通して、「削除したはずのものが残る」パターンが3種類出てきた。リージョン単位、付随リソース単位、オブジェクトバージョン単位。いずれも削除コマンド自体は成功していて、確認しなければ気づけない。

想定読者は次のような人。

- 個人の検証用AWSアカウントを持っていて、何が残っているか把握できていない人
- ハンズオンや教材を一通り終えたあと、環境を整理したい人
- マルチリージョンでのセキュリティサービス有効化を検討している人

実行環境はWindows PowerShell 5.1 + AWS CLI v2。すべて個人の検証用アカウントでの作業で、業務環境ではない。

### 前提となる背景

このアカウントでは4か月ほど前からAWSセキュリティ関連のハンズオン教材を進めていて、直近1か月は自分で設計した検証を行っている。今回見つかった残骸は、すべて教材フェーズのものだった。

自分で設計した検証のほうには、最初から後片付けの手順を組み込んでいた（[前回の記事](https://zenn.dev/nyondev/articles/zenn-article-implementation)のPart 7）。ただしそちらは作業リージョンを`ap-northeast-1`に統一していたため、片付けも東京リージョンの中で完結している。**リージョンという軸そのものが視野に入っていなかった**。これが今回の一番大きな気づきだった。

---

## 発端: Cost Explorerの内訳

9月の請求を日別で見たときの内訳。

![Cost Explorerのコストと使用量の内訳。合計$1.05のうちSecurity Hubが$0.93を占めている](/images/aws-inventory/01-cost-explorer.png)

- 合計: $1.05（9/1〜9/14）
- Security Hub: $0.93
- Tax: $0.10
- GuardDuty: $0.01
- S3: $0.01
- 他12サービス: $0.00

金額としては小さい。ただ、**このアカウントでSecurity Hubを意図的に使っている認識がなかった**ことが引っかかった。$0.93という額より、心当たりがないことのほうが問題だった。

### なぜ気づきにくいのか

この状態が見過ごされやすい理由は3つある。

**1. 金額が小さすぎる**

月$2程度では、請求アラートを設定していても閾値に届かない。「AWSの請求が跳ね上がった」系の事故とは性質が違う。

**2. コンソールはリージョン単位でしか見えない**

マネジメントコンソールのSecurity Hubを開いても、見えるのは今選択しているリージョンの状態だけ。他のリージョンで有効かどうかは、リージョンを切り替えるまで分からない。

**3. Cost Explorerの既定表示にリージョンの内訳が出ない**

上の画面はサービス別の内訳で、どのリージョンで発生した課金かは表示されていない。グループ化を「リージョン」に変えれば見えるが、既定では出ない。

オンプレミスの感覚だと、ここが一番落差が大きい。物理的な設備なら、存在する場所は限られている。資産管理台帳に載っていない機器がラックに刺さっていることは、まずない。AWSでは操作ひとつで全リージョンに展開されうるし、その一覧を出す標準的な画面が用意されていない。

---

## 棚卸しの方針

やることを3つに決めた。

1. **課金内訳に出ているサービス名を、調査対象のリストとして使う**
2. 各サービスについて、**全リージョンを走査して実体の有無を確認する**
3. 不要なものを削除し、**削除後にもう一度走査して確認する**

1について補足すると、課金内訳に名前が出ているなら、そのサービスで何らかの課金イベントが発生している。金額が$0.00でも名前が出ていれば、実体を確認する価値がある。逆に名前が一度も出ていないサービスは、少なくとも課金対象の使い方はしていない。一次フィルタとして使える。

3が要点で、今回の作業では削除コマンドが成功しても実際には残っているケースが複数出た。確認まで含めて1セットにする。

---

## 準備でつまずいた: RequestExpiredの切り分け

本題に入る前に、リージョン一覧の取得で詰まった話を書いておく。棚卸しそのものとは別の話なので、不要なら読み飛ばしてほしい。

### エラーメッセージ

```powershell
aws ec2 describe-regions --query 'Regions[].RegionName' --output text
```

```
aws: [ERROR]: An error occurred (RequestExpired) when calling the DescribeRegions operation:
Request has expired.
```

![リージョン一覧の取得がRequestExpiredで失敗し、変数が空のままになっている](/images/aws-inventory/02-request-expired.png)

`RequestExpired`という名前から、まずクロックスキューを疑った。AWSのSigV4署名にはリクエスト時刻が含まれていて、AWS側との時刻が数分以上ずれていると署名が期限切れと判定される。Kerberosの既定のクロックスキュー許容値が5分であるのと同じで、認証基盤が時刻に依存するのは珍しい話ではない。

### 時刻を調べた

```powershell
w32tm /query /status
```

```
階層: 5 (二次参照 - (S)NTP で同期)
ルート分散: 7.93890041s
参照 ID: 0x2851BC55 (ソース IP: 40.81.188.85)
最終正常同期時刻: 2026/09/14 11:25:40
ソース: time.windows.com,0x9
ポーリング間隔: 10 (1024s)
```

![w32tm /query /statusの出力。time.windows.comと同期済みだがルート分散が7.9秒ある](/images/aws-inventory/03-w32tm-status.png)

同期自体はできている。ただ`time.windows.com`はルート分散が7.9秒と大きく、精度の面では信頼しきれない。念のため、AWS側の時刻と直接比較した。

```powershell
$aws = (curl.exe -sI https://s3.amazonaws.com | Select-String '^Date:') -replace '^Date:\s*',''
$awsUtc = [datetime]::Parse($aws).ToUniversalTime()
$locUtc = [datetime]::UtcNow
"AWS   : $($awsUtc.ToString('yyyy-MM-dd HH:mm:ss'))"
"Local : $($locUtc.ToString('yyyy-MM-dd HH:mm:ss'))"
"Diff  : $([math]::Round(($locUtc - $awsUtc).TotalSeconds,1)) sec"
```

```
AWS   : 2026-09-14 03:02:24
Local : 2026-09-14 03:02:24
Diff  : 0.3 sec
```

![AWS側の時刻とローカル時刻の差が0.3秒であることを確認](/images/aws-inventory/04-time-diff.png)

`Date`ヘッダーはHTTPレスポンスに必ず入るので、認証なしで相手側の時刻が取れる。差は0.3秒。時刻はシロだった。

### 本当の原因

最小のAPI呼び出しで切り分けた。

```powershell
aws sts get-caller-identity
```

```
aws: [ERROR]: An error occurred (ExpiredToken) when calling the GetCallerIdentity operation:
The security token included in the request is expired
```

![sts get-caller-identityがExpiredTokenで失敗し、原因が認証情報だと確定した](/images/aws-inventory/05-expired-token.png)

環境変数に、期限切れの一時認証情報が残っていた。前回の検証でAssumeRoleしたときの`AWS_SESSION_TOKEN`がそのままだった。環境変数は`~/.aws/credentials`のプロファイルより優先されるので、消せば恒久的なアクセスキーに戻る。

```powershell
Remove-Item Env:AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
Remove-Item Env:AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
Remove-Item Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
aws sts get-caller-identity
```

![環境変数を削除するとget-caller-identityが成功し、プロファイルのIAMユーザーに戻った](/images/aws-inventory/06-clear-env-success.png)

これで通った。

### 何を間違えたか

同じ原因に対して、EC2は`RequestExpired`、STSは`ExpiredToken`を返していた。前者は時刻を、後者は認証情報を指す名前になっている。エラー名だけを手がかりにしたため、NTPの調査に時間を使った。

切り分けの順序としては、**時刻を調べる前に`sts get-caller-identity`を叩くべきだった**。認証情報が有効かどうかを確認する最小のAPIで、これが通れば署名は成立していると分かる。「一番単純な経路から確認する」という障害切り分けの定石を、エラー名に引きずられて飛ばしていた。

---

## 棚卸し その1: Security Hub

### 全リージョンを走査する

```powershell
$regions = (aws ec2 describe-regions --query 'Regions[].RegionName' --output text) -split '\s+' |
           Where-Object { $_ }
"regions: $($regions.Count)"

foreach ($r in $regions) {
    $s = aws securityhub describe-hub --region $r --query 'SubscribedAt' --output text 2>$null
    if ($LASTEXITCODE -eq 0 -and $s) {
        Write-Host "$r : ENABLED ($s)" -ForegroundColor Yellow
    }
}
```

`describe-hub`は、そのリージョンでSecurity Hubが有効なら`SubscribedAt`（有効化日時）を返し、無効なら`InvalidAccessException`でエラーを返す。この成否を有効・無効の判定に使っている。

`aws ec2 describe-regions`は既定で、オプトイン不要なリージョンとオプトイン済みのリージョンを返す。未オプトインのリージョン（`ap-east-1`など）は含まれない。それらまで確認したい場合は`--all-regions`を付けるが、未オプトインのリージョンではAPIを呼べないので今回は既定のままにした。

### 結果

13リージョンで有効だった。

```
ap-south-1 : ENABLED (2026-06-30T07:09:26.609Z)
eu-north-1 : ENABLED (2026-06-30T07:09:27.150Z)
eu-west-3 : ENABLED (2026-06-30T07:09:27.053Z)
eu-west-2 : ENABLED (2026-06-30T07:09:26.970Z)
eu-west-1 : ENABLED (2026-06-30T07:09:27.033Z)
ap-northeast-2 : ENABLED (2026-06-30T07:09:26.342Z)
ap-northeast-1 : ENABLED (2026-06-30T07:09:26.179Z)
ca-central-1 : ENABLED (2026-06-30T07:09:26.729Z)
sa-east-1 : ENABLED (2026-06-30T07:09:27.425Z)
ap-southeast-1 : ENABLED (2026-06-30T07:09:26.918Z)
eu-central-1 : ENABLED (2026-06-30T07:09:27.062Z)
us-east-2 : ENABLED (2026-06-30T07:09:26.707Z)
us-west-2 : ENABLED (2026-06-30T07:09:26.282Z)
```

![Security Hubが13リージョンで有効になっていることを確認した走査結果](/images/aws-inventory/07-securityhub-scan.png)

このあとの無効化で使うので、リージョン名を変数に取り直しておく。

```powershell
$shEnabled = @()
foreach ($r in $regions) {
    $s = aws securityhub describe-hub --region $r --query 'SubscribedAt' --output text 2>$null
    if ($LASTEXITCODE -eq 0 -and $s) { $shEnabled += $r }
}
$shEnabled
"count: $($shEnabled.Count)"
```

![走査結果を変数に格納し、13件であることを確認](/images/aws-inventory/08-securityhub-count.png)

有効化日時が`2026-06-30T07:09:26`〜`27`の1秒台に収まっている。個別に有効化したのではなく、コンソールから一括で有効化したときの痕跡だ。時刻から、4か月前に進めていたハンズオン教材の作業と一致すると分かった。

**`us-east-1`だけリストに入っていない。**

```powershell
aws securityhub describe-hub --region us-east-1
```

```
aws: [ERROR]: An error occurred (InvalidAccessException) when calling the DescribeHub operation:
Account <アカウントID> is not subscribed to AWS Security Hub
```

![us-east-1だけはSecurity Hubが未サブスクライブだった](/images/aws-inventory/09-securityhub-us-east-1.png)

一括有効化されたはずの中で1つだけ状態が違う。これは以前、個別に無効化した記憶があった。つまり「一括で有効化したものの一部を、あとから個別に無効化した」という履歴が現在の状態に埋まっている。**今の状態だけを見ても、そこに至った経緯は復元できない。**

経緯まで確定させたいなら、CloudTrailのイベント履歴（管理イベントは90日保持）を引く。

```powershell
aws cloudtrail lookup-events `
  --lookup-attributes AttributeKey=EventName,AttributeValue=EnableSecurityHub `
  --region ap-northeast-1 `
  --start-time 2026-06-29 --end-time 2026-07-02 `
  --query 'Events[].[EventTime,Username]' --output table
```

今回は両方とも心当たりがあったので追わなかった。有効化が90日以上前だったこともあり、このアカウントでは追えない状態になっている。

### 無効化する前に決めること

Security Hubを無効化すると検出結果が消える。公式ドキュメントによると、無効化から30日後にアーカイブ済みの検出結果が、90日後にアクティブな検出結果・インサイト・設定が完全に削除される。90日以内に再度有効化すればアクティブな検出結果と設定は復旧し、30日以内ならアーカイブ済みも戻る。

参考: [Security Hub CSPM の無効化](https://docs.aws.amazon.com/ja_jp/securityhub/latest/userguide/securityhub-disable.html)

今回は使っていないリージョンの検出結果なので、残す理由がなかった。残したい場合は、無効化前にS3へエクスポートしておく。

なお、2025年以降のドキュメントでは従来のSecurity Hubが「AWS Security Hub CSPM」という名称に変わっている。CLIのコマンド名（`aws securityhub ...`）は変わっていない。

### 課金を止めるだけなら標準の解除でもいい

Security Hub CSPMの課金は、セキュリティチェック（コントロールの評価）の件数が主体になっている。Security Hub自体を無効化せず、有効になっているセキュリティ基準（FSBP、CISなど）だけを解除しても、チェックは走らなくなる。

```powershell
# 有効な標準を確認
aws securityhub get-enabled-standards --region ap-northeast-1

# ARNを指定して解除
aws securityhub batch-disable-standards `
  --standards-subscription-arns "<get-enabled-standardsで返ってきたARN>" `
  --region ap-northeast-1
```

GuardDutyなど他サービスからの検出結果の集約は残したい、という場合はこちらを選ぶ。今回は集約する必要もなかったので、Security Hub自体を無効化した。

参考: [AWS Security Hub 料金](https://aws.amazon.com/jp/security-hub/pricing/)

### 無効化と確認

```powershell
foreach ($r in $shEnabled) {
    Write-Host "disabling $r ..." -NoNewline
    aws securityhub disable-security-hub --region $r 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host " OK" -ForegroundColor Green }
    else { Write-Host " FAILED" -ForegroundColor Red }
}
```

13リージョンすべてOK。確認する。

```powershell
foreach ($r in $shEnabled) {
    $s = aws securityhub describe-hub --region $r --query 'SubscribedAt' --output text 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host "$r : STILL ENABLED" -ForegroundColor Red }
    else { Write-Host "$r : disabled" -ForegroundColor Green }
}
```

全リージョンで`disabled`。

![13リージョンすべてでdisable-security-hubが成功](/images/aws-inventory/10-securityhub-disable.png)

![13リージョンすべてがdisabledになったことを確認](/images/aws-inventory/11-securityhub-verify.png)

なおこのループには`2>$null`が入っている。ここでは全件成功したので問題にならなかったが、次のGuardDutyでこの書き方に足をすくわれることになる。

### Organizations配下の場合の注意

このアカウントではSecurity Hubの委任管理者を設定していなかったため、単純に無効化できた。

組織で中央設定（central configuration）を使っている場合は、メンバーアカウント側で無効化しても設定ポリシーによって再度有効化される。その場合は委任管理者が設定ポリシーを変更する必要があり、ポリシーはホームリージョンとリンクされた全リージョンに効く。

---

## 棚卸し その2: GuardDuty

同じ日に一括有効化されているなら、GuardDutyも同じ状態のはずだった。

```powershell
$gdEnabled = @()
foreach ($r in $regions) {
    $d = aws guardduty list-detectors --region $r --query 'DetectorIds[0]' --output text 2>$null
    if ($LASTEXITCODE -eq 0 -and $d -and $d -ne "None") {
        $gdEnabled += [pscustomobject]@{ Region = $r; DetectorId = $d }
    }
}
$gdEnabled | Format-Table
"count: $($gdEnabled.Count)"
```

`--query 'DetectorIds[0]'`は空配列に対して`None`という文字列を返すので、その判定を入れている。

### 結果

12リージョンで検出器が存在した。検出器IDの先頭が揃っているのも、一括作成された痕跡だ。

```
Region          DetectorId
------          ----------
ap-south-1      d4cf8bae3fd0506a10e45fd8de55b212
eu-north-1      a6cf8bae4197698faa8d0429815c598e
eu-west-3       66cf8bae4168855048ae689ddb5c273f
eu-west-2       04cf8bae41613f20d89f11f3ba676d9a
eu-west-1       30cf8bae4170afe172d5f6b246c7aed7
ap-northeast-2  d6cf8bae3f57e69cbf9fd84296a958ed
ca-central-1    92cf8bae4146546bd2c28ef4251bf551
sa-east-1       b6cf8bae41dbc0f40fa32afc209e8ee7
ap-southeast-1  f4cf8bae3f889883b69d9632b42688b6
us-east-2       20cf8bae413d53a23d9eb60a9ca0796f
us-west-1       4acf8bae4010fc55b954d4de6bf12061
us-west-2       a8cf8bae412f50c2a8f81eff58fdc540

count: 12
```

**今度は`ap-northeast-1`が入っていない。**

```powershell
aws guardduty list-detectors --region ap-northeast-1
```

```json
{
    "DetectorIds": []
}
```

![GuardDutyの検出器が12リージョンに存在し、東京だけ空配列だった](/images/aws-inventory/12-guardduty-scan.png)

Security HubとGuardDutyで、抜けているリージョンが逆になっている。

| | リージョン数 | ap-northeast-1 | us-east-1 |
|---|---|---|---|
| Security Hub | 13 | あり | なし |
| GuardDuty | 12 | なし | あり |

東京のGuardDutyは、前回の記事の検証環境を片付けたときに削除していた。前回は最初に2アカウント構成を試しており、その際このアカウント自身をGuardDutyのメンバーとして有効化していたためだ。

つまり、**一括有効化された状態の上に、個別の有効化・削除が重なっている**。現在の状態を1回見ただけでは説明がつかない。

### 削除

```powershell
foreach ($x in $gdEnabled) {
    Write-Host "deleting GuardDuty in $($x.Region) ..." -NoNewline
    aws guardduty delete-detector --detector-id $x.DetectorId --region $x.Region 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host " OK" -ForegroundColor Green }
    else { Write-Host " FAILED" -ForegroundColor Red }
}
```

12リージョンすべてで`FAILED`と表示された。

![GuardDutyの削除ループが12リージョンすべてでFAILEDと表示された。エラー出力は2>$nullで捨てられている](/images/aws-inventory/13-guardduty-failed.png)

### FAILEDと出たが、実際には削除できていた

原因を見るため、エラー出力を捨てずに同じループを流し直した。

```powershell
foreach ($x in $gdEnabled) {
    $id  = $x.DetectorId
    $reg = $x.Region
    Write-Host "deleting GuardDuty in $reg ..." -NoNewline
    aws guardduty delete-detector --detector-id $id --region $reg
    if ($LASTEXITCODE -eq 0) { Write-Host " OK" -ForegroundColor Green }
    else { Write-Host " FAILED" -ForegroundColor Red }
}
```

```
deleting GuardDuty in ap-south-1 ...
aws: [ERROR]: An error occurred (BadRequestException) when calling the DeleteDetector operation:
The request is rejected because the input detectorId is not owned by the current account.

Additional error details:
Type: InvalidInputException
 FAILED
```

![エラー出力を表示すると、BadRequestExceptionでnot owned by the current accountと返っていた](/images/aws-inventory/14-guardduty-error-detail.png)

「このアカウントの所有ではない」と言われる。委任管理者の配下に入っているのかと考えて確認したが、そうではなかった。

```powershell
aws sts get-caller-identity                          # 想定どおりのアカウント
aws guardduty list-detectors --region ap-south-1
```

```json
{
    "DetectorIds": []
}
```

![list-detectorsが空配列を返し、get-detectorも同じエラーになった。検出器はすでに削除済みだった](/images/aws-inventory/15-guardduty-already-deleted.png)

**検出器はもう存在しなかった。** 最初のループで削除は成功していて、表示だけが`FAILED`になっていた。

その状態で同じIDを指定し直したので、「存在しない検出器ID」に対して`not owned by the current account`が返っていた。`get-detector`でも同じメッセージが返る。

```powershell
aws guardduty get-detector --detector-id d4cf8bae3fd0506a10e45fd8de55b212 --region ap-south-1
# → BadRequestException: ... is not owned by the current account.
```

削除済みIDに対する応答が`NotFound`ではなくこの文面なのは、かなり紛らわしい。所有権の問題だと読むと、委任管理者やクロスアカウントの設定を疑う方向に進んでしまう。実際そうなった。

全リージョンを確認したところ、検出器は1つも残っていなかった。

```powershell
foreach ($r in $regions) {
    $d = aws guardduty list-detectors --region $r --query 'DetectorIds[0]' --output text 2>$null
    if ($LASTEXITCODE -eq 0 -and $d -and $d -ne "None") {
        Write-Host "$r : STILL EXISTS ($d)" -ForegroundColor Red
    }
}
"done"
```

![全リージョンを再走査しても検出器は残っていなかった](/images/aws-inventory/16-guardduty-verify.png)

:::message
削除が成功しているのに`$LASTEXITCODE`が0以外になった理由は、この検証では特定できていない。1回目の実行時に`2>$null`でエラー出力を捨てていたため、その時点の情報が残っていない。**要検証**。
:::

### ここで何を間違えたか

問題は、**エラー出力を捨てたまま成否判定だけを表示していた**ことだ。

`2>$null`は、走査ループでは有効に働く。無効なリージョンでは必ずエラーが出るので、表示すると画面がエラーで埋まって結果が読めない。ところが同じ書き方を**削除**ループに持ち込むと、失敗したときに理由が一切残らない。

しかも判定ロジック自体は動いているので、ログには`FAILED`という結果だけが積まれる。「正常に失敗を検出した」という形になっていて、あとから見ても何も分からない。

書き分けるならこうなる。

- **状態を調べるループ**: エラーが想定内なので抑制してよい
- **変更を加えるループ**: エラーを抑制しない。想定外の失敗を見落とす

再実行できる形にするなら、事前に取ったIDを信用せず、その場で取り直すほうが安全だ。

```powershell
foreach ($r in $regions) {
    $id = aws guardduty list-detectors --region $r --query 'DetectorIds[0]' --output text 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $id -or $id -eq "None") { continue }

    Write-Host "$r : deleting $id ... " -NoNewline
    aws guardduty delete-detector --detector-id $id --region $r   # エラーは抑制しない
    if ($LASTEXITCODE -eq 0) { Write-Host "OK" -ForegroundColor Green }
    else { Write-Host "FAILED" -ForegroundColor Red }
}
```

存在確認と削除を1つのループに入れているので、2回目以降の実行では削除済みのリージョンをスキップする。

### 削除ではなく停止という選択肢

Security Hubには無効化という状態があったが、GuardDutyは`delete-detector`を実行すると検出結果も一緒に消える。

検出結果を残したまま解析を止めたいなら、検出器を残して停止（suspend）できる。

```powershell
aws guardduty update-detector --detector-id <ID> --no-enable --region <リージョン>
```

停止中は新しい検出結果が生成されなくなる。既存の検出結果は保持される。今回は残す理由がなかったので削除を選んだ。

参考: [Suspending or disabling Amazon GuardDuty](https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_suspend-disable.html)

### 余談: この操作は検知対象になる

自分のアカウントの片付けとしてやっているが、`DeleteDetector`と`UpdateDetector`は、攻撃者が侵害後に監視を潰すときに使うAPIでもある。MITRE ATT&CKでいうT1562.001（Impair Defenses: Disable or Modify Tools）に相当し、ElasticやSigmaの公開ルールセットにも検知ルールが存在する。

本番環境でこの棚卸しをやるなら、**実行前にSOC側へ連絡しておかないとインシデントとして上がる**。オンプレでいえば、監視エージェントを止める作業を無連絡でやるのと同じだ。逆に言えば、この操作が検知されない環境なら、そちらのほうが問題になる。

---

## 棚卸し その3: その他のサービス

### AWS Config

```powershell
foreach ($r in $regions) {
    $c = aws configservice describe-configuration-recorder-status --region $r `
         --query 'ConfigurationRecordersStatus[0].recording' --output text 2>$null
    if ($LASTEXITCODE -eq 0 -and $c -eq "True") {
        Write-Host "$r : Config recording" -ForegroundColor Magenta
    }
}
```

出力なし。どのリージョンでもConfigは動いていなかった。課金内訳にもConfigの名前は出ていない。

Security Hub CSPMの設定変更トリガー型コントロールはAWS Configに依存するため、Configが動いていない状態では評価できない。それでもSecurity Hubの課金は発生していた。

:::message
公式ドキュメントには、定期実行タイプのコントロールについて「課金を防ぐにはSecurity Hub CSPM側でコントロールを無効にする必要がある」「AWS Configのパラメータを変更しても定期的なコントロールには影響しない」という記述がある。今回の課金がすべて定期実行タイプによるものかどうかまでは確認していない。**要確認**。

参考: [Security Hub CSPM で無効化を推奨するコントロール](https://docs.aws.amazon.com/ja_jp/securityhub/latest/userguide/controls-to-disable.html)
:::

Configを止めるだけならレコーダーを停止すればよく、削除までは不要だ。

```powershell
aws configservice stop-configuration-recorder --configuration-recorder-name <名前> --region <リージョン>
```

### S3

```powershell
aws s3api list-buckets --query "Buckets[].[Name,CreationDate]" --output table
```

バケットは1つだけ。`glue-etl-handson-x7f3k9pw`、作成日は2026-09-05。Glueのハンズオンで作ったものだった。

```powershell
aws s3 ls s3://glue-etl-handson-x7f3k9pw --recursive --summarize
```

```
Total Objects: 133
   Total Size: 380750
```

中身は`metadata/v1〜v4.metadata.json`、`snap-*.avro`、`version-hint.text`という構成で、Apache Icebergのテーブルだった。同じパーティションに異なるUUIDのファイルが2組あるので、ジョブを2回実行した形跡がある。

Glue側は空だった。

```powershell
aws glue get-jobs      --query 'Jobs[].[Name,CreatedOn]'  --output table --region ap-northeast-1
aws glue get-crawlers  --query 'Crawlers[].[Name,State]'  --output table --region ap-northeast-1
aws glue get-databases --query 'DatabaseList[].[Name]'    --output table --region ap-northeast-1
```

![S3の合計133オブジェクト・380,750バイト。Glueのジョブ・クローラ・データベースはいずれも空](/images/aws-inventory/17-s3-glue-empty.png)

ジョブ・クローラ・データベースいずれも出力なし。S3のデータだけが残っていた。

### 削除したつもりが消えていない

```powershell
aws s3 rb s3://glue-etl-handson-x7f3k9pw --force
```

オブジェクトの削除ログが大量に流れたあと、最後にこうなった。

```
remove_bucket failed: s3://glue-etl-handson-x7f3k9pw
An error occurred (BucketNotEmpty) when calling the DeleteBucket operation:
The bucket you tried to delete is not empty. You must delete all versions in the bucket.
```

バージョニングが有効だった。

```powershell
aws s3api get-bucket-versioning --bucket glue-etl-handson-x7f3k9pw
aws s3api list-object-versions --bucket glue-etl-handson-x7f3k9pw `
  --query '{Versions:length(Versions),Markers:length(DeleteMarkers)}'
```

```json
{ "Status": "Enabled" }
{ "Versions": 144, "Markers": 144 }
```

`aws s3 rb --force`がやったのは、各オブジェクトに削除マーカーを付けることだけだった。実データは1バイトも消えていない。削除マーカーが144個増えた分、オブジェクトの総数はむしろ増えている。

![バージョニングがEnabled、バージョン144件と削除マーカー144件が残っている](/images/aws-inventory/18-s3-versioning.png)

`s3 ls --recursive --summarize`では133と表示されていたのに、バージョンは144ある。現行バージョンの数とバージョン総数は一致しない。内訳の正確な対応は確認していないが、**オブジェクト数から容量を見積もると、バージョニング有効なバケットでは過小評価になる**という点は押さえておきたい。

正確な容量を見るならCloudWatchのメトリクスを使う。

```powershell
aws cloudwatch get-metric-statistics `
  --namespace AWS/S3 --metric-name BucketSizeBytes `
  --dimensions Name=BucketName,Value=<バケット名> Name=StorageType,Value=StandardStorage `
  --start-time 2026-09-12 --end-time 2026-09-14 --period 86400 --statistics Average `
  --region ap-northeast-1
```

日次更新なので即時性はないが、非現行バージョンを含めた実容量が取れる。

### 全バージョンを削除する

```powershell
$b = "<バケット名>"

do {
    $r = aws s3api list-object-versions --bucket $b --max-keys 500 | ConvertFrom-Json
    $items = @()
    if ($r.Versions)      { $items += $r.Versions      | ForEach-Object { @{ Key=$_.Key; VersionId=$_.VersionId } } }
    if ($r.DeleteMarkers) { $items += $r.DeleteMarkers | ForEach-Object { @{ Key=$_.Key; VersionId=$_.VersionId } } }
    if ($items.Count -eq 0) { break }

    $payload = @{ Objects = $items; Quiet = $true } | ConvertTo-Json -Depth 5 -Compress
    [System.IO.File]::WriteAllText("$PWD\del.json", $payload)
    aws s3api delete-objects --bucket $b --delete file://del.json
    Write-Host "deleted $($items.Count) versions" -ForegroundColor Yellow
} while ($true)

Remove-Item del.json -ErrorAction SilentlyContinue
aws s3api delete-bucket --bucket $b
```

実装上の注意が3つある。

**JSONはBOMなしで書き出す。** Windows PowerShell 5.1の`Out-File -Encoding utf8`はBOM付きで出力するため、AWS CLIのJSONパースが失敗することがある。`[System.IO.File]::WriteAllText()`ならBOMは付かない。PowerShell 7なら`-Encoding utf8NoBOM`が使える。

**`delete-objects`は1回あたり1000件まで。** `--max-keys 500`で取得しているのは、1ページあたりのバージョンと削除マーカーの合計が1000件を超えないようにするため。

**要素が1件のときは配列にならない。** `ConvertTo-Json`は要素数1の配列をオブジェクトとして出力することがある。今回は288件あったので問題にならなかったが、1件のケースを通すなら明示的に配列化する必要がある。

削除後の確認。

```powershell
aws s3api head-bucket --bucket <バケット名>
```

```
aws: [ERROR]: An error occurred (404) when calling the HeadBucket operation: Not Found
```

![head-bucketが404を返し、バケットの削除が完了した](/images/aws-inventory/19-s3-head-bucket-404.png)

404が返ればバケットは消えている。

### 残りのサービス

課金内訳に名前が出ていたサービスを、東京リージョンで順に確認した。

```powershell
aws datazone       list-domains        --query 'items[].[id,name,status]'                --output table --region ap-northeast-1
aws secretsmanager list-secrets        --query 'SecretList[].[Name,CreatedDate]'         --output table --region ap-northeast-1
aws lambda         list-functions      --query 'Functions[].[FunctionName,LastModified]' --output table --region ap-northeast-1
aws stepfunctions  list-state-machines --query 'stateMachines[].[name,creationDate]'     --output table --region ap-northeast-1
aws sqs            list-queues  --region ap-northeast-1
aws sns            list-topics  --region ap-northeast-1
```

![DataZone・Secrets Manager・Lambda・Step Functions・SQS・SNSはいずれも空。KMSのみ2件返った](/images/aws-inventory/20-other-services.png)

いずれも空だった。

**DataZoneとSecrets Managerを優先して確認したのは、どちらも存在するだけで課金が発生する性質があるためだ。** 従量課金のLambdaやSQSは、残っていても呼ばれなければ課金されない。棚卸しの優先度は、金額そのものより課金モデルで決めたほうがいい。

KMSは2件のキーが出た。

```powershell
$keys = (aws kms list-keys --query 'Keys[].KeyId' --output text --region ap-northeast-1) -split '\s+'
foreach ($k in $keys) {
    if (-not $k) { continue }
    Write-Host "--- $k" -ForegroundColor Cyan
    aws kms describe-key --key-id $k --region ap-northeast-1 `
      --query 'KeyMetadata.[KeyManager,KeyState,KeyUsage,Description]' --output text
    aws kms list-aliases --key-id $k --region ap-northeast-1 --query 'Aliases[].AliasName' --output text
}
```

```
AWS  Enabled  ENCRYPT_DECRYPT  Default key that protects my RDS database volumes when no other key is defined
alias/aws/rds

AWS  Enabled  ENCRYPT_DECRYPT  Default key that protects my S3 objects when no other key is defined
alias/aws/s3
```

![2件ともKeyManagerがAWSのAWS管理キーだった](/images/aws-inventory/21-kms-aws-managed.png)

両方とも`KeyManager: AWS`のAWS管理キーだった。該当サービスを初めて使ったときに自動生成され、リソースを消しても残る。削除はできないが、AWS管理キーは無料なので対応も不要だ。

カスタマー管理キー（`KeyManager: CUSTOMER`）ならキー1つにつき月額課金が発生するので、そちらは削除対象になる。KMSキーは即時削除できず、7〜30日の待機期間を設定して削除をスケジュールする形を取る。待機期間中も課金は続く。

RDSのAWS管理キーが残っているのは過去にRDSを触った痕跡だが、課金されないので放置で構わない。

---

## 「消したつもり」の3パターン

今回の作業で、削除したはずのものが残るケースが3種類出た。

### 1. リージョン軸

前回の検証では東京リージョン内のリソースを徹底的に片付けた。CloudWatch Logsのロググループまで消し、Organizationsのサービスアクセスも戻している。それでも、**他の12リージョンで同じサービスが動いていることには気づかなかった**。

片付けの粒度は細かかったが、粒度を測る軸がリージョン内に閉じていた。

### 2. 付随リソース軸

`lambda delete-function`ではCloudWatch Logsのロググループは消えない。関数を消したあとも`/aws/lambda/<関数名>`が残り、既定では保持期間が無期限になる。これは前回の記事でも触れたが、同じ構造の問題だ。

**リソースを作ると、そのリソースの削除では消えないものが付随して生まれる。**

### 3. バージョン軸

`aws s3 rb --force`は現行バージョンに削除マーカーを付けるだけで、バージョン履歴には手を出さない。コマンドは成功したように見えるし、`s3 ls`で一覧を取っても何も出てこない。それでもストレージ課金は続く。

### 共通しているもの

3つとも、**削除コマンド自体は成功している**。今回はたまたまバケット削除の最後でエラーが出たので3に気づけたが、1と2は確認しなければ表に出ない。

言い換えると、**「削除した範囲」と「削除したかった範囲」のずれは、確認しない限り検出されない**。この差分を埋める作業が棚卸しで、そのためのコマンドは自分で用意することになる。

---

## オンプレミスの撤去との違い

自治体の情報システム部門にいた頃も、その後のインフラ業務でも、システムの更改や撤去は何度も経験してきた。そのときの感覚と比べると、違いがはっきりする。

**物理的な設備には「存在する場所」がある。** サーバーを撤去したかどうかは、ラックを見れば分かる。資産管理台帳と現物を突き合わせれば差分が出る。棚卸しという作業自体が、現物と台帳の照合として定義されている。

**AWSには現物にあたるものがない。** 全リージョンにまたがって何が存在するかを一覧する標準的な画面がなく、APIを叩いて自分で集める必要がある。しかも今回のSecurity Hubのように、「有効化されている」という状態はリソースですらない。

AWS Resource Explorerを使えばリージョンをまたいだリソース検索ができる。ただし、

- 対応するリソースタイプに制限がある
- Security Hubが有効かどうかのような**サービスの有効化状態はリソースとして表現されない**ため、この用途では別途APIを叩く必要がある

:::message
GuardDutyについては、Resource Explorerが`guardduty:detector/filter`などのサブリソースに対応しているという発表がある。検出器そのもの（`guardduty:detector`）が対応しているかどうかは未確認で、今回のケースでResource Explorerが使えたかどうかも試していない。**要検証**。
:::

撤去や廃棄を何度かやっていると、「作ったものより消したもののほうが管理が難しい」というのは実感としてある。クラウドではそこに、**消したかどうかを確認する手段も自分で作る**という手間が乗る。

---

## 本番環境ならどうするか

今回は個人の検証環境なので、気づいてから手で潰した。実運用ならこうはいかない。

### 検知を自動化する

**AWS Budgets**でサービス別・リージョン別の閾値を設定すれば、想定外の課金に自動で気づける。今回はCost Explorerをたまたま開いて気づいたので、再現性がない。

ただし金額ベースの検知には限界がある。今回のように月$2程度では、意味のある閾値が引けない。「先月比で増えた」という**Cost Anomaly Detection**のほうが向いている場面だ。

### 展開そのものを止める

より根本的には、使わないリージョンでリソースを作らせない。OrganizationsのSCPで`aws:RequestedRegion`を制限すれば、ハンズオンの手順どおりに全リージョン有効化しようとしても弾かれる。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyAllOutsideApprovedRegions",
      "Effect": "Deny",
      "NotAction": [
        "iam:*", "organizations:*", "sts:*",
        "cloudfront:*", "route53:*", "support:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": ["ap-northeast-1", "us-east-1"]
        }
      }
    }
  ]
}
```

`NotAction`にグローバルサービスを並べているのは、IAMやRoute 53などがリージョンを持たない（`us-east-1`として扱われる）ため。ここを漏らすと、承認リージョンで作業していてもIAM操作が拒否される。

:::message alert
**SCPは管理アカウント自身には適用されない。** 統制をかけるなら、検証用のメンバーアカウントを作ってそちらで作業する構成を取る。

参考: [サービスコントロールポリシー (SCP)](https://docs.aws.amazon.com/ja_jp/organizations/latest/userguide/orgs_manage_policies_scps.html)
:::

上記のポリシーは未検証で、この記事では適用していない。別途検証する。

### 検知の設計として

12リージョンでGuardDutyが動いていた状態を、セキュリティの観点で見直しておく。

東京の検出器を削除した時点で、このアカウントの状態はこうなっていた。

- **東京**: 検出器なし = 検知なし
- **他12リージョン**: 検出器あり。ただしEventBridgeルールもLambdaも通知先もない

つまり、**検知だけが動いていて、その結果が誰にも届かない状態**だった。前回の記事では「監視範囲がリージョン1つ分しかない」を問題点として挙げたが、実際の環境では逆の形で穴が開いていた。対応の届かないリージョンで検知だけが回っていたことになる。

SOCの運用でいえば、アラートは上がっているが受け手のいないセンサーが12台あるのと同じだ。攻撃者が使っていないリージョンを選ぶのは、まさにこの状態を期待してのことなので、構成として筋が悪い。

実運用で全リージョンをカバーするなら、

- GuardDutyを全リージョンで有効化する（またはOrganizationsの自動有効化を使う）
- Security Hubのクロスリージョン集約（`create-finding-aggregator`）で1つの集約リージョンに寄せる
- EventBridgeルールも全リージョンに展開するか、集約リージョンに寄せたイベントを処理する

という形を取る。**検知と対応の範囲を揃える**のが要点で、片方だけ広げても意味がない。

コスト上は、使わないリージョンでGuardDutyを止めるのが合理的に見える。ただしセキュリティ上は逆で、使っていないリージョンこそ攻撃者に選ばれる。「使っていないから止める」と「使っていないから監視する」のどちらを取るかは、コストと運用体制の兼ね合いで決まる。今回は個人の検証環境なので前者を選んだが、本番環境なら判断が変わる。

---

## コスト

今回止めたものの規模。

| サービス | 対応 | 9/1〜9/14の課金 |
|---|---|---|
| Security Hub | 13リージョンで無効化 | $0.93 |
| GuardDuty | 12リージョンで検出器削除 | $0.01 |
| S3 | バケット削除（バージョン込み） | $0.01 |
| その他 | 実体なし | $0.00 |

年間に直せば$25程度。金額としては小さいが、**放置したまま検証規模を広げると、リージョン数に比例して増える**性質のものだ。GuardDutyはVPC Flow LogsやDNSログの解析量で課金されるので、12リージョンでEC2を動かし始めれば一気に効いてくる。

課金内訳の`$0.00`についても補足しておく。`$0.00`は「存在しない」ではなく「今月はまだ課金対象の使い方をしていない」という意味だ。**Cost Explorerは課金の記録であって、資産の一覧ではない。** 今回、名前が出ているのに実体がなかったサービス（Glue、DataZone、Secrets Managerなど）もあれば、名前が出ていて実体もあったサービスもあった。一次フィルタとしては使えるが、それ以上ではない。

---

## まとめ

この棚卸しで確認できたこと。

1. **セキュリティサービスは、使っていないリージョンでも動き続ける。** コンソールはリージョン単位でしか見えないので、全リージョンを走査しないと把握できない
2. **削除コマンドが成功しても、対象の全体が消えたとは限らない。** リージョン軸、付随リソース軸、バージョン軸の3種類の残り方があった
3. **状態を調べるループと、変更を加えるループで、エラーの扱いを変える。** 前者はエラーを抑制してよいが、後者で抑制すると失敗の理由が残らない
4. **エラー名は原因を指しているとは限らない。** `RequestExpired`の実体は認証情報の期限切れで、時刻とは無関係だった。削除済みの検出器IDに対する`not owned by the current account`も同様
5. **`$0.00`は「存在しない」ではない。** Cost Explorerは課金の記録であって、資産の一覧ではない
6. **検知と対応の範囲は揃える。** 検知だけが広がっている状態は、監視していないより状況が悪い

3と4は、どちらも「情報を捨てたせいで分からなくなった」という同じ構造をしている。エラー出力を捨てたこと、エラー名を鵜呑みにしたこと。障害切り分けでは基本的な話だが、自動化したスクリプトの中では気づきにくい形で現れる。

次は、SCPによるリージョン制限を実際に組んで検証する。今回のような展開を構造的に防げるかどうかを、メンバーアカウントを作って確認する。
