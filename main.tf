# Consolidate all the comments into the readme at the end!
terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# We're using Azure here
# Using cached Azure CLI creds because setting up a service principal is overkill for a demo
provider "azurerm" {
  features {}
}

## Set variables

variable "location" {
  description = "Azure region"
  type        = string
  default     = "New Zealand North"
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
  default     = "rg-web-demo"
}

variable "vm_size" {
  description = "VM size"
  type        = string
  default     = "Standard_B1s"
}

variable "instance_count" {
  description = "Number of VM instances (default 2 for N+1 while meeting cost limitations)"
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 2
    error_message = "Instance count must be at least 2 to meet N+1 requirement."
  }
}

## Set resources
# For the Azure stuff, prefix azurerm_ for tidiness

# Generate SSH key pair
# I note that this will store it in the Terraform state. In production, we'd manage our keys securely.
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Azure resource group
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

# Virtual network, use 172.16.0.0/16 since I'm currently using 10.0.0.0/16 in the lab
resource "azurerm_virtual_network" "main" {
  name                = "vnet-web"
  address_space       = ["172.16.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

# Web services can have a whole /24
resource "azurerm_subnet" "web" {
  name                 = "subnet-web"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["172.16.1.0/24"]
}

# Public IP for the load balancer
# Across 3 zones despite only 2 VMs - the VMSS config will mirror this and gives redundancy in case we lose two zones
resource "azurerm_public_ip" "lb" {
  name                = "pip-web-lb"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

# Set up the load balancer
resource "azurerm_lb" "main" {
  name                = "lb-web"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "web-lb-frontend"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

# Backend address pool for the load balancer
resource "azurerm_lb_backend_address_pool" "main" {
  loadbalancer_id = azurerm_lb.main.id
  name            = "web-lb-backend-pool"
}

# Set up a health probe here

# Forwarding from the load balancer to the nginx servers
# Load Balancer Rule
resource "azurerm_lb_rule" "main" {
  loadbalancer_id                = azurerm_lb.main.id
  name                           = "http-rule"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "web-lb-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.main.id]
  probe_id                       = azurerm_lb_probe.main.id
}


# NSGs here

# Link the NSG with the web services subnet

# Virtual machine scale set config
# use 22_04 LTS
# custom_data = base64encode(<<-EOF
# #!/bin/bash
# apt-get update -y
# apt-get install -y nginx
# systemctl start nginx
# systemctl enable nginx
# EOF
# )
resource "azurerm_linux_virtual_machine_scale_set" "main" {

}

# Set up an autoscale monitor to keep the number of VMs at 2
# Use the var.instance_count to set default, min and max as 2
# Reuse the old Ptero deployment code but remove the maximum and minimum instance count

# Outputs
output "load_balancer_ip" {
  description = "Public IP of the load balancer"
  value       = azurerm_public_ip.lb.ip_address
}

output "load_balancer_url" {
  description = "URL to access the application"
  value       = "http://${azurerm_public_ip.lb.ip_address}"
}

output "resource_group_name" {
  description = "Azure resource group name"
  value       = azurerm_resource_group.main.name
}

output "ssh_private_key" {
  description = "Private SSH key to access VMs (save this securely)"
  value       = tls_private_key.ssh.private_key_pem
  sensitive   = true
}

output "vmss_name" {
  description = "VMSS Name"
  value       = azurerm_linux_virtual_machine_scale_set.main.name
}