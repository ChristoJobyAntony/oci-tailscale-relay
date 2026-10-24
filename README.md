# OCI + Terraform + Ansible + Tailscale relay scaffold

This scaffold does three things, once per deployment (currently Sydney and Hyderabad, in two OCI tenancies):

1. Terraform creates a small OCI network and one Compute instance.
2. Terraform outputs an Ansible inventory stanza for that node.
3. Ansible installs Tailscale and configures the node as either:
   - a Tailscale Peer Relay (`tailscale set --relay-server-port=...`), or
   - an Exit Node (`tailscale set --advertise-exit-node`), or
   - both Peer Relay and Exit Node at the same time, or
   - a plain Tailscale server.

## Important relay note

In current Tailscale docs, a "relay" can mean different things:

- **DERP relay**: advanced, custom DERP servers; usually not needed.
- **Peer Relay**: a normal tailnet device that other devices can use as a faster relay when direct connectivity is impossible.
- **Exit Node**: routes general internet traffic through the node.

This project targets **Peer Relay** by default, because it is the closest match to "set up a relay server" for most self-managed deployments.

The compute instance is configured for OCI's ARM free-tier shape by default: `VM.Standard.A1.Flex` with up to 4 OCPUs and 24 GB RAM.

## Deployments

Each node is one Terraform workspace with its own variable file and local state, and one Ansible inventory group under the parent group `relays`.

| Node | OCI tenancy / region | Terraform workspace | Variable file | Ansible group | Tailscale tags |
|---|---|---|---|---|---|
| `oci-ts-relay-01` | Australian account, `ap-sydney-1` | `default` | `terraform/terraform.tfvars` | `sydney` | `tag:exitnodes`, `tag:prod` |
| `oci-ts-relay-02` | Indian account, `ap-hyderabad-1` | `india` | `terraform/india.tfvars` | `india` | `tag:exitnodes` |

Sydney is 4 OCPU / 24 GB / 200 GB; Hyderabad is 2 OCPU / 12 GB / 100 GB, the Always Free size since June 2026 (see below). Only Sydney runs the Jellyfin cache proxy, deployed from the sibling `jellyfin-cache-proxy` repo.

Select the workspace with the `TF_WORKSPACE` environment variable rather than `terraform workspace select`, so the directory's saved selection stays on `default` (Sydney) and a bare `terraform apply` can never land in the wrong tenancy:

```bash
TF_WORKSPACE=india terraform -chdir=terraform plan -var-file=india.tfvars
```

Terraform auto-loads `terraform.tfvars` (Sydney) before any `-var-file`, so `india.tfvars` explicitly sets the Sydney credential variables to `null` and authenticates through the `[india]` profile in `~/.oci/config` (`config_file_profile`). Workspace state lives in `terraform/terraform.tfstate.d/<workspace>/` and is ignored by git like the default state.

## Staying inside Always Free

Both tenancies are Pay As You Go, so nothing stops a resource above the free allowance from billing except discipline and the guardrails below. Oracle's Always Free allowances (home region only) as of October 2026:

| Resource | Always Free allowance |
|---|---|
| Ampere A1 (`VM.Standard.A1.Flex`) | 1,500 OCPU-hours + 9,000 GB-hours a month = 2 OCPUs + 12 GB always on. Was 4 + 24 until 15 June 2026; tenancies that already ran 4/24 (Sydney) still show $0 for it, but a new instance may be held to 2/12. |
| AMD micro (`VM.Standard.E2.1.Micro`) | 2 instances |
| Boot + block volumes | 200 GB combined, 5 backups |
| Object Storage (paid account) | 10 GB each of Standard, Infrequent Access, Archive |
| Outbound data transfer | 10 TB a month |
| Load balancer | 1 flexible 10 Mbps, 1 network LB |
| Budgets, VCNs, Bastion, Notifications (1,000 emails) | free |

Oracle may also reclaim an Always Free compute instance that stays idle for 7 days (95th-percentile CPU, network and, for A1, memory all under 20%).

`enable_free_tier_guardrails = true` in a deployment's variable file (set for India) makes `terraform/guardrails.tf` create two tenancy-wide resources: a quota policy that caps A1 at the free OCPU/memory numbers, zeroes every other compute shape, caps boot+block storage at 200 GB and Object Storage at 10 GB, and zeroes the Database and Load Balancer families; and a $1/month budget on the whole tenancy with actual and forecast alerts to `budget_alert_recipients`. Quotas only gate new resources, so the policy can be applied with everything running. Check real spend any time with the Usage API:

```bash
oci usage-api usage-summary request-summarized-usages --profile india \
  --tenant-id <tenancy-ocid> --granularity MONTHLY --query-type COST \
  --time-usage-started 2026-10-01T00:00:00Z --time-usage-ended 2026-11-01T00:00:00Z \
  --group-by '["service","skuName"]'
```

## Prerequisites

- Terraform 1.5+
- Ansible on your workstation
- OCI API credentials configured in `terraform.tfvars`, environment variables, or an OCI config profile
- An SSH keypair on your workstation
- A Tailscale auth key for server provisioning

## 1) Configure Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # first deployment
cp india.tfvars.example india.tfvars           # second deployment, another tenancy
# edit the copies
```

Minimal values to set:

- `tenancy_ocid`
- `region`
- `config_file_profile` (a profile in `~/.oci/config`) or the explicit `user_ocid`, `fingerprint` and `private_key_path`
- `ansible_inventory_group` (`sydney`, `india`, ...), the header of the inventory stanza Terraform prints
- `image_ocid` can stay `null` to select the newest matching Ubuntu 24.04 image automatically, but pin it once the node exists: the launch triggers include the image, so a `null` value replaces the instance whenever Canonical publishes a newer image
- `ssh_public_key_path` (full path or `~` path are both fine)
- `admin_cidr`

The playbook uses generic package installation, so Ubuntu and Oracle Linux both work with the Tailscale install script. The default Terraform config uses an Ubuntu ARM image, so `ansible_ssh_user` is set to `ubuntu`. If you change `image_ocid` to an Oracle Linux ARM image, update `ansible_ssh_user` to `opc`. Also note that OCI `hostname_label` must be letters and numbers only; hyphens are not allowed there.

## 2) Provision OCI

```bash
terraform init
terraform apply                                            # Sydney (default workspace)
TF_WORKSPACE=india terraform apply -var-file=india.tfvars  # Hyderabad
```

A named workspace is created once with `terraform workspace new india && terraform workspace select default`.

## 3) Render the Ansible inventory from Terraform outputs

From the repository root:

```bash
terraform -chdir=terraform output -raw ansible_inventory                     # [sydney] stanza
TF_WORKSPACE=india terraform -chdir=terraform output -raw ansible_inventory  # [india] stanza
```

Paste each stanza into `ansible/inventory.ini` under the `[relays:children]` header. Both playbooks target `relays`, and a host's inventory name becomes its Tailscale hostname. `ansible/inventory.ini` is intentionally ignored because it contains deployment-specific host details. `ansible/inventory.ini.example` shows the expected format.

You can also inspect the public IP directly:

```bash
terraform -chdir=terraform output -raw instance_public_ip
```

## 4) Configure Ansible secrets

```bash
cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
# edit ansible/group_vars/all.yml
```

At minimum, set:

- `tailscale_auth_key` (a fresh, tagged, pre-authorised key each time a node joins; keys expire after at most 90 days)
- `relay_udp_port`

Per-node settings (`tailscale_mode`, `tailscale_tags`) live in `ansible/group_vars/<group>.yml` (`sydney.yml`, `india.yml`). Those files hold no secrets and are committed.

## 5) Run Ansible

```bash
ansible-playbook -i ansible/inventory.ini --private-key ~/.ssh/id_ed25519 ansible/site.yml --limit india
```

Without `--limit` the play runs against every node in `relays`.

## 6) Finish Tailscale-side approval

### If using Peer Relay

- Ensure your tailnet policy includes a `tailscale.com/cap/relay` grant for the devices that should use this relay.
- Ensure OCI allows inbound UDP to `relay_udp_port` from the source CIDRs you expect.
- Test with:

```bash
tailscale status | grep peer-relay
```

### If using Exit Node

- After Ansible runs, go to the Tailscale admin console and approve the node as an exit node.
- Ensure your tailnet policy grants clients access to `autogroup:internet`.

## Workloads on the nodes

The Sydney node also hosts the public NeoAuth deployment. Its infrastructure (Cloudflare Tunnel Terraform and node-preparation Ansible) lives in the sibling `neoauth-infra` repo; this repo's only involvement is advertising the node tags (`tailscale_tags` in `ansible/group_vars/all.yml`, including the `tag:prod` deploy-target tag that NeoAuth's CI targets).

### Jellyfin caching reverse proxy

The Sydney node also runs a Jellyfin caching reverse proxy and cache warmer. That lives in the sibling `jellyfin-cache-proxy` repo; this repo's only involvement is the `tag:prod` tag its tailnet grant to the Jellyfin host (`tag:media`, `tcp:8096`) keys on, and the node's 200 GB disk, of which the cache may use up to 130 GB.

The inventory may point at the node's tailnet IP instead of the public IP; with Tailscale SSH enabled that avoids depending on `admin_cidr`.

## Security recommendations

- Keep `admin_cidr` as narrow as possible instead of `0.0.0.0/0`.
- Use a tagged Tailscale auth key for servers.
- Store `ansible/group_vars/all.yml` in Ansible Vault or another secrets manager.
- Restrict `relay_source_cidr` if your client networks have stable public egress IPs.

## Custom DERP note

If you truly mean a **custom DERP server**, this scaffold is not that. In Tailscale's own docs, custom DERP is an advanced path that requires building and operating the `derper` binary and, in most cases, Tailscale recommends using Peer Relays instead.
