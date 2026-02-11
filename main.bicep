// =====================================================================
// Workaround for GitHub Issue #1659:
//   Container Apps v2 breaks Keycloak clustering (JDBC_PING)
//   https://github.com/microsoft/azure-container-apps/issues/1659
//
// Problem:
//   In Container Apps v2 (workload profiles), replicas of the same app
//   receive non-routable overlay IPs (169.254.x.x / 100.100.x.x).
//   JGroups picks one of these as bind_addr and advertises it in the
//   JDBC_PING table. Other replicas cannot reach these addresses, so
//   the Keycloak/Infinispan cluster never forms.
//
// Workaround:
//   Deploy each Keycloak "replica" as a separate container app (1 replica
//   each). Apps within the same environment can reach each other via
//   their app name (e.g. "keycloak-1:7800") which resolves to a routable
//   service IP. A startup script resolves this IP and passes it to
//   JGroups as external_addr / external_port so the JDBC_PING table
//   contains routable addresses. Each app exposes a unique TCP port for
//   JGroups via additionalPortMappings.
//
// Usage:
//   az group create -n <rg> -l swedencentral
//   az deployment group create -g <rg> -f main.bicep \
//     -p postgresPassword='<password>'
// =====================================================================

@description('Azure region for all resources')
param location string = 'swedencentral'

@secure()
@description('PostgreSQL administrator password')
param postgresPassword string

@description('Keycloak admin password')
param keycloakAdminPassword string = 'admin'

// --------------- Variables ---------------

var uniqueSuffix = uniqueString(resourceGroup().id)
var vnetName = 'vnet-repro'
var subnetName = 'snet-infra'
var envName = 'cae-repro'
var psqlName = 'psql-${uniqueSuffix}'
var lawName = 'law-${uniqueSuffix}'
var keycloakImage = 'quay.io/keycloak/keycloak:26.1'

// Each Keycloak node gets a unique exposed TCP port for JGroups
var nodes = [
  { name: 'keycloak-1', jgroupsPort: 7800, external: true }
  { name: 'keycloak-2', jgroupsPort: 7801, external: false }
  { name: 'keycloak-3', jgroupsPort: 7802, external: false }
]

// Startup script: resolves the app's service name to a routable IP and
// passes it to JGroups as external_addr. This is the key to the workaround —
// within a Container Apps environment, apps can reach each other via
// "<app-name>:<port>" which routes through the internal service mesh.
var startupScript = '''
echo "[workaround] Resolving app name for JGroups external_addr..."
MAX_RETRIES=30; RETRY=0
while ! getent hosts "${APP_NAME}" >/dev/null 2>&1; do
  RETRY=$((RETRY + 1))
  if [ $RETRY -ge $MAX_RETRIES ]; then
    echo "[workaround] ERROR: Could not resolve ${APP_NAME}"; exit 1
  fi
  echo "[workaround] Waiting for ${APP_NAME} (${RETRY}/${MAX_RETRIES})..."
  sleep 5
done
EXT_IP=$(getent hosts "${APP_NAME}" | head -1 | cut -d' ' -f1)
echo "[workaround] ${APP_NAME} -> ${EXT_IP}, JGroups external port: ${JGROUPS_EXT_PORT}"
export JAVA_OPTS_APPEND="-Djgroups.external_addr=${EXT_IP} -Djgroups.external_port=${JGROUPS_EXT_PORT}"
exec /opt/keycloak/bin/kc.sh start-dev
'''

// --------------- Networking ---------------

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.0.0/23'
          delegations: [
            {
              name: 'envDelegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

// --------------- Logging ---------------

resource law 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: lawName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// --------------- Container Apps Environment (v2) ---------------

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: envName
  location: location
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: vnet.properties.subnets[0].id
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

// --------------- PostgreSQL ---------------

resource psql 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' = {
  name: psqlName
  location: location
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '16'
    administratorLogin: 'kcadmin'
    administratorLoginPassword: postgresPassword
    storage: { storageSizeGB: 32 }
  }
}

resource psqlDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = {
  parent: psql
  name: 'keycloak'
}

resource psqlFirewallAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-12-01-preview' = {
  parent: psql
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// --------------- Keycloak Container Apps (one per "node") ---------------

resource keycloakApps 'Microsoft.App/containerApps@2024-03-01' = [
  for (node, i) in nodes: {
    name: node.name
    location: location
    dependsOn: [psqlDb, psqlFirewallAzure]
    properties: {
      environmentId: env.id
      configuration: {
        secrets: [
          { name: 'db-password', value: postgresPassword }
        ]
        ingress: {
          external: node.external
          targetPort: 8080
          transport: 'auto'
          additionalPortMappings: [
            {
              external: false
              targetPort: 7800
              exposedPort: node.jgroupsPort
            }
          ]
        }
      }
      template: {
        scale: {
          minReplicas: 1
          maxReplicas: 1
        }
        containers: [
          {
            name: 'keycloak'
            image: keycloakImage
            resources: {
              cpu: json('1.0')
              memory: '2Gi'
            }
            command: ['/bin/sh', '-c']
            args: [startupScript]
            env: [
              { name: 'KC_DB', value: 'postgres' }
              {
                name: 'KC_DB_URL'
                value: 'jdbc:postgresql://${psql.properties.fullyQualifiedDomainName}:5432/keycloak'
              }
              { name: 'KC_DB_USERNAME', value: 'kcadmin' }
              { name: 'KC_DB_PASSWORD', secretRef: 'db-password' }
              { name: 'KC_HEALTH_ENABLED', value: 'true' }
              { name: 'KC_CACHE', value: 'ispn' }
              { name: 'KC_CACHE_STACK', value: 'jdbc-ping' }
              { name: 'KC_BOOTSTRAP_ADMIN_USERNAME', value: 'admin' }
              { name: 'KC_BOOTSTRAP_ADMIN_PASSWORD', value: keycloakAdminPassword }
              { name: 'APP_NAME', value: node.name }
              { name: 'JGROUPS_EXT_PORT', value: string(node.jgroupsPort) }
            ]
          }
        ]
      }
    }
  }
]

// --------------- Outputs ---------------

output keycloak1Fqdn string = keycloakApps[0].properties.configuration.ingress.fqdn
output environmentDefaultDomain string = env.properties.defaultDomain
output postgresqlFqdn string = psql.properties.fullyQualifiedDomainName
