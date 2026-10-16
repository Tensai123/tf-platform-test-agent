mock_provider "azurerm" {
  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-tp-dev/providers/Microsoft.Network/virtualNetworks/vnet-tp-dev"
    }
  }

  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-tp-dev/providers/Microsoft.Network/virtualNetworks/vnet-tp-dev/subnets/snet-test"
    }
  }

  mock_resource "azurerm_network_security_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-tp-dev/providers/Microsoft.Network/networkSecurityGroups/nsg-test"
    }
  }

  mock_resource "azurerm_storage_account" {
    defaults = {
      id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-tp-dev/providers/Microsoft.Storage/storageAccounts/sttpdevraw"
      primary_dfs_endpoint = "https://sttpdevraw.dfs.core.windows.net/"
    }
  }

  mock_resource "azurerm_key_vault" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-tp-dev/providers/Microsoft.KeyVault/vaults/kv-tp-dev"
    }
  }

  mock_resource "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-tp-dev/providers/Microsoft.OperationalInsights/workspaces/log-tp-dev"
    }
  }

  mock_resource "azurerm_data_factory" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-tp-dev/providers/Microsoft.DataFactory/factories/adf-tp-dev"
      identity = { principal_id = "11111111-1111-1111-1111-111111111111" }
    }
  }

  mock_resource "azurerm_service_plan" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-tp-dev/providers/Microsoft.Web/serverFarms/asp-func-tp-dev"
    }
  }

  mock_resource "azurerm_linux_function_app" {
    defaults = {
      identity = { principal_id = "22222222-2222-2222-2222-222222222222" }
    }
  }

  mock_data "azurerm_role_definition" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"
    }
  }
}

mock_provider "external" {}

override_data {
  target = module.function_app.data.external.build_info
  values = {
    result = { revision = "abc1234" }
  }
}

variables {
  subscription_id    = "00000000-0000-0000-0000-000000000000"
  tenant_id          = "00000000-0000-0000-0000-000000000000"
  environment        = "dev"
  vnet_address_space = ["10.50.0.0/16"]
  data_lakes = {
    raw     = { containers = ["landing"] }
    curated = { containers = ["gold", "silver"] }
  }
}

run "names_and_tags_follow_the_environment" {
  command = plan

  assert {
    condition     = azurerm_resource_group.this.name == "rg-tp-dev"
    error_message = "The resource group must be rg-tp-<environment>."
  }

  assert {
    condition     = azurerm_resource_group.this.tags["environment"] == "dev" && azurerm_resource_group.this.tags["product"] == "data-platform" && azurerm_resource_group.this.tags["managed_by"] == "terraform"
    error_message = "The resource group must carry the standard tags."
  }
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}

run "network_has_apps_and_endpoints_subnets" {
  command = apply

  assert {
    condition     = toset(keys(module.network.subnet_ids)) == toset(["apps", "endpoints"])
    error_message = "The stack needs an apps subnet and an endpoints subnet."
  }
}

run "one_lake_and_two_endpoints_per_lake" {
  command = plan

  assert {
    condition     = length(module.data_lake) == 2
    error_message = "Expected one storage account per data lake key."
  }

  assert {
    condition     = toset(keys(module.lake_endpoint)) == toset(["raw-blob", "raw-dfs", "curated-blob", "curated-dfs"])
    error_message = "Each lake needs a blob and a dfs private endpoint."
  }
}
