# CLOUD_RESOURCES

Date: 2026-01-19

This document enumerates the Azure resources used by this codebase **as declared in Bicep**. It also highlights where the repository cannot fully determine deployed settings (SKUs, actual generated names, portal configuration), and provides a verification checklist.

Source of truth:

- `bicep/main.bicep`
- `bicep/core.bicep`

---

## 1) Deployment scope and naming

### 1.1 Scope

- The top-level deployment (`bicep/main.bicep`) is **subscription-scoped**.
- It creates a resource group, then deploys `core.bicep` into that resource group.

### 1.2 Parameters

- `location` (default: `southeastasia`)
- `projectPrefix` (default: `us`)
- `principalId` (object id granted Key Vault secret permissions)
- `sqlAdminPassword` (secure)

### 1.3 Resource group

- Resource group name: `rg-${projectPrefix}-prod`

### 1.4 Unique suffix / deterministic naming

`core.bicep` uses:

- `uniqueSuffix = uniqueString(resourceGroup().id)`

This means most resource names are:

- `${projectPrefix}-<resource>-${uniqueSuffix}`

Actual names in your subscription can only be computed after deployment (because `resourceGroup().id` is not known from source alone).

---

## 2) Azure resources declared by Bicep

### 2.1 Key Vault

- Type: `Microsoft.KeyVault/vaults`
- Name: `${projectPrefix}-kv-${uniqueSuffix}`
- Access policies:
  - `principalId` has secret permissions: `get`, `list`, `set`, `delete`
  - Function App’s managed identity is later granted: `get`, `list`

Primary purpose:

- Store secrets consumed by the Function App via Key Vault references.

### 2.2 AKS cluster

- Type: `Microsoft.ContainerService/managedClusters`
- Name: `${projectPrefix}-aks-${uniqueSuffix}`
- Identity: system assigned
- Node pool:
  - `count: 2`
  - `vmSize: Standard_B2s`
  - `osType: Linux`
- Networking:
  - `networkPlugin: azure`
  - `loadBalancerSku: standard`

Primary purpose:

- Run the `frontend`, `auth-service`, `link-management-service`, `analytics-query-service`, and `analytics-processing-service` workloads.

### 2.3 Azure SQL

- SQL Server:
  - Type: `Microsoft.Sql/servers`
  - Name: `${projectPrefix}-sql-${uniqueSuffix}`
  - Admin login: `sqladmin`
  - Admin password: `sqlAdminPassword`

- SQL Database:
  - Type: `Microsoft.Sql/servers/databases`
  - Name: `links-db`
  - SKU: Basic

- Firewall rule:
  - Type: `Microsoft.Sql/servers/firewallRules`
  - Name: `AllowAzureServices`
  - Allows `0.0.0.0` (Azure services)

Primary purpose:

- `links-db` stores `Users` and `Links` tables.

### 2.4 Azure Cosmos DB (SQL API)

- Account:
  - Type: `Microsoft.DocumentDB/databaseAccounts`
  - Name: `${projectPrefix}-cosmos-${uniqueSuffix}`
  - Capability: `EnableServerless`

- Database:
  - Type: `.../sqlDatabases`
  - Name: `analytics-db`

- Container:
  - Type: `.../containers`
  - Name: `clicks`
  - Partition key: `/short_code`

Primary purpose:

- Store raw analytics click events.

### 2.5 Azure Service Bus

- Namespace:
  - Type: `Microsoft.ServiceBus/namespaces`
  - Name: `${projectPrefix}-sb-${uniqueSuffix}`
  - SKU: Basic

- Queue:
  - Type: `.../queues`
  - Name: `analytics-queue`

Primary purpose:

- Buffer click events emitted from the redirect function and consumed by the analytics worker.

### 2.6 Storage account (Functions dependency)

- Type: `Microsoft.Storage/storageAccounts`
- Name: `st${projectPrefix}${uniqueSuffix}`
- SKU: `Standard_LRS`
- Kind: `StorageV2`

Primary purpose:

- `AzureWebJobsStorage` for the Function App.

### 2.7 App Service Plan (Linux Consumption)

- Type: `Microsoft.Web/serverfarms`
- Name: `${projectPrefix}-plan-${uniqueSuffix}`
- SKU: `Y1` (Dynamic) => consumption
- Linux: `reserved: true`

Primary purpose:

- Host the redirect Function App.

### 2.8 Azure Function App (Redirect Service)

- Type: `Microsoft.Web/sites`
- Name: `${projectPrefix}-func-${uniqueSuffix}`
- Kind: `functionapp,linux`
- Identity: system assigned
- App settings include:
  - `AzureWebJobsStorage` (constructed from the storage account and keys)
  - `FUNCTIONS_WORKER_RUNTIME=custom`
  - `FUNCTIONS_EXTENSION_VERSION=~4`
  - `SqlConnectionString` via Key Vault reference: `SecretName=SqlConnectionString`
  - `ServiceBusConnectionString` via Key Vault reference: `SecretName=ServiceBusConnection`

Primary purpose:

- Serve the low-latency redirect endpoint and enqueue analytics events.

---

## 3) Resources NOT provisioned by Bicep (but used/assumed)

These are important because you may need to manage them elsewhere:

- **Container registry**: not provisioned (no ACR). Kubernetes images are pulled from GHCR (`ghcr.io/shinshark/...`).
- **DNS**: the domain `lazurune.shinshark.my.id` is referenced in Caddy, but DNS is not managed in IaC.
- **TLS certificates**: issued by ZeroSSL via Caddy ACME; not managed in IaC.
- **Application Insights / Log Analytics**: not provisioned in Bicep, even though the Functions host config enables sampling settings in `services/redirect-service/host.json`.

---

## 3.1 DevOps delivery resources (outside Azure IaC)

Although not Azure resources, these are part of the *real* production footprint because they are required to build and ship changes:

- **GitHub Actions** (CI/CD runner + workflow engine): `.github/workflows/*.yml`
- **GitHub Container Registry (GHCR)**: stores Docker images pulled by AKS
  - Examples referenced by Kubernetes manifests: `ghcr.io/shinshark/azure-url-shortener/<service>:latest`
- **Microsoft Container Registry** images used at runtime:
  - DB migration job uses `mcr.microsoft.com/mssql-tools`

Required GitHub repository secrets:

- `AZURE_CREDENTIALS`: used by `azure/login@v1` in all deploy workflows
  - This is typically a JSON service principal credential payload.
- (Implicit) `GITHUB_TOKEN`: used to authenticate pushes to GHCR (provided automatically by GitHub Actions).

Deployment environment coupling to be aware of:

- Most workflows hardcode:
  - `RESOURCE_GROUP: rg-us-prod`
  - `CLUSTER_NAME: us-aks-p6ndmuotrzo5a`
- The redirect workflow hardcodes:
  - `AZURE_FUNCTIONAPP_NAME: us-func-p6ndmuotrzo5a`
- The DB migration workflow hardcodes:
  - SQL server hostname `us-sql-p6ndmuotrzo5a.database.windows.net`

If you redeploy IaC with a different suffix, these values must be updated.

---

## 4) Secrets and configuration you must supply

### 4.1 Key Vault secrets required for Function App

Bicep references (but does not create) these secrets:

- `SqlConnectionString` (ADO format; used by Rust/tiberius)
- `ServiceBusConnection` (Service Bus connection string, parsed to generate SAS)

If these are missing, the Function App will fail at runtime because `SqlConnectionString` and/or `ServiceBusConnectionString` env vars will be absent.

### 4.2 Kubernetes Secrets required for AKS pods

Manifests reference Secrets that are not committed in the repo:

- `db-secrets` with key `password` (SQL admin password)
- `auth-secrets` with key `jwt-secret` (shared JWT signing secret)
- `analytics-secrets` with keys:
  - `cosmos-connection-string`
  - `service-bus-connection-string`

---

## 5) Outputs from Bicep

`bicep/main.bicep` exports:

- `keyVaultName`
- `aksClusterName`
- `sqlServerName`
- `cosmosAccountName`

`bicep/core.bicep` also outputs:

- `functionAppName`

---

## 6) Verification checklist (what to check in Azure)

Use this when onboarding or debugging environment drift.

1. **Resource names**: confirm actual names (suffix) and location.
2. **AKS**:
   - Ensure the `frontend-service` has an external IP (LoadBalancer).
   - Ensure images from GHCR are pullable (public or imagePullSecrets).
3. **SQL Server**:
   - Confirm the server hostname matches what K8s manifests use (`DB_HOST`).
   - Confirm firewall and connectivity from AKS.
4. **Key Vault**:
   - Ensure `SqlConnectionString` and `ServiceBusConnection` secrets exist.
   - Ensure Function App managed identity has `get/list` secret access.
5. **Function App**:
   - Confirm deployment method for the custom handler binary (`redirect-service`).
   - Confirm app settings resolved Key Vault references successfully.
6. **Cosmos**:
   - Confirm database `analytics-db` and container `clicks` exist.
   - Confirm partition key is `/short_code`.
7. **Service Bus**:
   - Confirm queue `analytics-queue` exists.
   - Confirm SAS policy/key in the connection string supports sending.
