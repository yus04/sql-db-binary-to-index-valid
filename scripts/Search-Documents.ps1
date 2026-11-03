#Requires -Version 7.0
<#
.SYNOPSIS
    インデックスを検索し、資料本文のハイライトとメタデータ (クレーム情報) を表示する。
.EXAMPLE
    ./scripts/Search-Documents.ps1 -Query '硬度不足'
.EXAMPLE
    ./scripts/Search-Documents.ps1 -Query '接地' -Filter "severity eq '中' and document_type eq '報告資料'"
#>
[CmdletBinding()]
param(
    [string]$Query = '*',
    # OData フィルター (例: "claim_category eq '品質不良'")
    [string]$Filter,
    [int]$Top = 10,
    [string]$DeploymentName = 'sql-binary-search-poc'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"

$endpoint = (Get-DeploymentOutputs -DeploymentName $DeploymentName).searchEndpoint

$body = [ordered]@{
    search           = $Query
    top              = $Top
    count            = $true
    select           = 'claim_number,customer_name,product_name,claim_category,severity,status,incident_date,document_type,file_name,incident_summary'
    highlight        = 'content,incident_summary'
    highlightPreTag  = '['
    highlightPostTag = ']'
}
if ($Filter) { $body.filter = $Filter }

$result = Invoke-SearchApi -Endpoint $endpoint -Path "indexes/$SearchIndexName/docs/search" -Method Post -Body ($body | ConvertTo-Json)

Write-Host "ヒット件数: $($result.'@odata.count')" -ForegroundColor Green
foreach ($doc in $result.value) {
    Write-Host ''
    Write-Host ("[{0:N2}] {1} / {2} ({3})" -f $doc.'@search.score', $doc.claim_number, $doc.file_name, $doc.document_type) -ForegroundColor Cyan
    Write-Host "  顧客   : $($doc.customer_name)"
    Write-Host "  製品   : $($doc.product_name)"
    Write-Host "  区分   : $($doc.claim_category) / 重要度: $($doc.severity) / 状況: $($doc.status) / 発生日: $($doc.incident_date)"
    Write-Host "  発生事象: $($doc.incident_summary)"
    $highlights = $doc.PSObject.Properties['@search.highlights']
    if ($highlights) {
        foreach ($field in $highlights.Value.PSObject.Properties) {
            foreach ($fragment in $field.Value) { Write-Host "  … $fragment" -ForegroundColor DarkGray }
        }
    }
}
