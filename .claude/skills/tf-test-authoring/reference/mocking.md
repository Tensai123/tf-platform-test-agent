# How mocked providers behave here

Each point below was observed by running `terraform test` (Terraform 1.16, azurerm
4.x) in this repository's sandbox. When something surprises you, check it with a
small run and trust the run over this file.

## Mock every provider the module requires

```hcl
mock_provider "azurerm" {}
```

A mocked provider still knows the provider schema. Two consequences:

- **Enum and format validation still runs.** `min_tls_version = "TLS9"` fails with
  `expected min_tls_version to be one of [...]`. You cannot use made-up values for
  validated attributes, in variables or in mock defaults.
- **Unset computed attributes get random values** (`"7pvhnybf"`), consistent within
  one run only.

## `command = plan` vs `command = apply`

With mocks, `apply` creates nothing real; it only makes computed values known.

- Use `plan` for attributes the module sets from inputs or literals.
- Use `apply` when the condition reads a computed value: `id`, `principal_id`,
  `identity[0].principal_id`, endpoints, any `output` built from those. Under `plan`
  such conditions error with `Unknown condition value`.

## Mocked IDs are not valid Azure IDs

Under `apply`, the provider parses IDs that one resource passes to another (for
example `service_plan_id`). A random mocked ID then fails with
`parsing "7pvhnybf": ... the number of segments didn't match`. Give the referenced
resource a well-formed ID:

```hcl
mock_provider "azurerm" {
  mock_resource "azurerm_service_plan" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Web/serverFarms/asp-test"
    }
  }
}
```

Variables that the provider parses as IDs (subnet IDs, resource IDs used as
`private_connection_resource_id`, and so on) need the same shape.

## Nested blocks in mock defaults are objects, not lists

```hcl
mock_resource "azurerm_linux_function_app" {
  defaults = {
    identity = { principal_id = "11111111-1111-1111-1111-111111111111" }  # not [ { ... } ]
  }
}
```

Fixed values like this make assertions across resources exact (the role assignment
uses this principal ID).

## `data "external"` runs a program unless you stop it

A module with `data "external"` executes its `program` during `terraform test`. The
sandbox contains it, but a test must not depend on it, and `mock_provider "external"`
alone is not enough: the mocked `result` is an empty map, so the module's
`result.<key>` lookup fails with `Missing map element`. Override the data source
with the keys the module reads:

```hcl
mock_provider "external" {}

override_data {
  target = data.external.example
  values = {
    result = { version = "1.2.3" }
  }
}
```

Inside a stack test the target is the module path:
`target = module.app.data.external.example`.

The same applies to any data source that reaches outside Terraform (`http`, `local`
file reads): override it.

## Runs share state, in order

Runs in one file execute in order against shared state. If a run errors, later runs
in the file that depend on its state are skipped. Keep independent concerns
independent: separate files, or runs that do not need earlier applies.

## Variables

File-level `variables {}` apply to every run; a `variables {}` block inside a run
overrides them for that run only. Prefer one complete, valid file-level set and
small overrides per run.
