resource "random_integer" "ip_part" {
  # prevent overlap with 10.96.0.0/12
  min = 112
  # prevent overlap with 10.244.0.0/16
  max = 243
}

locals {
  private_network_cidr = var.os_private_network_cidr != "" ? var.os_private_network_cidr : "10.${random_integer.ip_part.result}.0.0/16"

  client_configuration = {
    ca_certificate     = var.talos_secrets.certs.os.crt
    client_certificate = base64encode(module.talos-config.talos_client_crt)
    client_key         = base64encode(module.talos-config.talos_client_key)
  }
}

################################################################################
# Openstack network setup
################################################################################
module "network" {
  source = "./modules/network"

  name_prefix             = var.base_name
  os_public_network_name  = var.os_public_network_name
  os_private_network_name = var.os_private_network_name
  os_private_network_cidr = local.private_network_cidr
  worker_count            = var.worker_count
  controlplane_count      = var.controlplane_count
  kube_api_external_ip    = var.kube_api_external_ip
  kube_api_external_port  = var.kube_api_external_port
}

################################################################################
# Talos config setup
################################################################################
module "talos-config" {
  source = "./modules/talos_config"

  cluster_name                     = var.base_name
  talos_secrets                    = var.talos_secrets
  kube_api_external_ip             = var.kube_api_external_ip
  kube_api_external_port           = var.kube_api_external_port
  kubernetes_version               = var.kubernetes_version
  os_ccm_version                   = var.openstack_ccm_version
  os_auth_url                      = var.os_auth_url
  os_application_credential_id     = var.os_application_credential_id
  os_application_credential_secret = var.os_application_credential_secret
  os_user_name                     = var.os_user_name
  public_network_id                = module.network.public_network_id
  private_network_subnet_id        = module.network.private_network_subnet_id

  pod_security_exemptions_namespaces = var.pod_security_exemptions_namespaces
}

module "instances" {
  source = "./modules/instances"

  name_prefix                  = var.base_name
  worker_count                 = var.worker_count
  controlplane_count           = var.controlplane_count
  image_name                   = var.image_name
  worker_instance_flavor       = var.worker_instance_flavor
  worker_volume_type           = var.worker_volume_type
  worker_volume_size           = var.worker_volume_size
  worker_port_id               = module.network.worker_port_id
  worker_user_data             = module.talos-config.worker_machine_configuration
  controlplane_instance_flavor = var.controlplane_instance_flavor
  controlplane_volume_type     = var.controlplane_volume_type
  controlplane_volume_size     = var.controlplane_volume_size
  controlplane_port_id         = module.network.controlplane_port_id
}

############################
# Apply Talos configuration
############################
resource "talos_machine_configuration_apply" "controlplane" {
  count = var.controlplane_count

  depends_on = [
    module.network,
    module.instances
  ]

  client_configuration = local.client_configuration
  endpoint             = var.kube_api_external_ip
  node                 = module.network.controlplane_fixed_ips[count.index]

  machine_configuration_input = module.talos-config.controlplane_machine_configuration
}

resource "talos_machine_configuration_apply" "worker" {
  count = var.worker_count

  depends_on = [talos_machine_configuration_apply.controlplane]

  client_configuration = local.client_configuration
  endpoint             = var.kube_api_external_ip
  node                 = module.network.worker_fixed_ips[count.index]

  machine_configuration_input = module.talos-config.worker_machine_configuration
}

########################
# Boostrap cluster
########################
resource "talos_machine_bootstrap" "cluster" {
  depends_on = [
    module.network,
    module.instances,
    talos_machine_configuration_apply.controlplane,
    talos_machine_configuration_apply.worker
  ]

  client_configuration = local.client_configuration

  node     = module.network.controlplane_fixed_ips[0]
  endpoint = var.kube_api_external_ip
}

data "talos_cluster_health" "talos" {
  depends_on = [talos_machine_bootstrap.cluster]

  client_configuration = local.client_configuration

  control_plane_nodes = module.network.controlplane_fixed_ips
  worker_nodes        = module.network.worker_fixed_ips
  endpoints           = [var.kube_api_external_ip]
}

data "talos_client_configuration" "talos" {
  cluster_name         = var.base_name
  client_configuration = local.client_configuration
  endpoints            = [var.kube_api_external_ip]
}

locals {
  openstack_helm_chart_version = replace(var.openstack_ccm_version, "v1", "2")
}

resource "helm_release" "openstack_cloud_controller_manager" {
  depends_on = [data.talos_cluster_health.talos]

  name       = "openstack-cloud-controller-manager"
  chart      = "openstack-cloud-controller-manager"
  version    = local.openstack_helm_chart_version
  repository = "https://kubernetes.github.io/cloud-provider-openstack"
  namespace  = "kube-system"

  values = [yamlencode({
    secret = {
      enabled = true
      create  = false
    }
    cluster = {
      name = var.base_name
    }
  })]

  wait = true
}
