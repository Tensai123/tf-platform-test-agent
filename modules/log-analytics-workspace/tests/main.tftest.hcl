mock_provider "azurerm" {}

variables {
  name                = "log-test"
  resource_group_name = "rg-test"
  location            = "westeurope"
}

run "defaults_use_pergb_sku_and_30_day_retention" {
  command = plan

  assert {
    condition     = azurerm_log_analytics_workspace.this.sku == "PerGB2018"
    error_message = "The workspace must use the PerGB2018 sku."
  }

  assert {
    condition     = azurerm_log_analytics_workspace.this.retention_in_days == 30
    error_message = "Default retention must be 30 days."
  }
}

run "retention_is_configurable" {
  command = plan

  variables {
    retention_in_days = 90
  }

  assert {
    condition     = azurerm_log_analytics_workspace.this.retention_in_days == 90
    error_message = "retention_in_days must reach the workspace."
  }
}

run "output_exposes_workspace_id" {
  command = apply

  assert {
    condition     = output.id == azurerm_log_analytics_workspace.this.id
    error_message = "id must be the workspace's resource ID."
  }
}
