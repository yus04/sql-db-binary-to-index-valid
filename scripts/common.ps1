#Requires -Version 7.0
# 各スクリプトから dot-source して使う共通関数

Set-StrictMode -Version Latest

$script:DefaultDeploymentName = 'sql-binary-search-poc'
$script:SearchApiVersion = '2024-07-01'
$script:SearchIndexName = 'claim-documents-index'
$script:SearchIndexerName = 'claim-documents-indexer'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments[0..1] -join ' ') failed (exit code $LASTEXITCODE)"
    }
    return ($output -join "`n")
}

function Get-DeploymentOutputs {
    param([Parameter(Mandatory)][string]$DeploymentName)
    $raw = Invoke-AzCli @('deployment', 'sub', 'show', '--name', $DeploymentName, '--query', 'properties.outputs', '-o', 'json') |
        ConvertFrom-Json
    $outputs = [ordered]@{}
    foreach ($property in $raw.PSObject.Properties) {
        $outputs[$property.Name] = $property.Value.value
    }
    return [pscustomobject]$outputs
}

function Get-AccessToken {
    param([Parameter(Mandatory)][string]$Resource)
    return Invoke-AzCli @('account', 'get-access-token', '--resource', $Resource, '--query', 'accessToken', '-o', 'tsv')
}

function Open-SqlConnection {
    # Entra ID (az login ユーザー) のアクセストークンで Azure SQL Database に接続する
    param(
        [Parameter(Mandatory)][string]$ServerFqdn,
        [Parameter(Mandatory)][string]$DatabaseName,
        [int]$MaxAttempts = 6
    )
    $connectionString = "Server=tcp:$ServerFqdn,1433;Initial Catalog=$DatabaseName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;"
    for ($attempt = 1; ; $attempt++) {
        $connection = [System.Data.SqlClient.SqlConnection]::new($connectionString)
        $connection.AccessToken = Get-AccessToken -Resource 'https://database.windows.net/'
        try {
            $connection.Open()
            return $connection
        }
        catch {
            $connection.Dispose()
            # ファイアウォール規則の反映待ちなどの一時的な失敗を考慮して再試行する
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Warning "SQL 接続に失敗しました。20 秒後に再試行します ($attempt/$MaxAttempts): $($_.Exception.Message)"
            Start-Sleep -Seconds 20
        }
    }
}

function Invoke-SearchApi {
    # Azure AI Search REST API を Entra ID トークンで呼び出す。RBAC 反映待ちの 401/403 は再試行する
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$Path,
        [string]$Method = 'Get',
        [string]$Body,
        [int]$MaxAttempts = 20
    )
    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $uri = "$Endpoint/$Path$($separator)api-version=$script:SearchApiVersion"
    $request = @{
        Method      = $Method
        Uri         = $uri
        ContentType = 'application/json; charset=utf-8'
    }
    if ($Body) { $request.Body = [System.Text.Encoding]::UTF8.GetBytes($Body) }

    for ($attempt = 1; ; $attempt++) {
        $request.Headers = @{ Authorization = "Bearer $(Get-AccessToken -Resource 'https://search.azure.com')" }
        try {
            return Invoke-RestMethod @request
        }
        catch {
            $status = 0
            if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
                $status = [int]$_.Exception.Response.StatusCode
            }
            if ($status -notin 401, 403 -or $attempt -ge $MaxAttempts) { throw }
            Write-Warning "AI Search が $status を返しました (ロール割り当ての反映待ち)。30 秒後に再試行します ($attempt/$MaxAttempts)"
            Start-Sleep -Seconds 30
        }
    }
}
