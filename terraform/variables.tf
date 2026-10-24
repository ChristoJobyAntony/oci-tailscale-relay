variable "tenancy_ocid" {
  description = "OCI tenancy OCID (root compartment OCID). Used to query availability domains."
  type        = string

  validation {
    condition     = startswith(var.tenancy_ocid, "ocid1.tenancy.")
    error_message = "tenancy_ocid must be an OCI tenancy OCID starting with ocid1.tenancy."
  }
}

variable "user_ocid" {
  description = "OCI user OCID for API authentication. Leave null to use an OCI config profile or environment variables."
  type        = string
  default     = null

  validation {
    condition     = var.user_ocid == null ? true : startswith(var.user_ocid, "ocid1.user.")
    error_message = "user_ocid must be null or an OCI user OCID starting with ocid1.user."
  }
}

variable "private_key_path" {
  description = "Path to OCI API private key file. Leave null to use an OCI config profile or environment variables."
  type        = string
  default     = null
}

variable "fingerprint" {
  description = "Fingerprint for OCI API key pair. Leave null to use an OCI config profile or environment variables."
  type        = string
  default     = null
}

variable "region" {
  description = "OCI region identifier, for example ap-sydney-1. Leave null to use an OCI config profile or environment variables."
  type        = string
  default     = null

  validation {
    condition     = var.region == null ? true : can(regex("^[a-z]+-[a-z]+-[0-9]+$", var.region))
    error_message = "region must be null or an OCI region identifier such as ap-sydney-1."
  }
}

variable "image_ocid" {
  description = "Optional platform image OCID for the instance. When null, Terraform selects the newest matching Ubuntu image for the chosen shape."
  type        = string
  default     = null

  validation {
    condition     = var.image_ocid == null ? true : startswith(var.image_ocid, "ocid1.image.")
    error_message = "image_ocid must be null or an OCI image OCID starting with ocid1.image."
  }
}

variable "image_operating_system" {
  description = "Operating system name used when image_ocid is null."
  type        = string
  default     = "Canonical Ubuntu"
}

variable "image_operating_system_version" {
  description = "Operating system version used when image_ocid is null."
  type        = string
  default     = "24.04"
}

variable "instance_name" {
  description = "Display name for the instance."
  type        = string
  default     = "oci-ts-relay-01"
}

variable "hostname_label" {
  description = "OCI hostname label for the primary VNIC. Must start with a letter and contain only letters and numbers."
  type        = string
  default     = "ocitsrelay01"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9]{0,62}$", var.hostname_label))
    error_message = "hostname_label must start with a letter and contain only letters and numbers."
  }
}

variable "shape" {
  description = "OCI compute shape. Example: VM.Standard.E5.Flex or VM.Standard.A1.Flex."
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "shape_is_flex" {
  description = "Set true for Flex shapes such as VM.Standard.E5.Flex or VM.Standard.A1.Flex."
  type        = bool
  default     = true
}

variable "flex_ocpus" {
  description = "OCPU count for Flex shapes."
  type        = number
  default     = 4

  validation {
    condition     = var.flex_ocpus > 0
    error_message = "flex_ocpus must be greater than 0."
  }
}

variable "flex_memory_gbs" {
  description = "Memory in GB for Flex shapes."
  type        = number
  default     = 24

  validation {
    condition     = var.flex_memory_gbs > 0
    error_message = "flex_memory_gbs must be greater than 0."
  }
}

variable "flex_boot_volume" {
  description = "Boot volume size in GB."
  type        = number
  default     = 200

  validation {
    condition     = var.flex_boot_volume >= 50
    error_message = "flex_boot_volume must be at least 50 GB."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key that OCI injects into the instance metadata."
  type        = string
}

variable "ansible_ssh_user" {
  description = "Default SSH user for Ansible. Ubuntu images typically use ubuntu; Oracle Linux typically uses opc."
  type        = string
  default     = "ubuntu"
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH to the instance during bootstrap. Lock this down to your own public IP or office CIDR."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr must be a valid CIDR block, for example 203.0.113.10/32."
  }
}

variable "relay_source_cidr" {
  description = "CIDR allowed to reach the peer relay UDP port. Use 0.0.0.0/0 if your Tailscale clients can come from anywhere, or narrow it if you know the source egress ranges."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.relay_source_cidr, 0))
    error_message = "relay_source_cidr must be a valid CIDR block."
  }
}

variable "relay_udp_port" {
  description = "UDP port that the Tailscale Peer Relay feature listens on."
  type        = number
  default     = 40000

  validation {
    condition     = var.relay_udp_port >= 1 && var.relay_udp_port <= 65535
    error_message = "relay_udp_port must be between 1 and 65535."
  }
}

variable "vcn_cidr" {
  description = "VCN CIDR block."
  type        = string
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrhost(var.vcn_cidr, 0))
    error_message = "vcn_cidr must be a valid CIDR block."
  }
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR block."
  type        = string
  default     = "10.42.10.0/24"

  validation {
    condition     = can(cidrhost(var.public_subnet_cidr, 0))
    error_message = "public_subnet_cidr must be a valid CIDR block."
  }
}

variable "budget_alert_recipients" {
  description = "Comma-separated email addresses for budget alert notifications."
  type        = string
  default     = null
}

variable "config_file_profile" {
  description = "Optional profile name in ~/.oci/config to authenticate with. When set, user_ocid, fingerprint, private_key_path and region can stay null and are read from that profile."
  type        = string
  default     = null
}

variable "ansible_inventory_group" {
  description = "Inventory group name written by the ansible_inventory output. Give each deployment (Terraform workspace) its own group so ansible/inventory.ini can hold several relays under the parent group `relays`."
  type        = string
  default     = "oci_relay"

  validation {
    condition     = can(regex("^[A-Za-z_][A-Za-z0-9_]*$", var.ansible_inventory_group))
    error_message = "ansible_inventory_group must be a valid Ansible group name (letters, digits, underscores)."
  }
}

# --- Always Free guardrails (guardrails.tf) -----------------------------------

variable "enable_free_tier_guardrails" {
  description = "Create a tenancy-wide quota policy and budget that pin the account to OCI's Always Free allowances. Use on accounts that must never be billed."
  type        = bool
  default     = false
}

variable "free_tier_a1_ocpus" {
  description = "Quota cap for VM.Standard.A1.Flex OCPUs across the tenancy. Oracle's Always Free allowance is 1,500 OCPU-hours a month, i.e. 2 OCPUs always on (it was 4 before June 2026)."
  type        = number
  default     = 2
}

variable "free_tier_a1_memory_gbs" {
  description = "Quota cap for VM.Standard.A1.Flex memory in GB across the tenancy. Always Free is 9,000 GB-hours a month, i.e. 12 GB always on (24 before June 2026)."
  type        = number
  default     = 12
}

variable "free_tier_micro_instances" {
  description = "Quota cap for VM.Standard.E2.1.Micro instances (and their OCPUs). Always Free allows 2."
  type        = number
  default     = 2
}

variable "free_tier_block_storage_gb" {
  description = "Quota cap for boot plus block volume storage in GB per availability domain. Always Free is 200 GB combined."
  type        = number
  default     = 200
}

variable "free_tier_object_storage_gb" {
  description = "Quota cap for Object Storage in GB. Always Free on a paid account is 10 GB Standard plus 10 GB Infrequent Access plus 10 GB Archive; 10 keeps any single tier inside its allowance."
  type        = number
  default     = 10
}

variable "free_tier_extra_quota_statements" {
  description = "Additional quota statements appended to the Always Free policy, for example zeroing further service families."
  type        = list(string)
  default     = []
}

variable "tenancy_budget_amount" {
  description = "Monthly amount in the tenancy's currency for the whole-tenancy budget created by the guardrails."
  type        = number
  default     = 1
}
