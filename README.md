# OCI + Terraform + Ansible + Tailscale relay scaffold

This scaffold does three things:

1. Terraform creates a small OCI network and one Compute instance.
2. Terraform outputs a one-host Ansible inventory.
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

## Prerequisites

- Terraform 1.5+
- Ansible on your workstation
- OCI API credentials configured in `terraform.tfvars`, environment variables, or an OCI config profile
- An SSH keypair on your workstation
- A Tailscale auth key for server provisioning

## 1) Configure Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
```

Minimal values to set:

- `tenancy_ocid`
- `region`
- `image_ocid` can stay `null` to select the newest matching Ubuntu 24.04 image automatically; set it only if you need a specific image OCID
- `ssh_public_key_path` (full path or `~` path are both fine)
- `admin_cidr`

The playbook uses generic package installation, so Ubuntu and Oracle Linux both work with the Tailscale install script. The default Terraform config uses an Ubuntu ARM image, so `ansible_ssh_user` is set to `ubuntu`. If you change `image_ocid` to an Oracle Linux ARM image, update `ansible_ssh_user` to `opc`. Also note that OCI `hostname_label` must be letters and numbers only; hyphens are not allowed there.

## 2) Provision OCI

```bash
terraform init
terraform apply
```

## 3) Render the Ansible inventory from Terraform outputs

From the repository root:

```bash
terraform -chdir=terraform output -raw ansible_inventory > ansible/inventory.ini
```

`ansible/inventory.ini` is intentionally ignored because it contains deployment-specific host details. `ansible/inventory.ini.example` shows the expected format.

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

- `tailscale_auth_key`
- `tailscale_mode`
- `tailscale_tags`
- `relay_udp_port`

## 5) Run Ansible

```bash
ansible-playbook -i ansible/inventory.ini --private-key ~/.ssh/id_ed25519 ansible/site.yml
```

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

## Workloads on this node

The node also hosts the public NeoAuth deployment. Its infrastructure (Cloudflare Tunnel Terraform and node-preparation Ansible) lives in the sibling `neoauth-infra` repo; this repo's only involvement is advertising the node tags (`tailscale_tags` in `ansible/group_vars/all.yml`, including the `tag:prod` deploy-target tag that NeoAuth's CI targets).

### Jellyfin caching reverse proxy

`ansible/jellyfin-cache-proxy.yml` installs nginx on the node as a caching reverse proxy in front of the home Jellyfin server. It listens on the node's tailnet IPv4 on port 8096 (never on the public interface) and caches direct-play media streams (`Static=true`) in 8 MB slices, plus artwork, so devices near the node stream from local disk instead of across the ~400 ms path to the home server. Transcoded HLS sessions, the API and the websocket pass straight through uncached.

Requirements:

- A tailnet grant that lets this node (`tag:prod`) reach the Jellyfin host (`tag:media`) on `tcp:8096`.
- `jellyfin_upstream_host` in `ansible/group_vars/all.yml` set to the tailnet IP of the Jellyfin host (see the example file for all tunables).

```bash
ansible-playbook -i ansible/inventory.ini ansible/jellyfin-cache-proxy.yml
```

Cache entries are keyed on the item and media source only, not on the client's `Tag` parameter, so the Jellyfin web app, Kodi and the mobile apps all share one copy and one pre-warmed file is a hit for every client. Freshness comes from revalidation: once a slice is older than `jellyfin_cache_valid` (24h), the next request for it makes nginx ask the home server whether the file changed since its `Last-Modified`; Jellyfin answers 304 in one round trip (about 0.2 s) and the slice is served and trusted for another day. Do not enable `proxy_cache_background_update` on the media location: combined with the slice module it re-downloads the whole file per slice.

Point clients at `http://oci-ts-relay-01:8096/`. Each cached response carries an `X-Cache-Status` header, and `/var/log/nginx/jellyfin-cache.access.log` on the node records HIT/MISS per request. Cached slices are served without re-checking the Jellyfin token, so keep the ACL for this port scoped to your own devices.

A companion cache warmer runs from a systemd timer on the node every 30 minutes. It asks Jellyfin what the users listed in `jellyfin_warm_users` are likely to watch next, in priority order: Continue Watching, anything in a collection named `Pre-cache`, Next Up, then titles added in the last 14 days and requests those files through the proxy in slice-aligned ranges, so nginx pulls them from the home server ahead of playback. Fills are paced to `jellyfin_warm_rate_mbit`, capped at `jellyfin_warm_budget`, and recent additions are only fetched inside the `jellyfin_warm_window` local-time window. It needs `jellyfin_api_key` in `ansible/group_vars/all.yml` (Jellyfin Dashboard, API Keys). Progress is in `journalctl -u jellyfin-cache-warmer`. To see what it would fetch without touching the cache, run it on the node with `--dry-run` under the same environment file: `sudo bash -c 'set -a; . /etc/jellyfin-cache-warmer.env; runuser -u www-data -- python3 /usr/local/bin/jellyfin-cache-warmer.py --dry-run'`. Collection members are expanded explicitly (a Season or Series becomes its episodes), because Jellyfin's own recursive query on a collection does not descend into Seasons.

The inventory may point at the node's tailnet IP instead of the public IP; with Tailscale SSH enabled that avoids depending on `admin_cidr`.

## Security recommendations

- Keep `admin_cidr` as narrow as possible instead of `0.0.0.0/0`.
- Use a tagged Tailscale auth key for servers.
- Store `ansible/group_vars/all.yml` in Ansible Vault or another secrets manager.
- Restrict `relay_source_cidr` if your client networks have stable public egress IPs.

## Custom DERP note

If you truly mean a **custom DERP server**, this scaffold is not that. In Tailscale's own docs, custom DERP is an advanced path that requires building and operating the `derper` binary and, in most cases, Tailscale recommends using Peer Relays instead.
