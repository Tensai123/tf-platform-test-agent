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

run "defaults_have_no_daily_cap" {
  command = plan

  assert {
    condition     = azurerm_log_analytics_workspace.this.daily_quota_gb == -1
    error_message = "Without daily_quota_gb the workspace must have no ingestion cap (-1)."
  }
}

run "daily_quota_reaches_workspace" {
  command = plan

  variables {
    daily_quota_gb = 1
  }

  assert {
    condition     = azurerm_log_analytics_workspace.this.daily_quota_gb == 1
    error_message = "daily_quota_gb must be passed to the workspace."
  }
}

run "rejects_retention_below_30" {
  command = plan

  variables {
    retention_in_days = 29
  }

  expect_failures = [var.retention_in_days]
}

run "rejects_retention_above_730" {
  command = plan

  variables {
    retention_in_days = 731
  }

  expect_failures = [var.retention_in_days]
}

run "accepts_retention_lower_bound" {
  command = plan

  variables {
    retention_in_days = 30
  }

  assert {
    condition     = azurerm_log_analytics_workspace.this.retention_in_days == 30
    error_message = "30 days is the lowest valid retention."
  }
}

run "accepts_retention_upper_bound" {
  command = plan

  variables {
    retention_in_days = 730
  }

  assert {
    condition     = azurerm_log_analytics_workspace.this.retention_in_days == 730
    error_message = "730 days is the highest valid retention."
  }
}

run "output_exposes_workspace_id" {
  command = apply

  assert {
    condition     = output.id == azurerm_log_analytics_workspace.this.id
    error_message = "id must be the workspace's resource ID."
  }
}
