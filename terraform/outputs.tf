output "compartment-OCID" {
  value = oci_identity_compartment.tf-compartment.id
}

output "instance_ocid" {
  value = oci_core_instance.relay.id
}

output "instance_public_ip" {
  value = oci_core_instance.relay.public_ip
}

output "instance_private_ip" {
  value = oci_core_instance.relay.private_ip
}

output "ssh_user" {
  value = var.ansible_ssh_user
}

output "ansible_inventory" {
  value = <<-EOT
[${var.ansible_inventory_group}]
${oci_core_instance.relay.display_name} ansible_host=${oci_core_instance.relay.public_ip} ansible_user=${var.ansible_ssh_user}
EOT
}

output "ssh_command" {
  value = "ssh -i <private-key> ${var.ansible_ssh_user}@${oci_core_instance.relay.public_ip}"
}
