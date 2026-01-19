// ===============================================
// Bicep template (DROP-IN) - MCP Server only
// Keeps ONLY what is needed to deploy/run the Hosted MCP Server in Azure Container Apps
// Removes: Storage, AI Search, OpenAI, Embeddings, and all role assignments/outputs for those
// ===============================================

@description('The name prefix for all resources')
param resourcePrefix string = 'lab565'

@description('The location where all resources will be deployed (fallback only)')
param location string = 'eastus'

// ===============================================
// PARAMS: Hosted MCP Server (Container Apps)
// ===============================================

@description('Shared resource group that hosts the ACR (registry)')
param acrResourceGroup string

@description('Shared ACR name (lowercase, globally unique)')
param acrName string

@description('MCP image tag in ACR (example: v1)')
param mcpImageTag string = 'v1'

@secure()
@description('API key students will paste into Copilot Studio')
param mcpApiKey string

// ===============================================
// LOCATION / NAMING
// ===============================================

var rgLocation = empty(location) ? resourceGroup().location : location
var uniqueSuffix = uniqueString(resourceGroup().id)

// Avoid decimal literal for older Bicep parsers
var mcpCpu = json('0.25')

// Managed Environment name: must be <= 32 chars
var mcpEnvBase = toLower('${resourcePrefix}-mcp-env-${uniqueSuffix}')
var mcpEnvName = length(mcpEnvBase) > 32 ? substring(mcpEnvBase, 0, 32) : mcpEnvBase

// Container App name: must be <= 32 chars
var mcpAppBase = toLower('${resourcePrefix}-mcp-${uniqueSuffix}')
var mcpAppName = length(mcpAppBase) > 32 ? substring(mcpAppBase, 0, 32) : mcpAppBase

// ===============================================
// ACR (EXISTING) + IMAGE REF
// ===============================================

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
  scope: resourceGroup(acrResourceGroup)
}

// NOTE: This is intentionally left in (questionable in some orgs if ACR admin user/credential listing is blocked),
// because your current deployment uses it and it’s the most “drop-in” compatible approach.
var acrCreds = acr.listCredentials()
var mcpImage = '${acr.properties.loginServer}/hr-mcp-server:${mcpImageTag}'

// ===============================================
// AZURE CONTAINER APPS
// ===============================================

resource mcpEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: mcpEnvName
  location: rgLocation
  properties: {}
}

resource mcpApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: mcpAppName
  location: rgLocation
  properties: {
    managedEnvironmentId: mcpEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          username: acrCreds.username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'acr-password'
          value: acrCreds.passwords[0].value
        }
        {
          name: 'mcp-api-key'
          value: mcpApiKey
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'hrmcp'
          image: mcpImage
          env: [
            // Keep these because they can be required for the app to listen correctly + find its data file
            {
              name: 'ASPNETCORE_URLS'
              value: 'http://0.0.0.0:8080'
            }
            {
              name: 'HRMCPServer__CandidatesPath'
              value: 'Data/candidates.json'
            }
            {
              name: 'MCP_API_KEY'
              secretRef: 'mcp-api-key'
            }
          ]
          resources: {
            cpu: mcpCpu
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// ===============================================
// OUTPUTS (only what students need)
// ===============================================

@description('Hosted MCP base URL (students paste into Copilot Studio)')
output mcpBaseUrl string = 'https://${mcpApp.properties.configuration.ingress.fqdn}'

@description('Header name to use for the MCP API key')
output mcpHeaderName string = 'x-mcp-api-key'
