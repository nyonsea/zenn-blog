<#
.SYNOPSIS
    VPC Lattice Auth Policy 検証環境の一括削除スクリプト

.DESCRIPTION
    検証で作成したリソースを、依存関係の順に削除する。
    リソースIDは名前から自動的に引くため、構築時のセッション変数は不要。

    削除順:
      1. アクセスログサブスクリプション
      2. Service Network への Service 関連付け（非同期・待機あり）
      3. Listener
      4. ターゲット登録解除 → Target Group
      5. Service
      6. Service Network への VPC 関連付け（非同期・待機あり）
      7. Service Network
      8. EC2（terminate 完了まで待機）
      9. IAM（インラインポリシー → インスタンスプロファイル → ロール）
     10. CloudWatch Logs ロググループ
     11. ネットワーク（SG → RTB → IGW → Subnet → VPC）

.NOTES
    存在しないリソースはスキップして続行する（冪等）。
    実行前に -WhatIf 相当の確認をしたい場合は -DryRun を付ける。
#>

[CmdletBinding()]
param(
    [string]$Region       = "ap-northeast-1",
    [string]$VpcName      = "lattice-lab-vpc",
    [string]$SnName       = "lattice-lab-sn",
    [string]$SvcName      = "my-lattice-service",
    [string]$TgName       = "lattice-lab-tg",
    [string]$LogGroupName = "/vpc-lattice/lattice-lab",
    [string[]]$RoleNames  = @("lattice-allowed-role", "lattice-denied-role"),
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"
$env:AWS_DEFAULT_REGION = $Region

# ------------------------------------------------------------------
# ヘルパー
# ------------------------------------------------------------------
function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-Skip {
    param([string]$Message)
    Write-Host "  [skip] $Message" -ForegroundColor DarkGray
}

function Write-Done {
    param([string]$Message)
    Write-Host "  [done] $Message" -ForegroundColor Green
}

# AWS CLI を実行し、失敗しても停止しない。出力は文字列で返す。
function Invoke-Aws {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

    if ($DryRun) {
        Write-Host "  [dry-run] aws $($Args -join ' ')" -ForegroundColor Yellow
        return $null
    }
    $out = & aws @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        # 「存在しない」系のエラーは想定内なので黙って握る
        if ($out -match "NotFound|does not exist|ResourceNotFound|NoSuchEntity|InvalidGroup\.NotFound") {
            return $null
        }
        Write-Host "  [warn] $out" -ForegroundColor Yellow
        return $null
    }
    return $out
}

# 値が空文字・None・null のいずれかなら $true
function Test-Empty {
    param($Value)
    return ($null -eq $Value) -or ("$Value".Trim() -in @("", "None", "null"))
}

# 関連付けの削除は非同期。消えるまでポーリングする。
function Wait-Gone {
    param(
        [scriptblock]$Check,
        [string]$Label,
        [int]$TimeoutSec = 180
    )
    if ($DryRun) { return }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $remaining = & $Check
        if (Test-Empty $remaining) {
            Write-Done "$Label の削除完了"
            return
        }
        Write-Host "  ... $Label の削除待ち" -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }
    Write-Host "  [warn] $Label が $TimeoutSec 秒以内に消えなかった。手動で確認してください" -ForegroundColor Yellow
}

Write-Host "VPC Lattice 検証環境 片付けスクリプト" -ForegroundColor White
Write-Host "リージョン: $Region"
if ($DryRun) { Write-Host "DRY RUN モード（実際には削除しません）" -ForegroundColor Yellow }

# ------------------------------------------------------------------
# 0. リソースIDの解決
# ------------------------------------------------------------------
Write-Step "リソースIDの解決"

$snId = Invoke-Aws vpc-lattice list-service-networks `
    --query "items[?name=='$SnName'].id | [0]" --output text
$svcId = Invoke-Aws vpc-lattice list-services `
    --query "items[?name=='$SvcName'].id | [0]" --output text
$tgId = Invoke-Aws vpc-lattice list-target-groups `
    --query "items[?name=='$TgName'].id | [0]" --output text
$vpcId = Invoke-Aws ec2 describe-vpcs `
    --filters "Name=tag:Name,Values=$VpcName" `
    --query "Vpcs[0].VpcId" --output text

foreach ($pair in @(
    @{ Name = "Service Network"; Id = $snId },
    @{ Name = "Service";         Id = $svcId },
    @{ Name = "Target Group";    Id = $tgId },
    @{ Name = "VPC";             Id = $vpcId }
)) {
    if (Test-Empty $pair.Id) {
        Write-Skip "$($pair.Name): 見つからない（削除済み）"
    } else {
        Write-Host "  $($pair.Name): $($pair.Id)"
    }
}

# ------------------------------------------------------------------
# 1. アクセスログサブスクリプション
# ------------------------------------------------------------------
Write-Step "1. アクセスログサブスクリプション"

foreach ($resId in @($svcId, $snId)) {
    if (Test-Empty $resId) { continue }
    $alsIds = Invoke-Aws vpc-lattice list-access-log-subscriptions `
        --resource-identifier $resId --query "items[].id" --output text
    if (Test-Empty $alsIds) {
        Write-Skip "$resId : サブスクリプションなし"
        continue
    }
    foreach ($alsId in ($alsIds -split "\s+" | Where-Object { $_ })) {
        Invoke-Aws vpc-lattice delete-access-log-subscription `
            --access-log-subscription-identifier $alsId | Out-Null
        Write-Done "アクセスログサブスクリプション $alsId"
    }
}

# ------------------------------------------------------------------
# 2. Service Network への Service 関連付け
#    Service を削除する前に、必ず関連付けを解除する必要がある
# ------------------------------------------------------------------
Write-Step "2. Service Network - Service 関連付けの解除"

if (-not (Test-Empty $snId)) {
    $snsaIds = Invoke-Aws vpc-lattice list-service-network-service-associations `
        --service-network-identifier $snId --query "items[].id" --output text

    if (Test-Empty $snsaIds) {
        Write-Skip "関連付けなし"
    } else {
        foreach ($id in ($snsaIds -split "\s+" | Where-Object { $_ })) {
            Invoke-Aws vpc-lattice delete-service-network-service-association `
                --service-network-service-association-identifier $id | Out-Null
            Write-Host "  削除要求: $id"
        }
        Wait-Gone -Label "Service 関連付け" -Check {
            Invoke-Aws vpc-lattice list-service-network-service-associations `
                --service-network-identifier $snId --query "items[].id" --output text
        }
    }
}

# ------------------------------------------------------------------
# 3. Listener
# ------------------------------------------------------------------
Write-Step "3. Listener"

if (-not (Test-Empty $svcId)) {
    $listenerIds = Invoke-Aws vpc-lattice list-listeners `
        --service-identifier $svcId --query "items[].id" --output text
    if (Test-Empty $listenerIds) {
        Write-Skip "Listener なし"
    } else {
        foreach ($id in ($listenerIds -split "\s+" | Where-Object { $_ })) {
            Invoke-Aws vpc-lattice delete-listener `
                --service-identifier $svcId --listener-identifier $id | Out-Null
            Write-Done "Listener $id"
        }
    }
}

# ------------------------------------------------------------------
# 4. ターゲット登録解除 → Target Group
#    ターゲットが登録されたままだと Target Group は削除できない
# ------------------------------------------------------------------
Write-Step "4. Target Group"

if (-not (Test-Empty $tgId)) {
    $targetIds = Invoke-Aws vpc-lattice list-targets `
        --target-group-identifier $tgId --query "items[].id" --output text

    if (-not (Test-Empty $targetIds)) {
        $targetArgs = @()
        foreach ($t in ($targetIds -split "\s+" | Where-Object { $_ })) {
            $targetArgs += "id=$t"
        }
        Invoke-Aws vpc-lattice deregister-targets `
            --target-group-identifier $tgId --targets @targetArgs | Out-Null
        Write-Done "ターゲット登録解除: $($targetArgs -join ', ')"

        Wait-Gone -Label "ターゲット登録解除" -TimeoutSec 120 -Check {
            Invoke-Aws vpc-lattice list-targets `
                --target-group-identifier $tgId --query "items[].id" --output text
        }
    }

    Invoke-Aws vpc-lattice delete-target-group --target-group-identifier $tgId | Out-Null
    Write-Done "Target Group $tgId"
}

# ------------------------------------------------------------------
# 5. Service
# ------------------------------------------------------------------
Write-Step "5. Service"

if (-not (Test-Empty $svcId)) {
    Invoke-Aws vpc-lattice delete-service --service-identifier $svcId | Out-Null
    Write-Done "Service $svcId"
} else {
    Write-Skip "Service なし"
}

# ------------------------------------------------------------------
# 6. Service Network への VPC 関連付け
# ------------------------------------------------------------------
Write-Step "6. Service Network - VPC 関連付けの解除"

if (-not (Test-Empty $snId)) {
    $snvaIds = Invoke-Aws vpc-lattice list-service-network-vpc-associations `
        --service-network-identifier $snId --query "items[].id" --output text

    if (Test-Empty $snvaIds) {
        Write-Skip "VPC 関連付けなし"
    } else {
        foreach ($id in ($snvaIds -split "\s+" | Where-Object { $_ })) {
            Invoke-Aws vpc-lattice delete-service-network-vpc-association `
                --service-network-vpc-association-identifier $id | Out-Null
            Write-Host "  削除要求: $id"
        }
        Wait-Gone -Label "VPC 関連付け" -Check {
            Invoke-Aws vpc-lattice list-service-network-vpc-associations `
                --service-network-identifier $snId --query "items[].id" --output text
        }
    }
}

# ------------------------------------------------------------------
# 7. Service Network
# ------------------------------------------------------------------
Write-Step "7. Service Network"

if (-not (Test-Empty $snId)) {
    Invoke-Aws vpc-lattice delete-service-network --service-network-identifier $snId | Out-Null
    Write-Done "Service Network $snId"
} else {
    Write-Skip "Service Network なし"
}

# ------------------------------------------------------------------
# 8. EC2
#    ENI が残っていると Security Group を削除できないため、
#    terminate の完了まで待つ
# ------------------------------------------------------------------
Write-Step "8. EC2 インスタンス"

if (-not (Test-Empty $vpcId)) {
    $instanceIds = Invoke-Aws ec2 describe-instances `
        --filters "Name=vpc-id,Values=$vpcId" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
        --query "Reservations[].Instances[].InstanceId" --output text

    if (Test-Empty $instanceIds) {
        Write-Skip "対象インスタンスなし"
    } else {
        $idList = @($instanceIds -split "\s+" | Where-Object { $_ })
        Write-Host "  対象: $($idList -join ', ')"
        Invoke-Aws ec2 terminate-instances --instance-ids @idList | Out-Null

        if (-not $DryRun) {
            Write-Host "  terminate 完了を待機中（数分かかる）..." -ForegroundColor DarkGray
            & aws ec2 wait instance-terminated --instance-ids @idList 2>&1 | Out-Null
        }
        Write-Done "EC2 terminate 完了"
    }
}

# ------------------------------------------------------------------
# 9. IAM
#    重要: インラインポリシーとインスタンスプロファイルを先に外さないと
#          delete-role が DeleteConflict で失敗する
# ------------------------------------------------------------------
Write-Step "9. IAM ロール"

foreach ($role in $RoleNames) {
    Write-Host "  --- $role ---"

    # 9-1. インラインポリシー（put-role-policy で作ったもの）
    $inlinePolicies = Invoke-Aws iam list-role-policies `
        --role-name $role --query "PolicyNames[]" --output text
    if (-not (Test-Empty $inlinePolicies)) {
        foreach ($pol in ($inlinePolicies -split "\s+" | Where-Object { $_ })) {
            Invoke-Aws iam delete-role-policy --role-name $role --policy-name $pol | Out-Null
            Write-Done "インラインポリシー $pol"
        }
    }

    # 9-2. アタッチされた管理ポリシー
    $attached = Invoke-Aws iam list-attached-role-policies `
        --role-name $role --query "AttachedPolicies[].PolicyArn" --output text
    if (-not (Test-Empty $attached)) {
        foreach ($arn in ($attached -split "\s+" | Where-Object { $_ })) {
            Invoke-Aws iam detach-role-policy --role-name $role --policy-arn $arn | Out-Null
            Write-Done "管理ポリシー デタッチ $arn"
        }
    }

    # 9-3. インスタンスプロファイル
    $profiles = Invoke-Aws iam list-instance-profiles-for-role `
        --role-name $role --query "InstanceProfiles[].InstanceProfileName" --output text
    if (-not (Test-Empty $profiles)) {
        foreach ($prof in ($profiles -split "\s+" | Where-Object { $_ })) {
            Invoke-Aws iam remove-role-from-instance-profile `
                --instance-profile-name $prof --role-name $role | Out-Null
            Invoke-Aws iam delete-instance-profile --instance-profile-name $prof | Out-Null
            Write-Done "インスタンスプロファイル $prof"
        }
    }

    # 9-4. ロール本体
    Invoke-Aws iam delete-role --role-name $role | Out-Null
    Write-Done "ロール $role"
}

# ------------------------------------------------------------------
# 10. CloudWatch Logs
# ------------------------------------------------------------------
Write-Step "10. CloudWatch Logs ロググループ"

Invoke-Aws logs delete-log-group --log-group-name $LogGroupName | Out-Null
Write-Done "ロググループ $LogGroupName"

# ------------------------------------------------------------------
# 11. ネットワーク
#     順序: SG → ルートテーブル関連付け解除 → RTB → IGW → Subnet → VPC
# ------------------------------------------------------------------
Write-Step "11. ネットワーク"

if (Test-Empty $vpcId) {
    Write-Skip "VPC なし（削除済み）"
} else {

    # 11-1. Security Group（default は削除できないので除外）
    #       ENI が残っていると失敗するため、数回リトライする
    $sgIds = Invoke-Aws ec2 describe-security-groups `
        --filters "Name=vpc-id,Values=$vpcId" `
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text

    if (-not (Test-Empty $sgIds)) {
        foreach ($sg in ($sgIds -split "\s+" | Where-Object { $_ })) {
            $deleted = $false
            for ($i = 1; $i -le 6; $i++) {
                $r = Invoke-Aws ec2 delete-security-group --group-id $sg
                Start-Sleep -Seconds 1
                $still = Invoke-Aws ec2 describe-security-groups `
                    --group-ids $sg --query "SecurityGroups[0].GroupId" --output text
                if (Test-Empty $still) { $deleted = $true; break }
                Write-Host "  ... SG $sg の削除待ち（ENI 解放待ち $i/6）" -ForegroundColor DarkGray
                Start-Sleep -Seconds 15
            }
            if ($deleted) { Write-Done "Security Group $sg" }
            else { Write-Host "  [warn] SG $sg を削除できなかった" -ForegroundColor Yellow }
        }
    }

    # 11-2. ルートテーブル（メインルートテーブルは削除不可なので除外）
    $rtbJson = Invoke-Aws ec2 describe-route-tables `
        --filters "Name=vpc-id,Values=$vpcId" --output json
    if (-not (Test-Empty $rtbJson)) {
        $rtbs = ($rtbJson | ConvertFrom-Json).RouteTables
        foreach ($rtb in $rtbs) {
            $isMain = $false
            foreach ($assoc in $rtb.Associations) {
                if ($assoc.Main) { $isMain = $true; continue }
                Invoke-Aws ec2 disassociate-route-table `
                    --association-id $assoc.RouteTableAssociationId | Out-Null
            }
            if ($isMain) {
                Write-Skip "メインルートテーブル $($rtb.RouteTableId) は VPC 削除時に消える"
                continue
            }
            Invoke-Aws ec2 delete-route-table --route-table-id $rtb.RouteTableId | Out-Null
            Write-Done "ルートテーブル $($rtb.RouteTableId)"
        }
    }

    # 11-3. Internet Gateway
    $igwId = Invoke-Aws ec2 describe-internet-gateways `
        --filters "Name=attachment.vpc-id,Values=$vpcId" `
        --query "InternetGateways[0].InternetGatewayId" --output text
    if (-not (Test-Empty $igwId)) {
        Invoke-Aws ec2 detach-internet-gateway --internet-gateway-id $igwId --vpc-id $vpcId | Out-Null
        Invoke-Aws ec2 delete-internet-gateway --internet-gateway-id $igwId | Out-Null
        Write-Done "Internet Gateway $igwId"
    }

    # 11-4. サブネット
    $subnetIds = Invoke-Aws ec2 describe-subnets `
        --filters "Name=vpc-id,Values=$vpcId" --query "Subnets[].SubnetId" --output text
    if (-not (Test-Empty $subnetIds)) {
        foreach ($sn in ($subnetIds -split "\s+" | Where-Object { $_ })) {
            Invoke-Aws ec2 delete-subnet --subnet-id $sn | Out-Null
            Write-Done "サブネット $sn"
        }
    }

    # 11-5. VPC
    Invoke-Aws ec2 delete-vpc --vpc-id $vpcId | Out-Null
    Write-Done "VPC $vpcId"
}

# ------------------------------------------------------------------
# 12. 残存確認
# ------------------------------------------------------------------
Write-Step "12. 残存確認"

if ($DryRun) {
    Write-Host "DRY RUN のため確認をスキップします" -ForegroundColor Yellow
    return
}

$leftovers = @()

$r = Invoke-Aws vpc-lattice list-service-networks --query "items[?name=='$SnName'].id" --output text
if (-not (Test-Empty $r)) { $leftovers += "Service Network: $r" }

$r = Invoke-Aws vpc-lattice list-services --query "items[?name=='$SvcName'].id" --output text
if (-not (Test-Empty $r)) { $leftovers += "Service: $r" }

$r = Invoke-Aws vpc-lattice list-target-groups --query "items[?name=='$TgName'].id" --output text
if (-not (Test-Empty $r)) { $leftovers += "Target Group: $r" }

$r = Invoke-Aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VpcName" `
    --query "Vpcs[].VpcId" --output text
if (-not (Test-Empty $r)) { $leftovers += "VPC: $r" }

foreach ($role in $RoleNames) {
    $r = Invoke-Aws iam get-role --role-name $role --query "Role.RoleName" --output text
    if (-not (Test-Empty $r)) { $leftovers += "IAM Role: $r" }
}

Write-Host ""
if ($leftovers.Count -eq 0) {
    Write-Host "すべて削除されました。課金対象リソースは残っていません。" -ForegroundColor Green
} else {
    Write-Host "以下が残っています。手動で確認してください:" -ForegroundColor Yellow
    $leftovers | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "課金確認: Billing コンソールで VPC Lattice / EC2 の当日利用分を確認することを推奨します。" -ForegroundColor White
