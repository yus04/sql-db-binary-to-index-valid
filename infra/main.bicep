targetScope = 'subscription'

@description('作成するリソースグループ名')
param resourceGroupName string = 'rg-sql-binary-search-poc'

@description('リソースのリージョン')
param location string = 'japaneast'

@description('デプロイ実行者 (SQL の Entra 管理者 / 各種データプレーン権限を付与する) のオブジェクト ID')
param principalId string

@description('デプロイ実行者のログイン名 (UPN)。SQL の Entra 管理者名として表示される')
param principalName string

@description('principalId の種別')
@allowed([
  'User'
  'Group'
])
param principalType string = 'User'

@description('SQL Database へ接続するクライアントのグローバル IP (登録用 PowerShell 実行端末)。空の場合はファイアウォール規則を作成しない')
param clientIpAddress string = ''

var tags = {
  SecurityControl: 'Ignore'
  project: 'sql-binary-to-ai-search-poc'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    tags: tags
    principalId: principalId
    principalName: principalName
    principalType: principalType
    clientIpAddress: clientIpAddress
  }
}

output resourceGroupName string = rg.name
output functionAppName string = resources.outputs.functionAppName
output functionIdentityName string = resources.outputs.functionIdentityName
output functionIdentityClientId string = resources.outputs.functionIdentityClientId
output sqlServerName string = resources.outputs.sqlServerName
output sqlServerFqdn string = resources.outputs.sqlServerFqdn
output sqlDatabaseName string = resources.outputs.sqlDatabaseName
output storageAccountName string = resources.outputs.storageAccountName
output storageAccountId string = resources.outputs.storageAccountId
output documentContainerName string = resources.outputs.documentContainerName
output searchServiceName string = resources.outputs.searchServiceName
output searchEndpoint string = resources.outputs.searchEndpoint
