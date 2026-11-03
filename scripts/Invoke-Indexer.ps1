#Requires -Version 7.0
<#
.SYNOPSIS
    インデクサーを即時実行し、完了まで待って結果とインデックスのドキュメント数を表示する。
    (インデクサーは 5 分間隔でも自動実行される)
#>
[CmdletBinding()]
param(
    [string]$DeploymentName = 'sql-binary-search-poc',
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"

$endpoint = (Get-DeploymentOutputs -DeploymentName $DeploymentName).searchEndpoint

Write-Step "インデクサー $SearchIndexerName を実行"
try {
    [void](Invoke-SearchApi -Endpoint $endpoint -Path "indexers/$SearchIndexerName/run" -Method Post)
}
catch {
    # 409: 既に実行中
    if ($_.Exception -isnot [Microsoft.PowerShell.Commands.HttpResponseException] -or [int]$_.Exception.Response.StatusCode -ne 409) { throw }
    Write-Host '既に実行中のため、完了を待機します。'
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Seconds 5
    $status = Invoke-SearchApi -Endpoint $endpoint -Path "indexers/$SearchIndexerName/status"
    $last = $status.lastResult
} while (($null -eq $last -or $last.status -eq 'inProgress') -and (Get-Date) -lt $deadline)

if ($null -eq $last) { throw 'インデクサーの実行結果を取得できませんでした。' }

$last | Select-Object status, startTime, endTime, itemsProcessed, itemsFailed | Format-List
foreach ($e in $last.errors) { Write-Warning "error  : $($e.key) $($e.errorMessage)" }
foreach ($w in $last.warnings) { Write-Warning "warning: $($w.key) $($w.message)" }

$count = Invoke-SearchApi -Endpoint $endpoint -Path "indexes/$SearchIndexName/docs/`$count"
Write-Host "インデックス $SearchIndexName のドキュメント数: $count" -ForegroundColor Green
