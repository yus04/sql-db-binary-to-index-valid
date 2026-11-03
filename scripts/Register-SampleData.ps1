#Requires -Version 7.0
<#
.SYNOPSIS
    sample-data/claims.json の定義に従い、資料ファイルを VARBINARY として dbo.Claims に 1 件ずつ登録する。
.DESCRIPTION
    登録 (INSERT) をトリガーに Azure Functions (SQL トリガー) が起動し、Blob Storage へアップロードされる。
    同じ ClaimNumber + FileName のレコードが既に存在する場合はスキップする。
.EXAMPLE
    ./scripts/Register-SampleData.ps1
.EXAMPLE
    ./scripts/Register-SampleData.ps1 -IntervalSeconds 10
#>
[CmdletBinding()]
param(
    [string]$DeploymentName = 'sql-binary-search-poc',
    [string]$DataFile = (Join-Path $PSScriptRoot '../sample-data/claims.json'),
    [string]$DocumentDirectory = (Join-Path $PSScriptRoot '../sample-data/documents'),
    # 1 件ごとに待機する秒数 (トリガーの発火を 1 件ずつ観察したい場合に指定)
    [int]$IntervalSeconds = 0
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"

$outputs = Get-DeploymentOutputs -DeploymentName $DeploymentName
$records = Get-Content -Path $DataFile -Raw -Encoding utf8 | ConvertFrom-Json

$insertSql = @'
IF EXISTS (SELECT 1 FROM dbo.Claims WHERE ClaimNumber = @ClaimNumber AND FileName = @FileName)
    SELECT CAST(NULL AS INT);
ELSE
    INSERT INTO dbo.Claims (
        ClaimNumber, ReceivedDate, CustomerName, ProductName, LotNumber, ClaimCategory, Severity,
        IncidentDate, IncidentSummary, Status, DocumentType, FileName, ContentType, FileData)
    OUTPUT INSERTED.ClaimId
    VALUES (
        @ClaimNumber, @ReceivedDate, @CustomerName, @ProductName, @LotNumber, @ClaimCategory, @Severity,
        @IncidentDate, @IncidentSummary, @Status, @DocumentType, @FileName, @ContentType, @FileData);
'@

# パラメーター名, 型, サイズ (-1 = MAX)
$parameterDefinitions = @(
    @('ClaimNumber', 'NVarChar', 20)
    @('ReceivedDate', 'Date', 0)
    @('CustomerName', 'NVarChar', 100)
    @('ProductName', 'NVarChar', 100)
    @('LotNumber', 'NVarChar', 50)
    @('ClaimCategory', 'NVarChar', 50)
    @('Severity', 'NVarChar', 10)
    @('IncidentDate', 'Date', 0)
    @('IncidentSummary', 'NVarChar', 1000)
    @('Status', 'NVarChar', 20)
    @('DocumentType', 'NVarChar', 20)
    @('FileName', 'NVarChar', 260)
    @('ContentType', 'NVarChar', 100)
    @('FileData', 'VarBinary', -1)
)

$connection = Open-SqlConnection -ServerFqdn $outputs.sqlServerFqdn -DatabaseName $outputs.sqlDatabaseName
try {
    Write-Step "$($records.Count) 件のレコードを dbo.Claims に登録"
    foreach ($record in $records) {
        $filePath = Join-Path $DocumentDirectory $record.FileName
        $values = @{}
        foreach ($property in $record.PSObject.Properties) { $values[$property.Name] = $property.Value }
        $values.FileData = [System.IO.File]::ReadAllBytes($filePath)
        foreach ($dateColumn in 'ReceivedDate', 'IncidentDate') {
            # ConvertFrom-Json が既に DateTime に変換している場合はそのまま使う
            if ($values[$dateColumn] -is [string]) {
                $values[$dateColumn] = [datetime]::ParseExact($values[$dateColumn], 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
            }
        }

        $command = $connection.CreateCommand()
        $command.CommandText = $insertSql
        foreach ($definition in $parameterDefinitions) {
            $name, $type, $size = $definition
            $parameter = $command.Parameters.Add("@$name", [System.Data.SqlDbType]$type, $size)
            $parameter.Value = if ($null -eq $values[$name]) { [DBNull]::Value } else { $values[$name] }
        }

        $claimId = $command.ExecuteScalar()
        if ($claimId -is [DBNull]) {
            Write-Host "  skip    : $($record.ClaimNumber) / $($record.FileName) (登録済み)" -ForegroundColor Yellow
        }
        else {
            Write-Host ("  inserted: ClaimId={0} {1} / {2} ({3:N0} bytes)" -f $claimId, $record.ClaimNumber, $record.FileName, $values.FileData.Length) -ForegroundColor Green
        }

        if ($IntervalSeconds -gt 0) { Start-Sleep -Seconds $IntervalSeconds }
    }
}
finally {
    $connection.Dispose()
}

Write-Host "`n登録が完了しました。Functions (SQL トリガー) が数秒以内に Blob ($($outputs.storageAccountName)/$($outputs.documentContainerName)) へアップロードします。" -ForegroundColor Green
