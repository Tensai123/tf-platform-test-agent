mock_provider "azurerm" {}

variables {
  name                = "dbw-test"
  resource_group_name = "rg-test"
  location            = "westeurope"
}

run "workers_have_no_public_ip" {
  command = plan

  assert {
    condition     = azurerm_databricks_workspace.this.custom_parameters[0].no_public_ip == true
    error_message = "Cluster nodes must not get public IPs."
  }
}

run "managed_resource_group_is_derived_from_names" {
  command = plan

  assert {
    condition     = azurerm_databricks_workspace.this.managed_resource_group_name == "rg-test-dbw-test-managed"
    error_message = "Managed resource group must be <resource group>-<name>-managed."
  }
}

run "default_sku_is_premium" {
  command = plan

  assert {
    condition     = azurerm_databricks_workspace.this.sku == "premium"
    error_message = "The default sku must be premium."
  }
}

run "accepts_standard_sku" {
  command = plan

  variables {
    sku = "standard"
  }

  assert {
    condition     = azurerm_databricks_workspace.this.sku == "standard"
    error_message = "standard is a valid sku."
  }
}

run "rejects_unknown_sku" {
  command = plan

  variables {
    sku = "trial"
  }

  expect_failures = [var.sku]
}

run "public_access_can_be_switched_off" {
  command = plan

  variables {
    public_network_access_enabled = false
  }

  assert {
    condition     = azurerm_databricks_workspace.this.public_network_access_enabled == false
    error_message = "Setting public_network_access_enabled to false must disable public access."
  }
}
