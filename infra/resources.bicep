param location string
param tags object
param principalId string
param principalName string
param principalType string
param clientIpAddress string

var suffix = uniqueString(resourceGroup().id)
var documentContainerName = 'claim-documents'
var sqlDatabaseName = 'ClaimsDb'

// 組み込みロール ID
var roles = {
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  storageBlobDataReader: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  searchIndexDataReader: '1407120a-92aa-4202-b7e9-c0e197c71c8f'
}

// ---------------------------------------------------------------------------
// 監視
// ---------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${suffix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${suffix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ---------------------------------------------------------------------------
// Storage (Functions ホスト用 + 資料格納コンテナー)。共有キーは無効化し Entra ID のみで認証
// ---------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource documentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: documentContainerName
  properties: {
    publicAccess: 'None'
  }
}

// ---------------------------------------------------------------------------
// Azure SQL Database (Entra ID 認証のみ / Entra 管理者 = デプロイ実行者)
// ---------------------------------------------------------------------------
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: 'sql-${suffix}'
  location: location
  tags: tags
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: principalName
      sid: principalId
      principalType: principalType
      tenantId: subscription().tenantId
    }
  }
}

// Functions など Azure 内部からの接続を許可
resource sqlFirewallAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlFirewallClient 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (!empty(clientIpAddress)) {
  parent: sqlServer
  name: 'AllowClientIp'
  properties: {
    startIpAddress: clientIpAddress
    endIpAddress: clientIpAddress
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  properties: {
    requestedBackupStorageRedundancy: 'Local'
  }
}

// ---------------------------------------------------------------------------
// Azure AI Search (API キー無効 / RBAC のみ。システム割り当て MI で Blob を読む)
// ---------------------------------------------------------------------------
resource search 'Microsoft.Search/searchServices@2023-11-01' = {
  name: 'srch-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'basic'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: 'enabled'
    disableLocalAuth: true
  }
}

// ---------------------------------------------------------------------------
// Azure Functions (Python / Linux App Service プラン)
// ---------------------------------------------------------------------------
resource functionIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-func-${suffix}'
  location: location
  tags: tags
}

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'plan-${suffix}'
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: 'func-${suffix}'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${functionIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'ENABLE_ORYX_BUILD', value: 'true' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        // Functions ホストのストレージ (ID ベース接続)
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId', value: functionIdentity.properties.clientId }
        // SQL トリガー (マネージド ID 認証)
        {
          name: 'SqlConnectionString'
          value: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Database=${sqlDatabaseName};Authentication=Active Directory Managed Identity;User Id=${functionIdentity.properties.clientId};Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
        }
        // VARBINARY を含む行がペイロードに載るため 1 回の呼び出しで処理する件数を抑える
        { name: 'Sql_Trigger_MaxBatchSize', value: '10' }
        // 資料アップロード先 (azure-identity の DefaultAzureCredential が AZURE_CLIENT_ID の MI を使用)
        { name: 'AZURE_CLIENT_ID', value: functionIdentity.properties.clientId }
        { name: 'DOCUMENT_STORAGE_ACCOUNT_URL', value: storage.properties.primaryEndpoints.blob }
        { name: 'DOCUMENT_CONTAINER_NAME', value: documentContainerName }
      ]
    }
  }
  dependsOn: [
    functionStorageRoleAssignments
  ]
}

// ---------------------------------------------------------------------------
// RBAC
// ---------------------------------------------------------------------------
// Functions MI -> Storage (ホスト用 Blob/Queue/Table + 資料アップロード)
var functionStorageRoles = [
  roles.storageBlobDataOwner
  roles.storageQueueDataContributor
  roles.storageTableDataContributor
]

resource functionStorageRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in functionStorageRoles: {
    name: guid(storage.id, functionIdentity.id, roleId)
    scope: storage
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
      principalId: functionIdentity.properties.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

// AI Search MI -> Storage (インデクサーが Blob とメタデータを読み取る)
resource searchStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, search.id, roles.storageBlobDataReader)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataReader)
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// デプロイ実行者 -> Storage (アップロード結果の確認)
resource userStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, principalId, roles.storageBlobDataContributor)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
    principalId: principalId
    principalType: principalType
  }
}

// デプロイ実行者 -> AI Search (インデックス/インデクサー作成、検索クエリ)
var userSearchRoles = [
  roles.searchServiceContributor
  roles.searchIndexDataReader
]

resource userSearchRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in userSearchRoles: {
    name: guid(search.id, principalId, roleId)
    scope: search
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
      principalId: principalId
      principalType: principalType
    }
  }
]

output functionAppName string = functionApp.name
output functionIdentityName string = functionIdentity.name
output functionIdentityClientId string = functionIdentity.properties.clientId
output sqlServerName string = sqlServer.name
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDatabase.name
output storageAccountName string = storage.name
output storageAccountId string = storage.id
output documentContainerName string = documentContainer.name
output searchServiceName string = search.name
output searchEndpoint string = 'https://${search.name}.search.windows.net'
