# RECENT_ARCHITECTURE

Date: 2026-01-19

This document describes the **current, repo-derived architecture** of this system as it exists in this workspace (Kubernetes manifests, Bicep IaC, and service code). The content in `docs/` may be outdated; when there is a mismatch, this document prioritizes **running code + manifests** as the “source of truth” and calls out the inconsistency.

`local-dep/` exists but is **unused** in the current cloud deployment. It can still be mined for historical context, but it is not part of the deployed architecture described here.

---

## 1) What this system is

A cloud-native URL shortener with:

- A **public edge** that serves the SPA and routes API calls (Caddy running inside the `frontend` pod).
- A **control plane** on AKS (auth + link CRUD + analytics query).
- A **hot-path redirect** implemented as an Azure Function (custom handler written in Rust).
- An **event-driven analytics pipeline** using Azure Service Bus (queue) + a worker on AKS writing to Cosmos DB.

The critical design choice is separating:

- **Hot path**: redirect lookup + immediate redirect response.
- **Async path**: click analytics emission and storage.

---

## 2) Deployed components (runtime boundaries)

### 2.1 Public edge / routing

**`frontend` (AKS pod)**

- Runs a built Vue SPA served by **Caddy**.
- Exposes ports **80/443** via a Kubernetes `LoadBalancer` service.
- Terminates TLS using ACME (ZeroSSL) and persists cert state to a PVC.

Source of truth:

- `kubernetes/frontend/configmap.yaml` (Caddyfile)
- `kubernetes/frontend/deployment.yaml`
- `kubernetes/frontend/service.yaml`
- `kubernetes/frontend/pvc.yaml`

### 2.2 AKS services (control plane + async worker)

**`auth-service` (Go + Gin)**

- Publicly reachable via Caddy under `/api/auth/*`.
- Handles register/login and mints JWTs.
- Persists users in Azure SQL (`Users` table).

**`link-management-service` (Go + Gin)**

- Publicly reachable via Caddy under `/api/links/*`.
- Creates and manages short links stored in Azure SQL (`Links` table).
- Contains quota logic and guest link expiration semantics.

**`analytics-query-service` (Node + Express)**

- Publicly reachable via Caddy under `/api/analytics/*`.
- Queries Cosmos DB for events and returns aggregated stats.

**`analytics-processing-service` (Node worker)**

- Not exposed via HTTP.
- Consumes click events from Service Bus queue `analytics-queue`.
- Writes each event as a document into Cosmos DB container `clicks`.

Source of truth:

- `kubernetes/auth-service/*`
- `kubernetes/link-management-service/*`
- `kubernetes/analytics-query-service/*`
- `kubernetes/analytics-processing-service/deployment.yaml`
- `services/*` (code)

### 2.3 Azure Functions (hot path)

**`redirect-service` (Rust + Axum, Azure Functions Custom Handler)**

- Handles redirect requests for `/{short_code}` via Functions HTTP trigger with default route prefix.
- Reads from Azure SQL to resolve `ShortCode -> OriginalUrl`.
- Responds with an HTTP redirect.
- Sends analytics event to Service Bus queue `analytics-queue` asynchronously.

Source of truth:

- `services/redirect-service/redirect/function.json`
- `services/redirect-service/host.json`
- `services/redirect-service/src/main.rs`
- `services/redirect-service/src/handlers.rs`
- `services/redirect-service/src/db.rs`
- `services/redirect-service/src/analytics.rs`

---

## 3) Public routing and request topology

### 3.1 Public DNS + TLS

The Caddyfile is configured for:

- Host: `lazurune.shinshark.my.id`
- ACME CA: `https://acme.zerossl.com/v2/DV90`

Caddy persists cert state under `/data` (PVC `caddy-data-pvc`).

### 3.2 Caddy routing rules

Caddy performs reverse proxy routing:

- `/api/auth*` → `http://auth-service` (K8s ClusterIP on port 80 → pod 8080)
- `/api/links*` → `http://link-management-service` (ClusterIP 80 → pod 8080)
- `/api/analytics*` → `http://analytics-query-service:3001` (ClusterIP 3001 → pod 3001)

For everything else:

- Rewrites path `/{anything}` to `/api/{anything}`
- Proxies to the Azure Function app upstream `https://us-func-p6ndmuotrzo5a.azurewebsites.net`

### 3.3 Why the rewrite is correct for Azure Functions

Azure Functions HTTP triggers default to an `api` route prefix when not overridden. This repo’s `redirect/function.json` defines a trigger `route: "{short_code}"`, so the effective endpoint is:

- `GET /api/{short_code}`

Caddy rewrites `/abc123` → `/api/abc123`, matching the Function trigger, while allowing user-friendly public short links.

---

## 4) Data stores and message bus

### 4.1 Azure SQL Database: `links-db`

Used for:

- `Users` (auth)
- `Links` (link management and redirect resolution)

Tables are described by:

- `services/auth-service/init.sql` (Users)
- `services/link-management-service/init.sql` (Links)

Notes:

- `Links` includes `ExpiresAt`, `ClickCount`, `IsActive`, and optional `CustomAlias`.
- Current redirect lookup checks `IsActive` and returns not found if inactive.
- Click counts are tracked via analytics events (Cosmos) rather than incrementing `ClickCount` in SQL.

### 4.2 Azure Cosmos DB: `analytics-db` / container `clicks`

Used for raw click events.

- Container partition key: `/short_code`.
- Query service filters by `short_code`.

### 4.3 Azure Service Bus: queue `analytics-queue`

Used for click events emitted by the redirect function and consumed by the analytics processing service.

---

## 5) Major request/data flows

### 5.1 Redirect flow (hot path)

1. Browser requests `https://lazurune.shinshark.my.id/{shortCode}`.
2. Caddy rewrites to `/api/{shortCode}` and proxies to the Azure Function.
3. Function host forwards the request to the Rust custom handler.
4. Rust handler:
   - Extracts `User-Agent` and `X-Forwarded-For` (IP).
   - Queries Azure SQL `Links` for `OriginalUrl` and `IsActive`.
   - If found/active: returns a **temporary redirect**.
   - Spawns an async task to send analytics event to Service Bus.

Failure behavior:

- If SQL lookup fails: returns 500.
- If the link is missing/inactive: returns 404.
- If Service Bus push fails: logs error but still redirects (fire-and-forget).

### 5.2 Link creation + management flow (control plane)

1. Browser uses the SPA dashboard to submit a URL.
2. SPA calls `POST /api/links`.
3. Caddy proxies to link-management-service.
4. Link management:
   - If no JWT: treats the caller as `Guest`.
   - If JWT: extracts user id (`sub`) and `role` claim.
   - Enforces quotas:
     - User: max 20 standard links.
     - User: max 2 custom alias links.
     - Guest: cannot create custom aliases.
   - Guest links get `ExpiresAt = now + 24h`.
   - Inserts `Links` row.

Updates/deletes:

- Require JWT (handler requires `userID` in context).
- Update is restricted: only custom alias links can be edited.
- Delete/update attempt triggers an async “cache eviction” request (see known gaps).

### 5.3 Auth flow

1. SPA submits:
   - `POST /api/auth/register` (username/password)
   - `POST /api/auth/login` (username/password)
2. Auth service:
   - Hashes password with bcrypt.
   - Issues JWT (HS256) with claims:
     - `sub`: user id
     - `role`: user role (default `User`)
     - `exp`: now + 24 hours
3. SPA stores token in `localStorage` and uses it for link management calls.

### 5.4 Analytics pipeline

1. Redirect service emits an event:
   - `{ short_code, original_url, timestamp, user_agent, ip_address }`
2. Analytics processing service:
   - Receives from Service Bus queue `analytics-queue`.
   - Adds a unique `id` if missing.
   - Inserts into Cosmos container `clicks`.
   - Completes the message; on error, abandons the message for retry.
3. Analytics query service:
   - `GET /api/analytics/:shortCode` queries Cosmos.
   - Aggregates by browser, OS, IP, and returns a timeline list.
4. SPA analytics page:
   - Renders charts.
   - Performs geolocation enrichment client-side using `https://ip-api.com/json/{ip}`.

---

## 6) Configuration, secrets, and deployment contracts

### 6.1 AKS pod environment variables (from manifests)

**auth-service** (`kubernetes/auth-service/deployment.yaml`)

- `PORT=8080`
- `DB_HOST`, `DB_NAME=links-db`, `DB_USER=sqladmin`, `DB_PASSWORD` from secret `db-secrets/password`
- `JWT_SECRET` from secret `auth-secrets/jwt-secret`

**link-management-service** (`kubernetes/link-management-service/deployment.yaml`)

- `PORT=8080`
- Same DB vars and `JWT_SECRET`
- `CACHE_EVICTION_URL=https://.../api/cache`

**analytics-query-service** (`kubernetes/analytics-query-service/deployment.yaml`)

- `PORT=3001`
- `COSMOS_CONNECTION_STRING` from secret `analytics-secrets/cosmos-connection-string`
- `COSMOS_DATABASE_NAME=analytics-db`, `COSMOS_CONTAINER_NAME=clicks`

**analytics-processing-service** (`kubernetes/analytics-processing-service/deployment.yaml`)

- `SERVICE_BUS_CONNECTION_STRING` from secret `analytics-secrets/service-bus-connection-string`
- `COSMOS_CONNECTION_STRING` from secret `analytics-secrets/cosmos-connection-string`
- `COSMOS_DATABASE_NAME=analytics-db`, `COSMOS_CONTAINER_NAME=clicks`

### 6.2 Azure Function app settings (from Bicep)

The Function App is configured with Key Vault references:

- `SqlConnectionString` → Key Vault secret `SqlConnectionString`
- `ServiceBusConnectionString` → Key Vault secret `ServiceBusConnection`

And standard Function settings:

- `AzureWebJobsStorage` from a provisioned Storage Account
- `FUNCTIONS_WORKER_RUNTIME=custom`

### 6.3 Container images

Kubernetes uses prebuilt images hosted on GHCR:

- `ghcr.io/shinshark/azure-url-shortener/frontend:latest`
- `ghcr.io/shinshark/azure-url-shortener/auth-service:latest`
- `ghcr.io/shinshark/azure-url-shortener/link-management-service:latest`
- `ghcr.io/shinshark/azure-url-shortener/analytics-query-service:latest`
- `ghcr.io/shinshark/azure-url-shortener/analytics-processing-service:latest`

Bicep does not provision an ACR; image distribution is external to IaC.

---

## 7) Known mismatches / gaps to verify (important onboarding notes)

These are places where the repo indicates incomplete/unfinished integration.

1. **Redirect status code mismatch**
   - README + `docs/architecture.md` claim HTTP 301.
   - `docs/api.yml` claims 302.
   - Rust handler uses `axum::response::Redirect::temporary`, which is a temporary redirect (307).

2. **Cache eviction endpoint appears missing**
   - link-management-service calls `DELETE {CACHE_EVICTION_URL}/{shortCode}`.
   - K8s sets `CACHE_EVICTION_URL=https://.../api/cache`.
   - redirect-service only exposes `/api/:short_code` in the custom handler; there is no `/api/cache` route in the Rust app.
   - This may be leftover from a previous caching design (e.g., Redis) and should be confirmed/removed or implemented.

3. **Guest link expiration is set but not enforced by redirect**
   - link-management-service sets `ExpiresAt` for guests.
   - redirect lookup currently checks `IsActive` only (not `ExpiresAt`).
   - Decide whether expiration should be enforced at redirect time or via a background cleanup job.

4. **Hardcoded DB host in K8s manifests**
   - `DB_HOST` is a specific `*.database.windows.net` host string in manifests.
   - Bicep generates SQL server names with a unique suffix. Ensure the host matches the actual deployed SQL server name.

5. **Third-party geolocation dependency**
   - Frontend calls `ip-api.com` directly for IP → country mapping.
   - This has privacy/data governance and rate-limit implications.

---

## 8) Suggested “first week” read order (high leverage)

1. Caddy routing: `kubernetes/frontend/configmap.yaml`
2. Infra: `bicep/main.bicep` and `bicep/core.bicep`
3. Redirect function: `services/redirect-service/src/*` + `services/redirect-service/redirect/function.json`
4. Link management: `services/link-management-service/cmd/server/main.go` + `internal/service/link_service.go`
5. Auth: `services/auth-service/cmd/server/main.go` + `internal/service/auth_service.go`
6. Analytics: `services/analytics-processing-service/index.js` and `services/analytics-query-service/src/index.js`
7. Frontend integration: `services/frontend/src/views/Dashboard.vue` and `services/frontend/src/views/Analytics.vue`

---

## 9) Glossary

- **AKS**: Azure Kubernetes Service.
- **Azure Functions Custom Handler**: Functions host forwards HTTP requests to a custom web server binary.
- **Hot path**: latency-sensitive redirect lookup and response.
- **Async path**: analytics pipeline (queue + worker + Cosmos).
- **JWT**: JSON Web Token used for auth between frontend and APIs.
- **SAS**: Shared Access Signature token used to call Service Bus REST endpoints.

---

## 10) DevOps / CI/CD (how code becomes running workloads)

This repo uses **GitHub Actions** to build and deploy each service independently.

Source of truth:

- `.github/workflows/*.yml`

### 10.1 Containerized services (AKS)

For these services:

- `frontend`
- `auth-service`
- `link-management-service`
- `analytics-query-service`
- `analytics-processing-service`

the CI pipeline generally does:

1. Build a Docker image.
2. Push the image to **GitHub Container Registry (GHCR)**.
3. `kubectl apply` the Kubernetes manifests under `kubernetes/<service>/`.
4. `kubectl rollout restart deployment/<...>` to force pulling the new image.

Important characteristics:

- Image tags: `latest` and `main-<sha>` (metadata action).
- The deployment manifests use `:latest`, so the rollout restart is what ensures pods pull the newest image.
- The workflows use a fixed `RESOURCE_GROUP` and `CLUSTER_NAME` (currently `rg-us-prod` and `us-aks-p6ndmuotrzo5a`).

Workflows:

- `.github/workflows/frontend.yml`
- `.github/workflows/auth-service.yml`
- `.github/workflows/link-management-service.yml`
- `.github/workflows/analytics-query-service.yml`
- `.github/workflows/analytics-processing-service.yml`

### 10.2 Redirect function (Azure Functions custom handler)

The redirect function is deployed via a dedicated pipeline that:

1. Builds a static Linux Rust binary (`x86_64-unknown-linux-musl`).
2. Copies the binary to the function package root as `redirect-service` (custom handler executable).
3. Deploys the folder `services/redirect-service` to the configured Function App using `Azure/functions-action@v1`.

Workflow:

- `.github/workflows/redirect-service.yml`

Operational note:

- The Function App name is hardcoded in the workflow (`AZURE_FUNCTIONAPP_NAME: us-func-p6ndmuotrzo5a`) and must match the deployed environment.

### 10.3 Database migrations

There is a pipeline intended to apply SQL schema scripts by launching a Kubernetes Job that runs `sqlcmd` against Azure SQL:

- Creates/updates a ConfigMap containing `services/auth-service/init.sql` and `services/link-management-service/init.sql`.
- Runs `mcr.microsoft.com/mssql-tools` in a Job and executes both scripts.
- Uses `db-secrets/password` as the SQL password.

Workflow:

- `.github/workflows/db-migration.yml`

Important characteristics:

- The SQL server hostname is hardcoded in the workflow job command (`us-sql-p6ndmuotrzo5a.database.windows.net`). If the SQL server name changes (Bicep unique suffix), this pipeline must be updated.
