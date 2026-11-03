#Requires -Version 7.0
<#
.SYNOPSIS
    Azure AI Search にデータソース・インデックス・インデクサーを作成 (更新) する。
.DESCRIPTION
    定義は search/*.json。データソースは AI Search のシステム割り当てマネージド ID で Blob に接続する
    (接続文字列に ResourceId のみを指定し、キーは使用しない)。
#>
[CmdletBinding()]
param(
    [string]$DeploymentName = 'sql-binary-search-poc'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"

$outputs = Get-DeploymentOutputs -DeploymentName $DeploymentName
$searchDir = Join-Path $PSScriptRoot '../search'

$definitions = @(
    @{ Collection = 'datasources'; File = 'datasource.json' }
    @{ Collection = 'indexes'; File = 'index.json' }
    @{ Collection = 'indexers'; File = 'indexer.json' }
)

foreach ($definition in $definitions) {
    $json = (Get-Content -Path (Join-Path $searchDir $definition.File) -Raw).
        Replace('__STORAGE_ACCOUNT_ID__', $outputs.storageAccountId).
        Replace('__CONTAINER_NAME__', $outputs.documentContainerName)
    $name = ($json | ConvertFrom-Json).name

    Write-Step "AI Search: $($definition.Collection)/$name を作成"
    [void](Invoke-SearchApi -Endpoint $outputs.searchEndpoint -Path "$($definition.Collection)/$name" -Method Put -Body $json)
}

Write-Host 'AI Search の初期化が完了しました (インデクサーは 5 分間隔で実行されます)。' -ForegroundColor Green
