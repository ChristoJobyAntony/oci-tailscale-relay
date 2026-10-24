terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.0"
    }
  }
}

# Two ways to authenticate:
#   1. Explicit credentials in the *.tfvars file (user_ocid, fingerprint,
#      private_key_path, region), as the Sydney deployment does.
#   2. A named profile in ~/.oci/config via config_file_profile, as the India
#      deployment does. Explicit values, when set, still override the profile.
provider "oci" {
  tenancy_ocid        = var.tenancy_ocid
  user_ocid           = var.user_ocid
  private_key_path    = var.private_key_path
  fingerprint         = var.fingerprint
  region              = var.region
  config_file_profile = var.config_file_profile
}
