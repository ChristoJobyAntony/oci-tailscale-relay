locals {
  selected_image_ocid = var.image_ocid != null ? var.image_ocid : data.oci_core_images.ubuntu[0].images[0].id

  common_tags = {
    Project = "oci-tailscale-relay"
    Managed = "terraform"
  }
}

resource "terraform_data" "relay_launch_triggers" {
  triggers_replace = {
    image_ocid              = local.selected_image_ocid
    shape                   = var.shape
    shape_is_flex           = var.shape_is_flex
    flex_ocpus              = var.flex_ocpus
    flex_memory_gbs         = var.flex_memory_gbs
    boot_volume_size_in_gbs = var.flex_boot_volume
  }
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu" {
  count                    = var.image_ocid == null ? 1 : 0
  compartment_id           = var.tenancy_ocid
  operating_system         = var.image_operating_system
  operating_system_version = var.image_operating_system_version
  shape                    = var.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"
}

resource "oci_identity_compartment" "tf-compartment" {
  # Required
  compartment_id = var.tenancy_ocid
  description    = "Compartment for Terraform resources."
  name           = "terraform_compartment"
}

resource "oci_core_vcn" "main" {
  compartment_id = oci_identity_compartment.tf-compartment.id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.instance_name}-vcn"
  dns_label      = "tsrelayvcn"
  freeform_tags  = local.common_tags
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = oci_identity_compartment.tf-compartment.id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.instance_name}-igw"
  enabled        = true
  freeform_tags  = local.common_tags
}

resource "oci_core_route_table" "public" {
  compartment_id = oci_identity_compartment.tf-compartment.id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.instance_name}-public-rt"
  freeform_tags  = local.common_tags

  route_rules {
    description       = "Internet access for public subnet"
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_security_list" "subnet" {
  compartment_id = oci_identity_compartment.tf-compartment.id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.instance_name}-subnet-sl"
  freeform_tags  = local.common_tags

  egress_security_rules {
    description      = "Allow all outbound traffic"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = oci_identity_compartment.tf-compartment.id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.public_subnet_cidr
  display_name               = "${var.instance_name}-public-subnet"
  dns_label                  = "publicsub"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.subnet.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = local.common_tags
}

resource "oci_core_network_security_group" "relay" {
  compartment_id = oci_identity_compartment.tf-compartment.id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.instance_name}-nsg"
  freeform_tags  = local.common_tags
}

resource "oci_core_network_security_group_security_rule" "ingress_ssh" {
  network_security_group_id = oci_core_network_security_group.relay.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.admin_cidr
  source_type               = "CIDR_BLOCK"
  description               = "SSH bootstrap access"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "ingress_peer_relay_udp" {
  network_security_group_id = oci_core_network_security_group.relay.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = var.relay_source_cidr
  source_type               = "CIDR_BLOCK"
  description               = "Tailscale Peer Relay UDP port"

  udp_options {
    destination_port_range {
      min = var.relay_udp_port
      max = var.relay_udp_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "egress_all" {
  network_security_group_id = oci_core_network_security_group.relay.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow all outbound traffic"
}

resource "oci_core_instance" "relay" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = oci_identity_compartment.tf-compartment.id
  display_name        = var.instance_name
  shape               = var.shape
  freeform_tags       = merge(local.common_tags, { Role = "tailscale-relay" })

  # When the Always Free guardrails are enabled, let the quota policy settle
  # before the launch is checked against it.
  depends_on = [oci_limits_quota.free_tier]

  lifecycle {
    replace_triggered_by = [terraform_data.relay_launch_triggers]
  }

  dynamic "shape_config" {
    for_each = var.shape_is_flex ? [1] : []
    content {
      ocpus         = var.flex_ocpus
      memory_in_gbs = var.flex_memory_gbs
    }
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    hostname_label   = var.hostname_label
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.relay.id]
  }

  source_details {
    source_type             = "image"
    source_id               = local.selected_image_ocid
    boot_volume_size_in_gbs = var.flex_boot_volume
  }

  metadata = {
    ssh_authorized_keys = file(pathexpand(var.ssh_public_key_path))
  }
}

resource "oci_budget_budget" "monthly_cost_guardrail" {
  compartment_id = var.tenancy_ocid
  amount         = 1
  reset_period   = "MONTHLY"
  display_name   = "${var.instance_name}-monthly-budget"
  description    = "Monthly budget guardrail for relay infrastructure"
  target_type    = "COMPARTMENT"
  targets        = [oci_identity_compartment.tf-compartment.id]
  freeform_tags  = local.common_tags
}

resource "oci_budget_alert_rule" "monthly_cost_guardrail_alert" {
  budget_id      = oci_budget_budget.monthly_cost_guardrail.id
  display_name   = "${var.instance_name}-budget-alert-100"
  description    = "Alert when monthly spend reaches 100% of budget"
  type           = "ACTUAL"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = var.budget_alert_recipients
  message        = "Monthly OCI budget of $1 has been reached for ${var.instance_name}."
}
