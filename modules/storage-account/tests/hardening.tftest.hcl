mock_provider "azurerm" {
  mock_resource "azurerm_storage_account" {
    defaults = {
      id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/sttptest001"
      primary_dfs_endpoint = "https://sttptest001.dfs.core.windows.net/"
    }
  }
}

variables {
  name                = "sttptest001"
  resource_group_name = "rg-test"
  location            = "westeurope"
  containers          = ["raw"]
  allowed_subnet_ids  = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-apps"]
}

run "keys_and_plain_http_are_off" {
  command = plan

  assert {
    condition     = azurerm_storage_account.this.https_traffic_only_enabled == true
    error_message = "HTTPS must be required."
  }

  assert {
    condition     = azurerm_storage_account.this.shared_access_key_enabled == false
    error_message = "Shared keys must be disabled; access is through Entra ID."
  }
}

run "defaults_are_lrs_without_hierarchical_namespace" {
  command = plan

  assert {
    condition     = azurerm_storage_account.this.account_replication_type == "LRS" && azurerm_storage_account.this.is_hns_enabled == false
    error_message = "Defaults must be LRS and no hierarchical namespace."
  }
}

run "account_is_standard_storagev2_with_blob_soft_delete" {
  command = plan

  assert {
    condition     = azurerm_storage_account.this.account_tier == "Standard" && azurerm_storage_account.this.account_kind == "StorageV2"
    error_message = "The account must be Standard StorageV2 (required for data lake)."
  }

  assert {
    condition     = azurerm_storage_account.this.blob_properties[0].delete_retention_policy[0].days == 7
    error_message = "Deleted blobs must be retained for 7 days."
  }
}

run "data_lake_turns_on_hierarchical_namespace" {
  command = plan

  variables {
    is_data_lake = true
  }

  assert {
    condition     = azurerm_storage_account.this.is_hns_enabled == true
    error_message = "is_data_lake must enable the hierarchical namespace."
  }
}

run "network_rules_allow_only_given_subnets_and_azure_services" {
  command = plan

  assert {
    condition     = azurerm_storage_account_network_rules.this.virtual_network_subnet_ids == toset(var.allowed_subnet_ids)
    error_message = "Only the allowed subnets may reach the account."
  }

  assert {
    condition     = azurerm_storage_account_network_rules.this.bypass == toset(["AzureServices"])
    error_message = "Only AzureServices may bypass the firewall."
  }
}

run "containers_are_private_and_optional" {
  command = plan

  assert {
    condition     = alltrue([for c in azurerm_storage_container.this : c.container_access_type == "private"])
    error_message = "Containers must be private."
  }
}

run "no_containers_by_default" {
  command = plan

  variables {
    containers = []
  }

  assert {
    condition     = length(azurerm_storage_container.this) == 0
    error_message = "An empty container set must create none."
  }
}

run "accepts_boundary_name_lengths" {
  command = plan

  variables {
    name = "abc"
  }

  assert {
    condition     = azurerm_storage_account.this.name == "abc"
    error_message = "A 3-character name is valid and must be used as given."
  }
}

run "rejects_name_longer_than_24" {
  command = plan

  variables {
    name = "abcdefghijklmnopqrstuvwxy"
  }

  expect_failures = [var.name]
}

run "outputs_expose_account" {
  command = apply

  assert {
    condition     = output.primary_dfs_endpoint == "https://sttptest001.dfs.core.windows.net/"
    error_message = "primary_dfs_endpoint must expose the account's DFS endpoint."
  }

  assert {
    condition     = output.name == var.name
    error_message = "name output must be the account name."
  }
}
