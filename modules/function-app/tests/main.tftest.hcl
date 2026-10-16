mock_provider "azurerm" {
  mock_resource "azurerm_service_plan" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Web/serverFarms/asp-func-test"
    }
  }

  mock_resource "azurerm_linux_function_app" {
    defaults = {
      identity = { principal_id = "11111111-1111-1111-1111-111111111111" }
    }
  }
}

mock_provider "external" {}

override_data {
  target = data.external.build_info
  values = {
    result = { revision = "abc1234" }
  }
}

variables {
  name                 = "func-test"
  resource_group_name  = "rg-test"
  location             = "westeurope"
  storage_account_name = "sttest"
  storage_account_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/sttest"
}

run "app_is_https_only_with_tls_12" {
  command = plan

  assert {
    condition     = azurerm_linux_function_app.this.https_only == true
    error_message = "The function app must accept HTTPS only."
  }

  assert {
    condition     = azurerm_linux_function_app.this.site_config[0].minimum_tls_version == "1.2"
    error_message = "The function app must require TLS 1.2."
  }
}

run "runtime_storage_uses_managed_identity" {
  command = plan

  assert {
    condition     = azurerm_linux_function_app.this.storage_uses_managed_identity == true
    error_message = "The runtime storage must be accessed with the managed identity, not a key."
  }

  assert {
    condition     = azurerm_linux_function_app.this.identity[0].type == "SystemAssigned"
    error_message = "The app must have a system-assigned identity."
  }
}

run "plan_and_python_defaults" {
  command = plan

  assert {
    condition     = azurerm_service_plan.this.name == "asp-func-test" && azurerm_service_plan.this.os_type == "Linux"
    error_message = "The plan must be a Linux plan named asp-<name>."
  }

  assert {
    condition     = azurerm_linux_function_app.this.site_config[0].application_stack[0].python_version == "3.12"
    error_message = "Default Python version must be 3.12."
  }
}

run "app_settings_are_merged_with_build_revision" {
  command = plan

  variables {
    app_settings = { MODE = "batch" }
  }

  assert {
    condition     = azurerm_linux_function_app.this.app_settings["MODE"] == "batch"
    error_message = "Caller app settings must be kept."
  }

  assert {
    condition     = azurerm_linux_function_app.this.app_settings["BUILD_REVISION"] == "abc1234"
    error_message = "BUILD_REVISION must come from the build info."
  }
}

run "role_assignment_targets_storage_and_app_identity" {
  command = apply

  assert {
    condition     = azurerm_role_assignment.runtime_storage.scope == var.storage_account_id
    error_message = "The role must be assigned on the runtime storage account."
  }

  assert {
    condition     = azurerm_role_assignment.runtime_storage.principal_id == "11111111-1111-1111-1111-111111111111"
    error_message = "The role must go to the function app's identity."
  }

  assert {
    condition     = output.principal_id == "11111111-1111-1111-1111-111111111111"
    error_message = "principal_id output must be the app's identity."
  }
}
