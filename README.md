# Keycloak Clustering on Azure Container Apps v2

A workaround for [microsoft/azure-container-apps#1659](https://github.com/microsoft/azure-container-apps/issues/1659) — Keycloak's JDBC_PING-based clustering breaks on Container Apps v2 (workload profiles) because replicas receive non-routable overlay IPs.

## The Problem

In Container Apps v2, pods get overlay IPs (`169.254.x.x` / `100.100.x.x`) instead of VNET IPs. JGroups picks one of these as its bind address and advertises it in the JDBC_PING discovery table. Other replicas can't reach these addresses, so the Infinispan cluster never forms.

## The Workaround

Instead of deploying one container app with N replicas, deploy N separate container apps with 1 replica each. Within the same environment, apps can reach each other over TCP via `<app-name>:<port>`, which resolves to a routable service IP.

A startup script resolves the app's own service name, then passes the resulting IP to JGroups as `external_addr` / `external_port`. Each app exposes a unique TCP port for JGroups via `additionalPortMappings`.

## What Gets Deployed

- A VNet with a delegated subnet for the Container Apps environment
- A Container Apps Environment v2 (workload profiles, Consumption plan)
- A PostgreSQL Flexible Server (Burstable B1ms) with a `keycloak` database
- 3 Keycloak container apps (`keycloak-1`, `keycloak-2`, `keycloak-3`), each with 1 replica

## Usage

```bash
az group create -n my-keycloak-rg -l swedencentral

az deployment group create \
  -g my-keycloak-rg \
  -f main.bicep \
  -p postgresPassword='YourSecurePassword123'
```

Only `keycloak-1` has external ingress enabled. The other two are internal only. All three form a single Infinispan cluster via JDBC_PING over PostgreSQL.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `postgresPassword` | Yes | — | PostgreSQL admin password |
| `keycloakAdminPassword` | No | `admin` | Keycloak bootstrap admin password |
| `location` | No | `swedencentral` | Azure region |

## Notes

- This is a workaround, not a permanent fix. It trades the simplicity of replicas for working cluster discovery.
- On redeployments, stale entries may linger in the `jgroups_ping` table. JGroups' MERGE protocol will eventually reconcile, but you can speed things up by truncating the table before deploying new revisions.
- The `additionalPortMappings` exposed ports (7800, 7801, 7802) must be unique per environment.
