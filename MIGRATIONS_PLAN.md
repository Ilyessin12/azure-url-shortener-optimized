# MIGRATIONS_PLAN

Goal: migrate the deployment into **your own Azure resource group** and **reduce cost** while keeping functionality intact.

This plan is grounded in:
- `bicep/main.bicep`, `bicep/core.bicep`
- `kubernetes/**`
- `.github/workflows/*.yml`
- `CLOUD_RESOURCES.md`, `KNOWN_ISSUES.md`, `OPERATIONS.md`, `RECENT_ARCHITECTURE.md`

---

## Phase 0 — Pick the fastest path (keep it running)

We’ll use **Track A only** for now (keep AKS + Service Bus, optimize sizes). This is the quickest and lowest-risk path to get your own environment running.

Track B (Container Apps + Event Hubs/Storage Queue) stays as a later option once your RG is stable.

---

## Phase 1 — Move to your own resource group (required)

### 1.1 Deploy infra into your subscription + RG
- Use `bicep/main.bicep` with your chosen `projectPrefix`, `location`, and `principalId`.
- Capture outputs:
  - `aksClusterName`
  - `keyVaultName`
  - `sqlServerName`
  - `cosmosAccountName`
  - `functionAppName`

**Manual task (Azure Portal / CLI):**
1. Deploy the Bicep template into your subscription.
2. Record the output names above (you’ll need them in CI/CD and manifests).

### 1.2 Create required Key Vault secrets
Add these secrets to your new Key Vault:
- `SqlConnectionString`
- `ServiceBusConnection`

**Manual task (Azure Portal):**
1. Go to Azure Portal → Your Key Vault → Secrets → Generate/Import.
2. Add:
  - `SqlConnectionString` (ADO format for Azure SQL)
  - `ServiceBusConnection` (Service Bus connection string with Send permission)

### 1.3 Recreate Kubernetes secrets in your new cluster
You must create these in your AKS namespace:
- `db-secrets` (`password`)
- `auth-secrets` (`jwt-secret`)
- `analytics-secrets` (`cosmos-connection-string`, `service-bus-connection-string`)

**Manual task (kubectl):**
1. Create the secrets in the target namespace (match the values used by the old deployment).
2. Verify they exist before deploying workloads.

### 1.4 Update hardcoded environment values (critical)
Based on `KNOWN_ISSUES.md`:
- Workflows hardcode `RESOURCE_GROUP`, `CLUSTER_NAME`, `AZURE_FUNCTIONAPP_NAME`, and SQL host.
- Manifests hardcode `DB_HOST` and the Function upstream URL.

**Action:** replace all hardcoded names with your new outputs.
Suggested method (no code changes yet):
- Update `.github/workflows/*.yml` env vars to your new:
  - `RESOURCE_GROUP`
  - `CLUSTER_NAME`
  - `AZURE_FUNCTIONAPP_NAME`
  - SQL host in the DB migration job
- Update Kubernetes manifests:
  - `DB_HOST` in `kubernetes/auth-service/deployment.yaml`
  - `DB_HOST` in `kubernetes/link-management-service/deployment.yaml`
  - Function upstream in `kubernetes/frontend/configmap.yaml`

**Manual task (GitHub repo settings):**
1. Go to your GitHub repo → Settings → Secrets and variables → Actions.
2. Add or update `AZURE_CREDENTIALS` for your own Azure subscription.

---

## Phase 2 — Stabilize CI/CD to your environment

### 2.1 Fix migration workflow trigger
Per `KNOWN_ISSUES.md`, update `.github/workflows/db-migration.yml` trigger paths to include:
- `services/link-management-service/init.sql`

### 2.2 Confirm images are accessible
All manifests use GHCR images. Ensure GHCR visibility or configure image pull secrets in AKS.

### 2.3 Consider moving to immutable tags
Still optional, but recommended:
- Deploy `main-<sha>` instead of `:latest`.
- Use kustomize or env substitution to inject tag values.

---

## Phase 3 — Cost optimization (Track A: keep AKS)

**Low-change, immediate cost wins**:

1. **Right-size AKS node pool**
	- Consider 1 node (if downtime risk is acceptable).
	- Use `B`-series (burstable) or `D`-series with lower cores.

2. **Scale down services with low traffic**
	- Use HPA or set `replicas: 1` for all non-critical services.

3. **Reduce Cosmos costs**
	- Serverless is already enabled; ensure no higher RU settings exist.

4. **Service Bus**
	- Basic tier is already used. Keep it unless you change the pipeline.

5. **Function App**
	- Consumption plan already used. No change needed.

6. **Defer non-essential logging**
	- Application Insights is not provisioned; keep it off unless needed.

---

## Phase 4 — Later (optional): Move off AKS + Service Bus

Skip for now. Revisit only after your RG is stable and costs are still high.

---

## Phase 5 — Clean-up and drift control

1. Update `CLOUD_RESOURCES.md` with your new naming and any service changes.
2. Add a new section to `KNOWN_ISSUES.md` if you decide on a redirect status code or cache eviction changes.
3. Document the chosen cost track and rationale in this file.

---

## Checklist (migration to your RG)

- [ ] Deployed `bicep/main.bicep` in your subscription
- [ ] Captured outputs and replaced hardcoded values in manifests + workflows
- [ ] Added KV secrets: `SqlConnectionString`, `ServiceBusConnection`
- [ ] Recreated AKS secrets: `db-secrets`, `auth-secrets`, `analytics-secrets`
- [ ] Updated Caddy upstream Function URL
- [ ] Updated DB migration workflow SQL host
- [ ] Ran pipelines and validated deployments

---

## Notes

- The existing Function App uses Key Vault references. Secret names must match **exactly**.
- The codebase assumes Azure SQL + Service Bus unless you implement Track B changes.
- Keep scope focused: first get a clean deployment in your RG, then optimize cost.