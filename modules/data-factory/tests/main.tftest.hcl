mock_provider "azurerm" {
  mock_resource "azurerm_data_factory" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.DataFactory/factories/adf-test"
      identity = { principal_id = "11111111-1111-1111-1111-111111111111" }
    }
  }
}

variables {
  name                       = "adf-test"
  resource_group_name        = "rg-test"
  location                   = "westeurope"
  log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/log-test"
  linked_storage_accounts = {
    raw     = "https://straw.dfs.core.windows.net/"
    curated = "https://stcurated.dfs.core.windows.net/"
  }
}

run "factory_uses_system_assigned_identity" {
  command = plan

  assert {
    condition     = azurerm_data_factory.this.identity[0].type == "SystemAssigned"
    error_message = "The factory must use a system-assigned managed identity."
  }
}

run "links_one_service_per_storage_account_with_managed_identity" {
  command = plan

  assert {
    condition     = length(azurerm_data_factory_linked_service_data_lake_storage_gen2.this) == 2
    error_message = "Expected one linked service for each entry in linked_storage_accounts."
  }

  assert {
    condition     = azurerm_data_factory_linked_service_data_lake_storage_gen2.this["raw"].name == "ls-raw"
    error_message = "Linked service names must be ls-<key>."
  }

  assert {
    condition     = azurerm_data_factory_linked_service_data_lake_storage_gen2.this["raw"].url == "https://straw.dfs.core.windows.net/"
    error_message = "The linked service must use the DFS endpoint given for its key."
  }

  assert {
    condition     = alltrue([for ls in azurerm_data_factory_linked_service_data_lake_storage_gen2.this : ls.use_managed_identity == true])
    error_message = "Linked services must authenticate with the managed identity, not keys."
  }
}

run "no_linked_services_without_storage_accounts" {
  command = plan

  variables {
    linked_storage_accounts = {}
  }

  assert {
    condition     = length(azurerm_data_factory_linked_service_data_lake_storage_gen2.this) == 0
    error_message = "No linked service may be created for an empty map."
  }
}

run "diagnostics_send_pipeline_and_activity_logs" {
  command = plan

  assert {
    condition     = azurerm_monitor_diagnostic_setting.this.name == "diag-adf-test"
    error_message = "The diagnostic setting must be named diag-<name>."
  }

  assert {
    condition     = azurerm_monitor_diagnostic_setting.this.log_analytics_workspace_id == var.log_analytics_workspace_id
    error_message = "Diagnostics must go to the given Log Analytics workspace."
  }

  assert {
    condition     = toset([for l in azurerm_monitor_diagnostic_setting.this.enabled_log : l.category]) == toset(["PipelineRuns", "ActivityRuns"])
    error_message = "Pipeline and activity run logs must be enabled."
  }
}

run "outputs_expose_id_and_identity" {
  command = apply

  assert {
    condition     = output.principal_id == "11111111-1111-1111-1111-111111111111"
    error_message = "principal_id must be the factory's managed identity principal."
  }

  assert {
    condition     = output.id == azurerm_data_factory.this.id
    error_message = "id must be the factory's resource ID."
  }
}
