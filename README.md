# Project: Cloud-Native URL Shortener

This is the monorepo for our Cloud Technology project.

## Architecture

The system follows a cloud-native event-driven architecture using Azure Functions, Azure Service Bus, and Azure Kubernetes Service (AKS).

1.  **User Clicks Link** → Hits **Azure Function (Redirect Service)**.
2.  **Redirect Service** → Reads **Azure SQL** (Fast lookup) → Redirects User (HTTP 301).
3.  **Redirect Service** → Asynchronously pushes an event ("User Clicked") to **Azure Service Bus** (Queue).
4.  **Analytics Service (AKS Pod)** → Wakes up, pulls message from Queue → Writes to **Cosmos DB**.
5.  **Link Management (AKS Pod)** → CRUD API to create links → Writes to **Azure SQL**.

## Services

- **/services/link-management-service**: (AKS) Creates and manages short links.
- **/services/redirect-service**: (Azure Function) Handles the high-performance redirects.
- **/services/analytics-query-service**: (AKS) Serves aggregated analytics data.
- **/services/analytics-processing-service**: (AKS) Asynchronously processes click data from Service Bus.

### Preview

## Dashboard
<img width="1904" height="1081" alt="image" src="https://github.com/user-attachments/assets/1b2ea41b-2c16-4469-8d22-4b4ce394a574" />
<img width="1406" height="825" alt="image" src="https://github.com/user-attachments/assets/569ec516-2b01-4d68-aee5-e2abf582bac1" />
## Analytics
<img width="1427" height="978" alt="image" src="https://github.com/user-attachments/assets/908d8617-1e12-4d78-a921-c673c789ca58" />
<img width="1778" height="1005" alt="image" src="https://github.com/user-attachments/assets/d0d943ee-7399-49db-bd47-66c94c3685ff" />

