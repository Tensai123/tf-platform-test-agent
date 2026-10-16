# Review criteria

Generic checks for Terraform on Azure. For each one: what to look for, and when it
is serious.

## Code that runs during plan, test or apply

- `data "external"`, `provisioner "local-exec"`/`"remote-exec"`, `data "http"`,
  `templatefile`/`file` on paths outside the module, providers from non-registry
  sources.
- Why it matters: anything that runs during `plan` or `terraform test` runs in CI on
  every pull request, with whatever the CI job can reach, and a pull request can
  change the program it runs. It also makes plans depend on the machine that runs
  them.
- Severity: high when the program or its path can be changed by a contributor and
  runs in pipelines; medium otherwise. Recommend passing the value in as a variable
  from the pipeline instead.

## Identity and access (RBAC)

- Role assignments: is the role the narrowest one that works (`Reader`/`...Data
  Reader`/`...Data Contributor` vs `Owner`/`...Data Owner`/`Contributor`)? Is the
  scope the narrowest (a container, a vault, a resource) rather than a resource
  group or subscription?
- Who gets the role: the resource's own managed identity, or a caller-supplied
  principal without validation?
- Severity: high for owner-level or access-administration roles where a reader or
  contributor role would do; medium for scope wider than needed.

## Network exposure and defaults

- `public_network_access_enabled`, `public_network_enabled`, `default_action`,
  firewall rules, `allow_nested_items_to_be_public`, private endpoints and their
  DNS zones.
- Module defaults matter more than stack values: every new caller gets the default.
  A module that is public unless told otherwise is a finding even if today's stack
  overrides it.
- Private endpoints without a private DNS zone group: callers resolving the public
  name will not reach the private endpoint.
- Severity: high when production is exposed; medium for unsafe module defaults.

## Transport and protocols

- Every way in to a service, not only the main endpoint: TLS minimums, HTTPS-only
  flags, deployment and management channels (FTP, SCM, remote debugging, local
  users, shared keys) and whether any of them still allow plaintext or credential
  based access when the service is otherwise identity-based.
- Severity: medium when plaintext or credential-based access is allowed.

## Data protection and reliability

- Soft delete and retention, purge protection, `prevent_destroy` on stateful
  resources (storage, key vaults, databases, workspaces), replication type,
  backups.
- Changes that force replacement of stateful resources (renames, immutable
  attributes): data loss risk in the plan.
- Severity: high for changes that would destroy data; low/medium for missing
  hardening.

## Correctness and consistency

- Documentation vs configuration: what the README, variable descriptions and stated
  conventions promise, against what the code and its per-environment inputs actually
  contain.
- Variable validation: inputs with a constrained format (names, CIDRs, enums, SKUs)
  without `validation`, or validation that does not match the description.
- Outputs that index lists or blocks that may be empty.
- `count` where the repository convention says `for_each`.
- Provider version ranges and missing `.terraform.lock.hcl` (non-reproducible
  provider versions between runs).
- Severity: usually low/medium; high if it breaks an environment.

## Observability

- Diagnostic settings: present for services that produce logs that matter, sent to
  the shared workspace; retention appropriate.
- Severity: low.
