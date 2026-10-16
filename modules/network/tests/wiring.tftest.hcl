mock_provider "azurerm" {
  mock_resource "azurerm_network_security_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/networkSecurityGroups/nsg-test"
    }
  }

  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-tp-test/subnets/snet-test"
    }
  }

  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-tp-test"
    }
  }
}

variables {
  name                = "tp-test"
  resource_group_name = "rg-test"
  location            = "westeurope"
  address_space       = ["10.10.0.0/16", "10.20.0.0/16"]
  subnets = {
    apps = {
      address_prefixes  = ["10.10.0.0/24"]
      service_endpoints = ["Microsoft.Storage"]
    }
    data = {
      address_prefixes = ["10.10.1.0/24"]
    }
  }
}

run "subnets_carry_prefixes_and_service_endpoints" {
  command = plan

  assert {
    condition     = azurerm_subnet.this["apps"].service_endpoints == toset(["Microsoft.Storage"])
    error_message = "Service endpoints must be applied to the subnet."
  }

  assert {
    condition     = length(azurerm_subnet.this["data"].service_endpoints) == 0
    error_message = "Service endpoints must default to none."
  }

  assert {
    condition     = azurerm_subnet.this["data"].address_prefixes == tolist(["10.10.1.0/24"])
    error_message = "Subnet prefixes must come from the subnet definition."
  }
}

run "nsg_names_include_network_and_subnet_key" {
  command = plan

  assert {
    condition     = azurerm_network_security_group.this["data"].name == "nsg-tp-test-data"
    error_message = "NSG names must be nsg-<name>-<subnet key>."
  }
}

run "accepts_several_valid_ranges" {
  command = plan

  assert {
    condition     = length(azurerm_virtual_network.this.address_space) == 2
    error_message = "All address ranges must reach the virtual network."
  }
}

run "rejects_one_bad_range_among_good_ones" {
  command = plan

  variables {
    address_space = ["10.10.0.0/16", "10.10.0.0/33"]
  }

  expect_failures = [var.address_space]
}

run "no_subnets_creates_only_the_network" {
  command = plan

  variables {
    subnets = {}
  }

  assert {
    condition     = length(azurerm_subnet.this) == 0 && length(azurerm_network_security_group.this) == 0
    error_message = "An empty subnets map must create no subnet or NSG."
  }
}

run "associations_connect_each_subnet_to_its_own_nsg" {
  command = apply

  assert {
    condition     = alltrue([for k, a in azurerm_subnet_network_security_group_association.this : a.subnet_id == azurerm_subnet.this[k].id && a.network_security_group_id == azurerm_network_security_group.this[k].id])
    error_message = "Each association must pair the subnet and the NSG with the same key."
  }

  assert {
    condition     = output.subnet_ids == { for k, s in azurerm_subnet.this : k => s.id }
    error_message = "subnet_ids must map each key to its subnet ID."
  }

  assert {
    condition     = output.vnet_id == azurerm_virtual_network.this.id
    error_message = "vnet_id must be the virtual network's ID."
  }
}
