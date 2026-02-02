# ARCHITECTURE_DIAGRAM

This file contains Mermaid diagrams that represent the entire codebase architecture.

Notes:

- The **public edge** is Caddy inside the `frontend` pod (AKS). It serves SPA assets and routes requests.
- Azure Functions HTTP triggers default to the `/api` prefix; the redirect function trigger route is `{short_code}`.
- `local-dep/` is intentionally omitted from diagrams because it is unused in the current cloud deployment.

---

## 1) System component diagram

```mermaid
flowchart TD
  %% External
  U[User Browser]

  %% Public edge
  subgraph AKS[Azure Kubernetes Service (AKS)]
    subgraph FE[frontend pod]
      C[Caddy (TLS + reverse proxy + static SPA)]
      SPA[Vue SPA (static assets)]
    end

    AS[auth-service (Go/Gin)]
    LMS[link-management-service (Go/Gin)]
    AQS[analytics-query-service (Node/Express)]
    APS[analytics-processing-service (Node worker)]
  end

  subgraph Azure[Azure Managed Services]
    SQL[(Azure SQL: links-db)]
    SB[(Azure Service Bus: analytics-queue)]
    COSMOS[(Cosmos DB: analytics-db/clicks)]
    KV[(Key Vault: SqlConnectionString + ServiceBusConnection)]
    SA[(Storage Account: AzureWebJobsStorage)]
  end

  subgraph Func[Azure Functions]
    F[redirect-service (Rust custom handler)]
  end

  %% User -> edge
  U -->|HTTPS 443| C
  C -->|serves| SPA

  %% API routing (Caddy)
  C -->|/api/auth/*| AS
  C -->|/api/links/*| LMS
  C -->|/api/analytics/*| AQS

  %% Short links
  C -->|rewrite /{code} -> /api/{code}| F

  %% Data dependencies
  AS --> SQL
  LMS --> SQL

  %% Redirect dependencies
  F -->|lookup ShortCode| SQL
  F -->|enqueue click event| SB

  %% Analytics pipeline
  APS -->|receive| SB
  APS -->|write click docs| COSMOS
  AQS -->|query + aggregate| COSMOS

  %% App configuration
  F -. KeyVault refs .-> KV
  F -. storage binding .-> SA

  %% Optional integration
  SPA -. IP geolocation (client-side) .-> IPAPI[(ip-api.com)]
```

---

## 2) Redirect (hot path) sequence

```mermaid
sequenceDiagram
  autonumber
  participant Browser as User Browser
  participant Caddy as Caddy (frontend pod)
  participant Func as Azure Functions Host
  participant Redirect as redirect-service (Rust)
  participant SQL as Azure SQL (links-db)
  participant SB as Service Bus (analytics-queue)

  Browser->>Caddy: GET /{shortCode}
  Caddy->>Func: GET /api/{shortCode}
  Func->>Redirect: Forward HTTP request (custom handler)
  Redirect->>SQL: SELECT OriginalUrl, IsActive WHERE ShortCode

  alt Found and IsActive=true
    Redirect-->>Browser: 307 Temporary Redirect (Location: OriginalUrl)
    par Async analytics emission
      Redirect->>SB: POST message {short_code, original_url, timestamp, user_agent, ip_address}
    end
  else Not found or inactive
    Redirect-->>Browser: 404 Link not found
  else DB error
    Redirect-->>Browser: 500 DB Failure
  end
```

---

## 3) Auth (register + login) sequence

```mermaid
sequenceDiagram
  autonumber
  participant Browser as User Browser
  participant Caddy as Caddy (frontend pod)
  participant Auth as auth-service (Go)
  participant SQL as Azure SQL (links-db)

  Browser->>Caddy: POST /api/auth/register {username,password}
  Caddy->>Auth: POST /api/auth/register
  Auth->>SQL: INSERT Users (bcrypt hash)
  Auth-->>Browser: 201 Created (user)

  Browser->>Caddy: POST /api/auth/login {username,password}
  Caddy->>Auth: POST /api/auth/login
  Auth->>SQL: SELECT user by username
  Auth-->>Browser: 200 OK {token,user}
  Note over Browser: SPA stores token in localStorage
```

---

## 4) Link creation / update / delete sequence

```mermaid
sequenceDiagram
  autonumber
  participant Browser as User Browser
  participant Caddy as Caddy (frontend pod)
  participant Links as link-management-service (Go)
  participant SQL as Azure SQL (links-db)
  participant Func as redirect-service (Azure Function)

  %% Create (guest or user)
  Browser->>Caddy: POST /api/links {originalUrl, customAlias?}
  Caddy->>Links: POST /api/links

  alt No Authorization header
    Note over Links: Treated as Guest; customAlias rejected
    Links->>SQL: INSERT Links (ExpiresAt=now+24h)
    Links-->>Browser: 201 Created (link)
  else Has JWT
    Note over Links: Extract sub (userID) and role
    Links->>SQL: INSERT Links (quota checks)
    Links-->>Browser: 201 Created (link)
  end

  %% Update (requires JWT)
  Browser->>Caddy: PUT /api/links/{shortCode} {originalUrl} (Authorization: Bearer)
  Caddy->>Links: PUT /api/links/{shortCode}
  Links->>SQL: SELECT link by ShortCode
  Links->>SQL: UPDATE Links SET OriginalUrl
  Links-->>Browser: 200 OK (updated link)
  Note over Links: Also attempts async cache eviction via DELETE {CACHE_EVICTION_URL}/{shortCode}

  %% Delete (requires JWT)
  Browser->>Caddy: DELETE /api/links/{shortCode} (Authorization: Bearer)
  Caddy->>Links: DELETE /api/links/{shortCode}
  Links->>SQL: SELECT link by ShortCode
  Links->>SQL: DELETE FROM Links
  Links-->>Browser: 200 OK
  Note over Links: Also attempts async cache eviction

  Note over Func: Current Rust redirect service does not expose /api/cache in this repo.
```

---

## 5) Analytics processing (async path) sequence

```mermaid
sequenceDiagram
  autonumber
  participant Redirect as redirect-service (Rust)
  participant SB as Service Bus (analytics-queue)
  participant Worker as analytics-processing-service (Node)
  participant Cosmos as Cosmos DB (analytics-db/clicks)

  Redirect->>SB: Send click event message
  SB-->>Worker: Deliver message
  Worker->>Cosmos: Insert document (partition: short_code)

  alt Insert succeeded
    Worker->>SB: Complete message
  else Insert failed
    Worker->>SB: Abandon message (retry)
  end
```

---

## 6) Analytics query + frontend enrichment sequence

```mermaid
sequenceDiagram
  autonumber
  participant Browser as User Browser (SPA)
  participant Caddy as Caddy (frontend pod)
  participant Query as analytics-query-service (Node)
  participant Cosmos as Cosmos DB
  participant IPAPI as ip-api.com

  Browser->>Caddy: GET /api/analytics/{shortCode}
  Caddy->>Query: GET /api/analytics/{shortCode}
  Query->>Cosmos: SELECT * WHERE short_code={shortCode}
  Cosmos-->>Query: event documents
  Query-->>Browser: aggregated stats (browsers, os, locations, timeline)

  Note over Browser: SPA optionally enriches IPs client-side
  loop for each IP
    Browser->>IPAPI: GET /json/{ip}
    IPAPI-->>Browser: country info
  end
```

---

## 7) CI/CD delivery diagram (GitHub Actions)

```mermaid
flowchart LR
  Dev[Developer pushes to main]
  GH[GitHub Repo]
  GHA[GitHub Actions]
  GHCR[(GHCR: container images)]
  AKS[AKS cluster]
  K8s[(kubernetes/*.yaml)]
  FuncApp[Azure Function App]
  FuncPkg[(Function package: services/redirect-service)]
  SQLJob[K8s Job: db-migration-job]
  SQL[(Azure SQL)]

  Dev --> GH --> GHA

  %% AKS services
  GHA -->|docker build/push| GHCR
  GHA -->|kubectl apply| K8s
  GHA -->|rollout restart| AKS
  GHCR -->|image pull| AKS

  %% Redirect function
  GHA -->|build musl static binary| FuncPkg
  GHA -->|Azure/functions-action deploy| FuncApp

  %% DB migrations
  GHA -->|kubectl apply Job| SQLJob
  SQLJob -->|sqlcmd runs init.sql| SQL
```

---

## 8) CI/CD sequence (AKS services)

```mermaid
sequenceDiagram
  autonumber
  participant Dev as Developer
  participant GH as GitHub
  participant GHA as GitHub Actions
  participant GHCR as GHCR
  participant AKS as AKS

  Dev->>GH: push to main (services/<svc> or kubernetes/<svc>)
  GH-->>GHA: workflow triggers
  GHA->>GHCR: docker build + push (:latest, main-<sha>)
  GHA->>AKS: kubectl apply kubernetes/<svc>/*.yaml
  GHA->>AKS: kubectl rollout restart deployment/<svc>
  AKS->>GHCR: pull image :latest
```

---

## 9) CI/CD sequence (redirect-service Azure Functions)

```mermaid
sequenceDiagram
  autonumber
  participant Dev as Developer
  participant GH as GitHub
  participant GHA as GitHub Actions
  participant Func as Azure Functions

  Dev->>GH: push to main (services/redirect-service/**)
  GH-->>GHA: redirect-service workflow triggers
  GHA->>GHA: install Rust + musl tools
  GHA->>GHA: cargo build --release (musl)
  GHA->>Func: deploy package (services/redirect-service)
```
