terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.22.0"
    }
    azuread = {
      source  = "hashicorp/azuread",
      version = "~> 2.28.1"
    }
  }

  required_version = ">= 1.1.0"
}

provider "azurerm" {
  features {}
}

provider "azuread" {
}

// Bring in the current configuration of the client to do things like access the tenant_id
data "azurerm_client_config" "current" {
}

// Then bring in the user that's making these requests
data "azuread_client_config" "current" {
}

// Create the service principal for Github Actions to deploy to the Container Registry
data "azuread_service_principal" "github_actions" {
  application_id        = "20481032-be75-4a10-860f-4790b7041acf"
}

// Create the resource group for the DEV environment
resource "azurerm_resource_group" "rg" {
  name     = "aafdSignalRDEV004"
  location = "centralus"
}

// Create the Container Registry that will store the Docker images
resource "azurerm_container_registry" "acr" {
  name                = "aafdSignalRDEVContainerRegistry"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Standard"
  admin_enabled       = true
}

// Grant the Service Principal the ability to push to the Container Registry
resource "azurerm_role_assignment" "acr_sa" {
  scope                     = azurerm_container_registry.acr.id
  role_definition_name      = "AcrPush"
  principal_id              = data.azuread_service_principal.github_actions.id
}

// Create the App Insights for the Integration Engine Web App
resource "azurerm_application_insights" "integrationengine_ai" {
  name                  = "aafdSignalRDEVIntegrationEngineAI"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  application_type      = "web"
}

// Create the Key Vault to store secrets for the Integration Engine Web App
resource "azurerm_key_vault" "integrationengine_kv" {
  name                      = "aafdSignalRDEVIEKV004"
  location                  = azurerm_resource_group.rg.location
  resource_group_name       = azurerm_resource_group.rg.name
  tenant_id                 = data.azurerm_client_config.current.tenant_id
  sku_name                  = "premium"

  access_policy {
    object_id = data.azuread_client_config.current.object_id
    tenant_id = data.azurerm_client_config.current.tenant_id

    secret_permissions = [
       "Get", "List", "Set"
    ]
  }
}

// Then provision the secrets for the Integration Engine Key Vault
resource "azurerm_key_vault_secret" "integrationengine_docker_registry_server_url" {
  name                    = "DOCKER-REGISTRY-SERVER-URL"
  value                   = "https://${azurerm_container_registry.acr.login_server}"
  key_vault_id            = azurerm_key_vault.integrationengine_kv.id
}

resource "azurerm_key_vault_secret" "integrationengine_docker_registry_server_username" {
  name                    = "DOCKER-REGISTRY-SERVER-USERNAME"
  value                   = azurerm_container_registry.acr.admin_username
  key_vault_id            = azurerm_key_vault.integrationengine_kv.id
}

resource "azurerm_key_vault_secret" "integrationengine_docker_registry_server_password" {
  name                    = "DOCKER-REGISTRY-SERVER-PASSWORD"
  value                   = azurerm_container_registry.acr.admin_password
  key_vault_id            = azurerm_key_vault.integrationengine_kv.id
}

// Include the legacy APPINSIGHTS_INSTRUMENTATIONKEY
resource "azurerm_key_vault_secret" "integrationengine_appinsights_instrumentationkey" {
  name                    = "APPINSIGHTS-INSTRUMENTATIONKEY"
  value                   = azurerm_application_insights.integrationengine_ai.instrumentation_key
  key_vault_id            = azurerm_key_vault.integrationengine_kv.id
}

// As well as the newer APPLICATIONINSIGHTS_CONNECTION_STRING
resource "azurerm_key_vault_secret" "integrationengine_applicationinsights_connection_string" {
  name                    = "APPLICATIONINSIGHTS-CONNECTION-STRING"
  value                   = azurerm_application_insights.integrationengine_ai.connection_string
  key_vault_id            = azurerm_key_vault.integrationengine_kv.id
}

// Create the App Service Plan for the Integration Engine Web App
resource "azurerm_service_plan" "integrationengine_asp" {
  name                  = "aafdSignalRDEVIntegrationEngineASP"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  os_type               = "Linux"
  sku_name              = "P1v2"
}

resource "azurerm_linux_web_app" "integrationengine_api" {
  name                = "aafdSignalRDEVIntegrationEngineAPI"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  service_plan_id = azurerm_service_plan.integrationengine_asp.id

  identity {
    type    = "SystemAssigned"
  }

  site_config {
    always_on = "true"
    health_check_path = "/health"

    application_stack {
      docker_image = "${azurerm_container_registry.acr.login_server}/aafd-signalr-integrationengine-api"
      docker_image_tag = "latest"
    }
  }

  app_settings = {
    "DOCKER_REGISTRY_SERVER_URL" = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.integrationengine_docker_registry_server_url.versionless_id})"
    "DOCKER_REGISTRY_SERVER_USERNAME" = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.integrationengine_docker_registry_server_username.versionless_id})"
    "DOCKER_REGISTRY_SERVER_PASSWORD" = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.integrationengine_docker_registry_server_password.versionless_id})"
    "APPINSIGHTS_INSTRUMENTATIONKEY" = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.integrationengine_appinsights_instrumentationkey.versionless_id})"
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.integrationengine_applicationinsights_connection_string.versionless_id})"
  }
}

// Then create the policy that allows the Integration Engine Web App to read secret values from its Key Vault
resource "azurerm_key_vault_access_policy" "keyvault_policy" {
  key_vault_id            = azurerm_key_vault.integrationengine_kv.id
  object_id               = azurerm_linux_web_app.integrationengine_api.identity[0].principal_id
  tenant_id               = data.azurerm_client_config.current.tenant_id
  secret_permissions      = [
    "Get"
  ]
}