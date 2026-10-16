mock_provider "azurerm" {
  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.KeyVault/vaults/kv-tp-test"
      vault_uri = "https://kv-tp-test.vault.azure.net/"
    }
  }

  mock_data "azurerm_role_definition" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"
    }
  }
}

variables {
  name                = "kv-tp-test"
  resource_group_name = "rg-test"
  location            = "westeurope"
  tenant_id           = "00000000-0000-0000-0000-000000000000"
  allowed_subnet_ids  = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-apps"]
  secret_readers = {
    adf  = "11111111-1111-1111-1111-111111111111"
    func = "22222222-2222-2222-2222-222222222222"
  }
}

run "network_is_denied_by_default" {
  command = plan

  assert {
    condition     = azurerm_key_vault.this.network_acls[0].default_action == "Deny"
    error_message = "The vault firewall must deny by default."
  }

  assert {
    condition     = azurerm_key_vault.this.network_acls[0].virtual_network_subnet_ids == toset(var.allowed_subnet_ids)
    error_message = "Only the allowed subnets may reach the vault."
  }
}

run "trusted_azure_services_may_bypass_the_firewall" {
  command = plan

  assert {
    condition     = azurerm_key_vault.this.network_acls[0].bypass == "AzureServices"
    error_message = "Only trusted Azure services may bypass the vault firewall."
  }
}

run "retention_is_30_days" {
  command = plan

  assert {
    condition     = azurerm_key_vault.this.soft_delete_retention_days == 30
    error_message = "Soft delete retention must be 30 days."
  }
}

run "deny_with_no_subnets_when_none_given" {
  command = plan

  variables {
    allowed_subnet_ids = []
  }

  assert {
    condition     = azurerm_key_vault.this.network_acls[0].default_action == "Deny"
    error_message = "Default action must stay Deny when no subnet is allowed."
  }
}

run "no_role_assignments_without_readers" {
  command = plan

  variables {
    secret_readers = {}
  }

  assert {
    condition     = length(azurerm_role_assignment.secret_reader) == 0
    error_message = "No role assignment may exist for an empty secret_readers map."
  }
}

run "readers_get_the_secrets_user_role_on_the_vault" {
  command = apply

  assert {
    condition     = length(azurerm_role_assignment.secret_reader) == 2
    error_message = "Expected one assignment per reader."
  }

  assert {
    condition     = azurerm_role_assignment.secret_reader["func"].principal_id == "22222222-2222-2222-2222-222222222222"
    error_message = "Each assignment must use the principal of its key."
  }

  assert {
    condition     = azurerm_role_assignment.secret_reader["adf"].scope == azurerm_key_vault.this.id
    error_message = "Roles must be scoped to the vault."
  }

  assert {
    condition     = azurerm_role_assignment.secret_reader["adf"].role_definition_id == data.azurerm_role_definition.secrets_user.id
    error_message = "Readers must get the Key Vault Secrets User role."
  }

  assert {
    condition     = output.vault_uri == "https://kv-tp-test.vault.azure.net/"
    error_message = "vault_uri must expose the vault URI."
  }
}
