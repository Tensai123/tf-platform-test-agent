# Test patterns

Generic examples; adapt names and attributes to the module under test.

## Validation: reject bad input, accept the edge of good input

```hcl
run "rejects_name_with_uppercase" {
  command = plan

  variables {
    name = "Invalid-Name"
  }

  expect_failures = [var.name]
}

run "accepts_shortest_valid_name" {
  command = plan

  variables {
    name = "abc"
  }

  assert {
    condition     = azurerm_storage_account.this.name == "abc"
    error_message = "A three-character lowercase name is valid and must be accepted."
  }
}
```

`expect_failures` only proves the rule fires; the accepting run proves it is not so
strict that valid input breaks.

## Defaults: what a caller gets without setting anything

```hcl
run "defaults_keep_public_access_off" {
  command = plan

  assert {
    condition     = azurerm_example.this.public_network_access_enabled == false
    error_message = "With default inputs the resource must not be reachable from the internet."
  }
}
```

Only write this when the module's default actually is the safe value. If it is not,
that is a finding, not a test.

## Branches of a switch variable

```hcl
run "dns_zone_group_created_when_zone_given" {
  command = plan

  variables {
    private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/privateDnsZones/privatelink.example.net"
  }

  assert {
    condition     = length(azurerm_private_endpoint.this.private_dns_zone_group) == 1
    error_message = "A DNS zone group must be created when a zone ID is given."
  }
}

run "no_dns_zone_group_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_private_endpoint.this.private_dns_zone_group) == 0
    error_message = "No DNS zone group is expected without a zone ID."
  }
}
```

## Collections: one per item, and the empty case

```hcl
run "one_link_per_account" {
  command = plan

  variables {
    accounts = {
      raw     = "https://raw.example"
      curated = "https://curated.example"
    }
  }

  assert {
    condition     = length(azurerm_example_link.this) == 2
    error_message = "Expected one link for each entry in var.accounts."
  }

  assert {
    condition     = azurerm_example_link.this["raw"].name == "ls-raw"
    error_message = "Link names must be ls-<key>."
  }
}

run "no_links_without_accounts" {
  command = plan

  variables {
    accounts = {}
  }

  assert {
    condition     = length(azurerm_example_link.this) == 0
    error_message = "No links are expected when no accounts are given."
  }
}
```

## Wiring across resources (computed values: use apply)

```hcl
mock_provider "azurerm" {
  mock_resource "azurerm_example_app" {
    defaults = {
      identity = { principal_id = "11111111-1111-1111-1111-111111111111" }
    }
  }
}

run "role_is_granted_to_the_app_identity" {
  command = apply

  assert {
    condition     = azurerm_role_assignment.this.principal_id == azurerm_example_app.this.identity[0].principal_id
    error_message = "The role assignment must target the app's own managed identity."
  }

  assert {
    condition     = azurerm_role_assignment.this.scope == var.target_id
    error_message = "The role must be scoped to the target given by the caller, nothing wider."
  }
}
```

## Outputs

```hcl
run "exposes_identity_principal" {
  command = apply

  assert {
    condition     = output.principal_id == "11111111-1111-1111-1111-111111111111"
    error_message = "output.principal_id must be the managed identity's principal ID."
  }
}
```

## Stacks

A stack test mocks the same providers and sets the stack's required variables (often
from a realistic tfvars). Test what the stack decides: per-environment switches, how
module inputs are derived (names, address ranges, maps built in `locals`), and which
module instances exist for a given input. Do not re-test module internals there.

```hcl
run "prod_disables_public_access" {
  command = plan

  variables {
    environment           = "prod"
    public_access_enabled = false
  }

  assert {
    condition     = module.example.public_access == false
    error_message = "prod must not expose services publicly."
  }
}
```
