#Requires -Version 7.0
<#
.SYNOPSIS
    SQL Database のテーブル作成・変更の追跡の有効化・Functions マネージド ID のデータベースユーザー作成を行う。
.DESCRIPTION
    deploy.ps1 から呼び出される (単体でも再実行可能・冪等)。
    Entra 管理者 (= Bicep をデプロイしたユーザー) のトークンで接続する。
#>
[CmdletBinding()]
param(
    [string]$DeploymentName = 'sql-binary-search-poc'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"

$outputs = Get-DeploymentOutputs -DeploymentName $DeploymentName
$connection = Open-SqlConnection -ServerFqdn $outputs.sqlServerFqdn -DatabaseName $outputs.sqlDatabaseName

try {
    Write-Step "テーブル作成と変更の追跡を有効化 ($($outputs.sqlDatabaseName))"
    $schemaSql = Get-Content -Path (Join-Path $PSScriptRoot '../sql/schema.sql') -Raw
    foreach ($batch in ($schemaSql -split '(?im)^\s*GO\s*$') | Where-Object { $_.Trim() }) {
        $command = $connection.CreateCommand()
        $command.CommandText = $batch
        [void]$command.ExecuteNonQuery()
    }

    # Functions の UAMI をデータベースユーザーとして作成する。
    # SID 指定 (クライアント ID) で作成するため、SQL サーバーに Microsoft Graph の参照権限は不要。
    Write-Step "Functions マネージド ID ($($outputs.functionIdentityName)) のデータベースユーザーを作成"
    $command = $connection.CreateCommand()
    $command.CommandText = @'
DECLARE @sid NVARCHAR(MAX) = CONVERT(VARCHAR(MAX), CONVERT(VARBINARY(16), @clientId), 1);
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name)
BEGIN
    DECLARE @create NVARCHAR(MAX) = N'CREATE USER ' + QUOTENAME(@name) + N' WITH SID = ' + @sid + N', TYPE = E;';
    EXEC (@create);
END

-- SQL トリガーは az_func スキーマにリース管理用テーブルを作成するため ddladmin も付与する
DECLARE @grant NVARCHAR(MAX) =
      N'ALTER ROLE db_datareader ADD MEMBER ' + QUOTENAME(@name) + N';'
    + N'ALTER ROLE db_datawriter ADD MEMBER ' + QUOTENAME(@name) + N';'
    + N'ALTER ROLE db_ddladmin ADD MEMBER ' + QUOTENAME(@name) + N';'
    + N'GRANT VIEW CHANGE TRACKING ON OBJECT::dbo.Claims TO ' + QUOTENAME(@name) + N';';
EXEC (@grant);
'@
    [void]$command.Parameters.Add('@name', [System.Data.SqlDbType]::NVarChar, 128)
    [void]$command.Parameters.Add('@clientId', [System.Data.SqlDbType]::UniqueIdentifier)
    $command.Parameters['@name'].Value = $outputs.functionIdentityName
    $command.Parameters['@clientId'].Value = [guid]$outputs.functionIdentityClientId
    [void]$command.ExecuteNonQuery()

    Write-Host 'SQL Database の初期化が完了しました。' -ForegroundColor Green
}
finally {
    $connection.Dispose()
}
