// === Parameters ===
param location string
param projectPrefix string
param principalId string
@secure()
param sqlAdminPassword string

@minValue(1)
param aksNodeCount int = 1

param aksVmSize string = 'Standard_B2s'

// === Variables ===
// uniqueString generates a 13-char hash based on the Resource Group ID
var uniqueSuffix = uniqueString(resourceGroup().id)

// Existing Resources
var keyVaultName = '${projectPrefix}-kv-${uniqueSuffix}'
var aksClusterName = '${projectPrefix}-aks-${uniqueSuffix}'
var sqlServerName = '${projectPrefix}-sql-${uniqueSuffix}'
var cosmosAccountName = '${projectPrefix}-cosmos-${uniqueSuffix}'
var serviceBusNamespaceName = '${projectPrefix}-sb-${uniqueSuffix}'

// === NEW: Function App Resources ===
// 1. Naming Convention: func-<project>-<hash>
var functionAppName = '${projectPrefix}-func-${uniqueSuffix}'
var appServicePlanName = '${projectPrefix}-plan-${uniqueSuffix}'

// 2. Storage Naming Convention: st<project><hash>
// Storage names must be lowercase, alphanumeric, and <24 chars.
// 'st' (2) + 'us' (2) + hash (13) = 17 chars. Safe.
var storageAccountName = 'st${projectPrefix}${uniqueSuffix}'

// === 1. Azure Key Vault ===
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: principalId
        permissions: { secrets: [ 'get', 'list', 'set', 'delete' ] }
      }
    ]
  }
}

// === 2. Azure Kubernetes Service (AKS) ===
resource aks 'Microsoft.ContainerService/managedClusters@2024-01-01' = {
  name: aksClusterName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    dnsPrefix: '${projectPrefix}-aks'
    agentPoolProfiles: [
      {
        name: 'agentpool'
        count: aksNodeCount
        vmSize: aksVmSize
        mode: 'System'
        osType: 'Linux'
      }
    ]
    networkProfile: { networkPlugin: 'azure', loadBalancerSku: 'standard' }
  }
}

// === 3. Azure SQL Server & Database ===
resource sqlServer 'Microsoft.Sql/servers@2021-11-01' = {
  name: sqlServerName
  location: location
  properties: {
    administratorLogin: 'sqladmin'
    administratorLoginPassword: sqlAdminPassword
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2021-11-01' = {
  parent: sqlServer
  name: 'links-db'
  location: location
  sku: { name: 'Basic', tier: 'Basic' } 
}

resource sqlFirewall 'Microsoft.Sql/servers/firewallRules@2021-11-01' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// === 4. Azure Cosmos DB ===
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: cosmosAccountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [ { locationName: location, failoverPriority: 0 } ]
    capabilities: [ { name: 'EnableServerless' } ] 
  }
}

resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmosAccount
  name: 'analytics-db'
  properties: { resource: { id: 'analytics-db' } }
}

resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: cosmosDb
  name: 'clicks'
  properties: {
    resource: {
      id: 'clicks'
      partitionKey: { paths: [ '/short_code' ], kind: 'Hash' }
    }
  }
}

// === 5. Azure Service Bus ===
resource serviceBus 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: serviceBusNamespaceName
  location: location
  sku: { name: 'Basic' }
}

resource sbQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBus
  name: 'analytics-queue'
}

// === 6. Storage Account (Required for Functions) ===
// Equivalent to: az storage account create --sku Standard_LRS ...
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}

// === 7. App Service Plan (Consumption) ===
// Equivalent to: --consumption-plan-location southeastasia
resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: appServicePlanName
  location: location
  sku: { name: 'Y1', tier: 'Dynamic' } // Y1 = Consumption Plan
  properties: { reserved: true } // True = Linux
}

// === 8. Function App (Redirect Service) ===
// Equivalent to: az functionapp create --runtime custom --os-type Linux ...
resource functionApp 'Microsoft.Web/sites@2022-09-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' } // Managed Identity
  properties: {
    serverFarmId: appServicePlan.id
    reserved: true
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'custom' // --runtime custom
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4' // --functions-version 4
        }
        // === Key Vault References ===
        // This allows your code to read secrets via os.environ (or env::var)
        {
          name: 'SqlConnectionString'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=SqlConnectionString)' 
        }
        {
          name: 'ServiceBusConnectionString'
          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=ServiceBusConnection)'
        }
      ]
    }
  }
}

// === 9. Grant Function App Access to Key Vault ===
// This gives the Function App permission to read the secrets referenced above.
resource kvAccessPolicy 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  parent: kv
  name: 'add'
  properties: {
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: functionApp.identity.principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
    ]
  }
}

// === Outputs ===
output functionAppName string = functionApp.name
output keyVaultName string = kv.name
output aksClusterName string = aks.name
output sqlServerName string = sqlServer.name
output cosmosAccountName string = cosmosAccount.name
