#Requires -Version 7.0
<#
.SYNOPSIS
    検証環境を一括構築する。
      1. Bicep で Azure リソース・マネージド ID・RBAC をプロビジョニング (リソースグループに SecurityControl: Ignore タグ)
      2. SQL Database のテーブル作成 / 変更の追跡有効化 / Functions MI のデータベースユーザー作成
      3. AI Search のデータソース / インデックス / インデクサー作成
      4. Azure Functions へ関数コードをデプロイ
    実行者には対象サブスクリプションの所有者 (またはロール割り当て権限を含むロール) が必要。
.EXAMPLE
    az login
    ./deploy.ps1
.EXAMPLE
    ./deploy.ps1 -ResourceGroupName rg-my-poc -Location japanwest
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-sql-binary-search-poc',
    [string]$Location = 'japaneast',
    [string]$DeploymentName = 'sql-binary-search-poc',
    # SQL Database のファイアウォールで許可するクライアント IP。省略時は自動取得する
    [string]$ClientIpAddress,
    [switch]$SkipFunctionPublish
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/scripts/common.ps1"

foreach ($tool in @('az') + ($SkipFunctionPublish ? @() : @('func'))) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool コマンドが見つかりません。README の前提条件を確認してください。" }
}

Write-Step '1/5 サインインユーザーとクライアント IP を取得'
$user = Invoke-AzCli @('ad', 'signed-in-user', 'show', '--query', '{id:id, upn:userPrincipalName}', '-o', 'json') | ConvertFrom-Json
if (-not $ClientIpAddress) {
    $ClientIpAddress = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
}
$subscription = Invoke-AzCli @('account', 'show', '--query', 'name', '-o', 'tsv')
Write-Host "  subscription : $subscription"
Write-Host "  user         : $($user.upn) ($($user.id))"
Write-Host "  client IP    : $ClientIpAddress"

Write-Step "2/5 Bicep をデプロイ (リソースグループ: $ResourceGroupName / $Location)"
Invoke-AzCli @(
    'deployment', 'sub', 'create',
    '--name', $DeploymentName,
    '--location', $Location,
    '--template-file', (Join-Path $PSScriptRoot 'infra/main.bicep'),
    '--parameters',
    "resourceGroupName=$ResourceGroupName",
    "location=$Location",
    "principalId=$($user.id)",
    "principalName=$($user.upn)",
    "clientIpAddress=$ClientIpAddress",
    '--only-show-errors', '-o', 'none'
) | Out-Null
$outputs = Get-DeploymentOutputs -DeploymentName $DeploymentName
$outputs | Format-List

Write-Step '3/5 SQL Database を初期化'
& (Join-Path $PSScriptRoot 'scripts/Initialize-Database.ps1') -DeploymentName $DeploymentName

Write-Step '4/5 AI Search を初期化'
& (Join-Path $PSScriptRoot 'scripts/Initialize-SearchIndex.ps1') -DeploymentName $DeploymentName

if (-not $SkipFunctionPublish) {
    # テーブルと変更の追跡が有効になった後にデプロイし、SQL トリガーを確実に開始させる
    Write-Step "5/5 Azure Functions ($($outputs.functionAppName)) へ関数コードをデプロイ"
    Push-Location (Join-Path $PSScriptRoot 'src/function')
    try {
        func azure functionapp publish $outputs.functionAppName --python
        if ($LASTEXITCODE -ne 0) { throw "func azure functionapp publish failed (exit code $LASTEXITCODE)" }
    }
    finally {
        Pop-Location
    }
}

Write-Host "`n構築が完了しました。次に ./scripts/Register-SampleData.ps1 を実行してデータを登録してください。" -ForegroundColor Green
