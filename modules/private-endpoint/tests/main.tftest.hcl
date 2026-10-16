mock_provider "azurerm" {}

variables {
  name                = "tp-test-blob"
  resource_group_name = "rg-test"
  location            = "westeurope"
  subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-endpoints"
  target_resource_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/sttest"
  subresource_name    = "blob"
}

run "names_and_connection_follow_inputs" {
  command = plan

  assert {
    condition     = azurerm_private_endpoint.this.name == "pe-tp-test-blob"
    error_message = "Endpoint name must be pe-<name>."
  }

  assert {
    condition     = azurerm_private_endpoint.this.private_service_connection[0].name == "psc-tp-test-blob"
    error_message = "Connection name must be psc-<name>."
  }

  assert {
    condition     = azurerm_private_endpoint.this.private_service_connection[0].subresource_names == tolist(["blob"])
    error_message = "The connection must target exactly the requested sub-resource."
  }

  assert {
    condition     = azurerm_private_endpoint.this.private_service_connection[0].is_manual_connection == false
    error_message = "The connection must not require manual approval."
  }
}

run "no_dns_zone_group_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_private_endpoint.this.private_dns_zone_group) == 0
    error_message = "Without a DNS zone ID no zone group may be created."
  }
}

run "dns_zone_group_when_zone_given" {
  command = plan

  variables {
    private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
  }

  assert {
    condition     = length(azurerm_private_endpoint.this.private_dns_zone_group) == 1
    error_message = "A DNS zone ID must create one zone group."
  }

  assert {
    condition     = one(azurerm_private_endpoint.this.private_dns_zone_group).private_dns_zone_ids == tolist([var.private_dns_zone_id])
    error_message = "The zone group must reference the given zone."
  }
}
