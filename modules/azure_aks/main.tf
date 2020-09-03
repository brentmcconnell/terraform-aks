resource "azurerm_kubernetes_cluster" "modaks" {
  lifecycle {
    #    prevent_destroy = true
    ignore_changes = [
      default_node_pool[0].node_count
    ]
  }

  name                            = var.name
  location                        = var.location
  resource_group_name             = var.resource_group_name
  dns_prefix                      = var.name
  kubernetes_version              = var.kubernetes_version
  node_resource_group             = "${var.resource_group_name}-worker"
  private_cluster_enabled         = var.private_cluster
  sku_tier                        = var.sla_sku
  api_server_authorized_ip_ranges = var.api_auth_ips

  default_node_pool {
    name                          = substr(var.default_node_pool.name, 0, 12)
    orchestrator_version          = var.kubernetes_version
    node_count                    = 1
    vm_size                       = var.default_node_pool.vm_size
    type                          = "VirtualMachineScaleSets"
    availability_zones            = null
    max_pods                      = 30
    os_disk_size_gb               = 128
    vnet_subnet_id                = var.vnet_subnet_id
    node_labels                   = null 
    node_taints                   = null
    enable_auto_scaling           = false
    min_count                     = null 
    max_count                     = null 
    enable_node_public_ip         = false
  }
  
  identity {
    type = "SystemAssigned"
  }

  role_based_access_control {
    enabled = true
  }

  network_profile {
    docker_bridge_cidr            = "172.18.0.1/16"
    dns_service_ip                = "172.16.0.10"
    network_plugin                = "azure"
    outbound_type                 = "userDefinedRouting"
    service_cidr                  = "172.16.0.0/16"
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "system-nodes" {
  lifecycle {
    ignore_changes = [
      node_count, node_labels, node_taints
    ]
  }
  
  for_each = var.system_node_pools

  kubernetes_cluster_id           = azurerm_kubernetes_cluster.modaks.id
  mode                            = "System"
  name                            = each.value.node_os == "Windows" ? substr(each.key, 0, 6) : substr(each.key, 0, 12)
  orchestrator_version            = each.value.orchestrator_version
  node_count                      = each.value.node_count
  vm_size                         = each.value.vm_size
  availability_zones              = each.value.zones
  tags                            = each.value.azure_tags
  max_pods                        = 30
  os_disk_size_gb                 = 128
  os_type                         = each.value.node_os
  vnet_subnet_id                  = var.vnet_subnet_id
  node_labels                     = null
  node_taints                     = ["CriticalAddonsOnly=true:NoSchedule"]
  enable_auto_scaling             = each.value.cluster_auto_scaling
  min_count                       = each.value.cluster_auto_scaling_min_count
  max_count                       = each.value.cluster_auto_scaling_max_count
  enable_node_public_ip           = false
}

resource "azurerm_kubernetes_cluster_node_pool" "user-nodes" {
  lifecycle {
    ignore_changes = [
      node_count
    ]
  }

  for_each = var.user_node_pools

  kubernetes_cluster_id           = azurerm_kubernetes_cluster.modaks.id
  mode                            = "User"
  name                            = each.value.node_os == "Windows" ? substr(each.key, 0, 6) : substr(each.key, 0, 12)
  orchestrator_version            = each.value.orchestrator_version
  node_count                      = each.value.node_count
  vm_size                         = each.value.vm_size
  availability_zones              = each.value.zones
  tags                            = each.value.azure_tags
  max_pods                        = 30
  os_disk_size_gb                 = 128
  os_type                         = each.value.node_os
  vnet_subnet_id                  = var.vnet_subnet_id
  node_labels                     = null
  node_taints                     = null 
  enable_auto_scaling             = each.value.cluster_auto_scaling
  min_count                       = each.value.cluster_auto_scaling_min_count
  max_count                       = each.value.cluster_auto_scaling_max_count
  enable_node_public_ip           = false
}

resource "null_resource" "kubectl" {
  triggers = {
    default_node_version = azurerm_kubernetes_cluster.modaks.default_node_pool.0.orchestrator_version
  }

  provisioner "local-exec" {
    command = <<EOF
      for node in $(kubectl get nodes -l agentpool=default1 -o name --kubeconfig <(echo $KUBECONFIG | base64 --decode)); do
        kubectl taint nodes "$node" default=true:NoExecute --overwrite=true --kubeconfig <(echo $KUBECONFIG | base64 --decode) 
      done
    EOF
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = "${base64encode(azurerm_kubernetes_cluster.modaks.kube_config_raw)}"
    }
  }

  # Marking these nodes as NoExecute requires the system pool to be available
  depends_on = [azurerm_kubernetes_cluster_node_pool.system-nodes]
}

