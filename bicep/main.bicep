// File: bicep/main.bicep
targetScope = 'subscription'

// === Parameter ===
param location string = 'southeastasia'
param projectPrefix string = 'us'
param resourceGroupName string = 'rg-${projectPrefix}-prod'
param principalId string 
@secure()
param sqlAdminPassword string // RECEIVE the password here

@minValue(1)
param aksNodeCount int = 1

param aksVmSize string = 'Standard_B2s'

// === Variabel ===
// === Resource Group ===
resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

// === Module ===
module coreResources 'core.bicep' = {
  name: 'CoreResourcesDeployment'
  scope: rg 
  params: {
    location: location
    projectPrefix: projectPrefix
    principalId: principalId
    sqlAdminPassword: sqlAdminPassword // PASS it down here
    aksNodeCount: aksNodeCount
    aksVmSize: aksVmSize
  }
}

// === Outputs ===
output keyVaultName string = coreResources.outputs.keyVaultName
output aksClusterName string = coreResources.outputs.aksClusterName
output sqlServerName string = coreResources.outputs.sqlServerName
output cosmosAccountName string = coreResources.outputs.cosmosAccountName
output functionAppName string = coreResources.outputs.functionAppName
output resourceGroupName string = resourceGroupName
