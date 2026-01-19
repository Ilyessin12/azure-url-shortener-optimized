# KNOWN_ISSUES

Date: 2026-01-19

This is a **repo-grounded** list of known issues, mismatches, and operational hazards discovered during architecture review. Items are grouped by severity/impact, with concrete next actions.

---

## Priority 0 (likely to break deployments or cause major drift)

### 0.1 Hardcoded environment names across manifests and workflows

Evidence:

- Kubernetes manifests hardcode:
  - SQL hostname: `us-sql-p6ndmuotrzo5a.database.windows.net`
  - Function upstream: `https://us-func-p6ndmuotrzo5a.azurewebsites.net`
- GitHub workflows hardcode:
  - `RESOURCE_GROUP: rg-us-prod`
  - `CLUSTER_NAME: us-aks-p6ndmuotrzo5a`
  - `AZURE_FUNCTIONAPP_NAME: us-func-p6ndmuotrzo5a`
  - SQL hostname in DB migration job command
- Bicep generates names with a unique suffix based on the resource group id.

Impact:

- Redeploying IaC (new RG, new suffix, different prefix) will silently break:
  - AKS deployments (wrong cluster name)
  - SQL connectivity (wrong host)
  - redirects (wrong Function upstream)
  - DB migration job

Suggested fix:

- Introduce environment parameterization:
  - Use GitHub Actions environments/variables or a `.env`-style source for `RESOURCE_GROUP`, `CLUSTER_NAME`, `FUNCTIONAPP_NAME`, `SQL_HOST`.
  - Consider generating K8s manifests from templates (kustomize/helm) so `DB_HOST` and Function upstream are not hardcoded.

---

### 0.2 DB migration pipeline trigger does not cover all schema changes

Evidence:

- `.github/workflows/db-migration.yml` triggers on changes to:
  - `services/auth-service/init.sql`
- But the job also applies:
  - `services/link-management-service/init.sql`

Impact:

- Updating link schema may not trigger migrations unless you manually run the workflow.

Suggested fix:

- Add `services/link-management-service/init.sql` to the workflow `on.push.paths` list.

---

## Priority 1 (prod correctness / reliability / security)

### 1.1 Redirect status code mismatch (docs vs implementation)

Evidence:

- README and docs claim HTTP 301.
- OpenAPI snippet in `docs/api.yml` claims 302.
- Rust handler uses a temporary redirect (`axum::response::Redirect::temporary`).

Impact:

- Client caching, SEO semantics, and expected behavior can differ.

Suggested fix:

- Decide on desired redirect semantics (301/302/307) and align:
  - redirect implementation
  - README
  - OpenAPI

---

### 1.2 Cache eviction feature appears unimplemented in deployed redirect function

Evidence:

- `link-management-service` calls `DELETE {CACHE_EVICTION_URL}/{shortCode}`.
- K8s sets `CACHE_EVICTION_URL=https://.../api/cache`.
- Rust custom handler exposes only `/api/:short_code`.

Impact:

- Every update/delete triggers a background HTTP call that is likely to 404.
- This adds noise in logs and can mislead debugging.

Suggested fix:

- Either implement a cache eviction endpoint (and the cache) or remove the feature entirely.

---

### 1.3 Guest link expiration is set but not enforced by redirect

Evidence:

- Link creation sets `ExpiresAt` for guests.
- Redirect lookup currently filters only by `IsActive` (not `ExpiresAt`).

Impact:

- Guest links may continue to work beyond intended lifetime.

Suggested fix:

- Enforce expiration in redirect lookup (SQL predicate or Rust filter), or add a cleanup job that deactivates expired links.

---

### 1.4 Azure Functions secret name mismatch (easy to misconfigure)

Evidence:

- Function App setting `ServiceBusConnectionString` references Key Vault secret name `ServiceBusConnection`.

Impact:

- Operators might create a KV secret named `ServiceBusConnectionString` and still fail.

Suggested fix:

- Standardize naming (either change KV secret name to match setting, or change the app setting reference) and document it prominently.

---

### 1.5 CI/CD uses `:latest` in manifests (non-deterministic deployments)

Evidence:

- Workflows push both `latest` and `main-<sha>`, but manifests reference `:latest`.

Impact:

- Rollbacks and reproducibility are hard.
- Race conditions are possible if multiple pipelines push `latest` quickly.

Suggested fix:

- Deploy immutable tags (e.g., `main-<sha>`) via manifest templating or kustomize image overrides.

---

## Priority 2 (maintainability / “gotchas” / onboarding hazards)

### 2.1 Caddy configuration source of truth is the Kubernetes ConfigMap

What you remembered (and what’s true here):

- In this repo, there is no standalone `Caddyfile` checked in as a file.
- The actual Caddy config is stored inside the Kubernetes ConfigMap:
  - `kubernetes/frontend/configmap.yaml` (`data.Caddyfile: | ...`)

Impact:

- Editing a hypothetical “Caddyfile in the container/image” won’t change behavior in AKS.
- Running the `frontend` container outside Kubernetes (without mounting the ConfigMap to `/etc/caddy/Caddyfile`) will likely not reproduce production routing.

Suggested fix:

- Treat the ConfigMap as the single source of truth.
- If you want local parity, consider adding a real `services/frontend/Caddyfile` used in Docker builds, and have K8s mount override it (or generate ConfigMap from that file).

---

### 2.2 Analytics query service Dockerfile port mismatch

Evidence:

- `services/analytics-query-service/Dockerfile` exposes `8080`, but the service listens on `PORT=3001` in Kubernetes.

Impact:

- Confusing for developers/operators; doesn’t break runtime by itself but causes wrong expectations.

Suggested fix:

- Align Dockerfile `EXPOSE` to 3001 (or adjust runtime to 8080).

---

### 2.3 Frontend Dockerfile only exposes 80 but AKS exposes 80/443

Evidence:

- `services/frontend/Dockerfile` uses `EXPOSE 80`.
- `kubernetes/frontend/deployment.yaml` declares container ports 80 and 443.

Impact:

- Mostly documentation-level mismatch (EXPOSE doesn’t enforce ports), but can confuse local runs.

Suggested fix:

- Add `EXPOSE 443` or document that TLS is enabled by Caddy and K8s service exposes 443.

---

### 2.4 GitHub Actions auth model (secret-based) despite id-token permissions

Evidence:

- Workflows grant `id-token: write` but still use `azure/login@v1` with `AZURE_CREDENTIALS`.

Impact:

- Service principal secret rotation burden.

Suggested fix:

- Consider moving to OIDC-based Azure login (federated credentials) so you can drop long-lived `AZURE_CREDENTIALS`.

---

## Suggested next actions (fastest wins)

1. Fix DB migration workflow trigger paths to include link schema.
2. Parameterize hardcoded environment names (AKS/SQL/Function) across manifests + workflows.
3. Decide redirect status code and align docs + implementation.
4. Remove or implement cache eviction.
5. Move to immutable image tag deployments.
