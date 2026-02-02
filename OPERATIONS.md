# OPERATIONS

Date: 2026-01-19

This document is the operational runbook for the deployed system (AKS + Azure Functions + Azure SQL + Cosmos DB + Service Bus). It focuses on **how to deploy, configure, and debug the live system**, grounded in the repo’s IaC and Kubernetes manifests.

Key sources of truth:

- `bicep/main.bicep`, `bicep/core.bicep`
- `kubernetes/**`
- `services/redirect-service/host.json`, `services/redirect-service/redirect/function.json`
- `kubernetes/frontend/configmap.yaml` (Caddy routing)

---

## 1) Mental model (ops perspective)

Public traffic path:

1. Public DNS points to the **AKS LoadBalancer** created by `frontend-service`.
2. Caddy (inside the `frontend` pod) terminates TLS and routes requests.
3. API calls go to AKS services; short links go to the Azure Function (redirect).

Analytics path:

1. Redirect function enqueues events to Service Bus queue `analytics-queue`.
2. `analytics-processing-service` consumes queue messages and writes them to Cosmos.
3. `analytics-query-service` reads Cosmos and returns aggregated stats.

---

## 2) Prerequisites / tooling

Recommended tooling:

- Azure CLI (`az`)
- `kubectl`
- Bicep support (either `az` integrated Bicep or the standalone Bicep CLI)

You’ll typically need access to:

- Subscription scope (to deploy `bicep/main.bicep`)
- Resource group `rg-<projectPrefix>-prod`
- AKS cluster credentials

---

## 3) Provisioning Azure resources (IaC)

### 3.1 What Bicep provisions

From `bicep/core.bicep`:

- Resource Group (created from subscription scope)
- AKS cluster
- Azure SQL server + `links-db`
- Cosmos DB account (serverless) + database `analytics-db` + container `clicks`
- Service Bus namespace + queue `analytics-queue`
- Storage account (Functions dependency)
- Linux Consumption plan + Function App (custom handler runtime)
- Key Vault + access policies

### 3.2 What Bicep does NOT provision

- DNS for `lazurune.shinshark.my.id`
- A container registry (AKS pulls images from GHCR)
- Kubernetes `Secret` objects referenced by manifests
- Key Vault secret *values* (only references)
- Application Insights/Log Analytics resources

### 3.3 Deploying Bicep

`bicep/main.bicep` is `targetScope = 'subscription'` and creates `rg-${projectPrefix}-prod`.

You will need to supply:

- `principalId` (the object id that should have Key Vault secret admin permissions)
- `sqlAdminPassword`

After deployment, capture outputs:

- `aksClusterName`
- `keyVaultName`
- `sqlServerName`
- `cosmosAccountName`
- `functionAppName` (from `core.bicep` output)

---

## 4) Secrets and configuration (required)

### 4.1 Key Vault secrets required for the redirect Function App

Bicep configures Function App app settings as Key Vault references:

- `SqlConnectionString` (KV secret name: `SqlConnectionString`)
- `ServiceBusConnectionString` (KV secret name: `ServiceBusConnection`)

If these are missing, the redirect function will fail at runtime.

#### 4.1.1 `SqlConnectionString` format

The Rust redirect function uses `tiberius::Config::from_ado_string`.

Use an Azure SQL ADO-style connection string similar to:

- `Server=tcp:<sqlServer>.database.windows.net,1433;Database=links-db;User ID=sqladmin;Password=<...>;Encrypt=true;TrustServerCertificate=false;Connection Timeout=30;`

Important:

- Encryption is required (the code explicitly enables required encryption).

#### 4.1.2 `ServiceBusConnection` format

The Rust redirect function parses a Service Bus connection string to generate SAS tokens and call the Service Bus REST endpoint.

It expects a string containing:

- `Endpoint=sb://<namespace>.servicebus.windows.net/;SharedAccessKeyName=<policy>;SharedAccessKey=<key>`

The policy must permit **Send**.

### 4.2 Kubernetes Secrets required for AKS

Manifests reference these secrets (not committed in repo):

- `db-secrets`
  - key: `password` (Azure SQL admin password)
- `auth-secrets`
  - key: `jwt-secret` (JWT signing secret shared by auth-service + link-management-service)
- `analytics-secrets`
  - key: `cosmos-connection-string`
  - key: `service-bus-connection-string`

Operational note:

- `JWT_SECRET` must match between `auth-service` and `link-management-service` or all authenticated link operations will fail.

---

## 5) Deploying Kubernetes workloads

### 5.1 Apply manifests

Manifests live under `kubernetes/`:

- `frontend/` (Deployment + Service + ConfigMap + PVC)
- `auth-service/` (Deployment + Service)
- `link-management-service/` (Deployment + Service)
- `analytics-query-service/` (Deployment + Service)
- `analytics-processing-service/` (Deployment only)

### 5.2 Public entrypoint

The public IP is provisioned via:

- `kubernetes/frontend/service.yaml` (`type: LoadBalancer`)

DNS should point the desired hostname to that public IP.

### 5.3 Caddy routing is the "ingress"

There is no Kubernetes Ingress object in this repo; instead, Caddy is configured via:

- `kubernetes/frontend/configmap.yaml`

If routes don’t work, validate:

- ConfigMap mounted at `/etc/caddy/Caddyfile`
- Caddy logs inside the frontend pod

---

## 6) Function App deployment (redirect-service)

This repo provisions the Function App infrastructure, and includes the Rust custom handler code + Functions metadata. The *exact deployment method* of the custom handler binary (zip deploy vs container, CI pipeline, etc.) is not described in IaC.

Operational checks:

- The Function host expects to run executable `redirect-service` (see `services/redirect-service/host.json`).
- Ensure the deployed artifact includes:
  - the `redirect-service` executable
  - `host.json`
  - the function folder `redirect/` with `function.json`

If you are missing a deployment pipeline, the most reliable approach is to add a CI workflow that builds the Rust binary for Linux and publishes it as a Functions custom handler artifact.

---

## 7) Health checks and smoke tests

### 7.1 AKS services

These endpoints exist in code:

- `GET /health` on:
  - auth-service
  - link-management-service
  - analytics-query-service

Because Caddy routes only `/api/*` explicitly, you typically reach these by port-forwarding to the service/pod, or by adding a temporary Caddy route.

### 7.2 Redirect function

Basic smoke test:

- Create a link via `/api/links`.
- Navigate to `/{shortCode}` on the public domain.
- Validate an HTTP redirect is returned.

---

## 8) Logs

Where to look:

- Frontend/Caddy logs: `frontend` pod
- Go services logs: `auth-service`, `link-management-service` pods
- Node services logs: `analytics-query-service`, `analytics-processing-service` pods
- Function logs: Function App logs in Azure (and/or Application Insights if enabled)

---

## 9) Operational gotchas (known issues to verify)

- Redirect status code mismatch (docs vs implementation). The redirect handler currently uses a temporary redirect.
- `CACHE_EVICTION_URL` is configured and called by link-management-service, but the redirect custom handler does not expose `/api/cache` in this repo. Confirm whether a separate function/route exists in the deployed Function App or remove/implement the feature.
- Guest links set `ExpiresAt` but redirect lookup currently filters only on `IsActive` (not `ExpiresAt`). Decide how expiration should be enforced.
- `DB_HOST` is hardcoded in Kubernetes manifests; Bicep generates a unique suffix for SQL server name. Confirm the hostname matches your deployment outputs.

---

## 10) CI/CD pipelines (GitHub Actions)

All pipelines live under `.github/workflows/` and are service-scoped.

### 10.1 Common prerequisites

Required GitHub repository secret:

- `AZURE_CREDENTIALS` (used by `azure/login@v1`)

GHCR publishing:

- Uses `docker/login-action@v3` with the built-in `GITHUB_TOKEN` and `packages: write` permission.

Important coupling:

- Workflows hardcode AKS environment identifiers (`RESOURCE_GROUP` and `CLUSTER_NAME`). If you redeploy with a new AKS name/suffix, update the workflow env vars.

### 10.2 AKS service pipelines (build image → push GHCR → apply manifests)

Each pipeline triggers on pushes to `main` limited to the service folder and its Kubernetes manifests, and can also be run manually (`workflow_dispatch`).

Pipelines:

- `frontend`: `.github/workflows/frontend.yml`
- `auth-service`: `.github/workflows/auth-service.yml`
- `link-management-service`: `.github/workflows/link-management-service.yml`
- `analytics-query-service`: `.github/workflows/analytics-query-service.yml`
- `analytics-processing-service`: `.github/workflows/analytics-processing-service.yml`

What they do (pattern):

1. Checkout.
2. Build Docker image from `services/<service>`.
3. Push to `ghcr.io/<owner>/<repo>/<service>` with tags:
  - `latest`
  - `main-<sha>`
4. Azure login.
5. Set AKS context.
6. `kubectl apply -f kubernetes/<service>/...`.
7. `kubectl rollout restart deployment/<...>` to force new image pull.

Operational implications:

- Because manifests use `:latest`, the forced restart step is crucial.
- If the cluster cannot pull from GHCR (private images), you must configure image pull secrets or make packages public.

### 10.3 Redirect function pipeline (Rust custom handler → Functions deploy)

Pipeline:

- `.github/workflows/redirect-service.yml`

What it does:

1. Installs Rust + target `x86_64-unknown-linux-musl` and `musl-tools`.
2. Builds release binary.
3. Copies binary to `services/redirect-service/redirect-service` (function package root).
4. Deploys `services/redirect-service` to a Function App via `Azure/functions-action@v1`.

Operational implications:

- Function App name is hardcoded (`AZURE_FUNCTIONAPP_NAME`). If Bicep redeploys a new name/suffix, update this.
- Ensure Key Vault secrets are present and resolvable so the deployed function can read `SqlConnectionString` and `ServiceBusConnectionString`.

### 10.4 DB migration pipeline (Kubernetes Job running sqlcmd)

Pipeline:

- `.github/workflows/db-migration.yml`

What it does:

1. Creates a ConfigMap `db-init-script` containing the SQL init scripts.
2. Runs a Kubernetes Job using `mcr.microsoft.com/mssql-tools` to execute:
  - `services/auth-service/init.sql`
  - `services/link-management-service/init.sql`
3. Pulls SQL password from Kubernetes Secret `db-secrets/password`.

Operational implications:

- SQL server hostname is hardcoded in the workflow (`us-sql-p6ndmuotrzo5a.database.windows.net`). If the SQL server name changes, update the workflow.
- This job runs inside AKS; it requires outbound network connectivity to Azure SQL and appropriate firewall rules.
