# Development Environment Variables
# These are overridden by config.psd1 values during automated deployment

environment    = "dev"
hyperv_host    = "localhost"
vm_count       = 1
vm_memory_gb   = 4
vm_cpus        = 2
vm_path        = "E:\\VMs"
# iso_path is set dynamically by 0300_Deploy-Infrastructure.ps1
