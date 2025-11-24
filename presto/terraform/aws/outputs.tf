output "coordinator_public_ip" {
  description = "Public IP of coordinator"
  value       = aws_instance.coordinator.public_ip
}

output "coordinator_private_ip" {
  description = "Private IP of coordinator"
  value       = aws_instance.coordinator.private_ip
}

output "worker_public_ips" {
  description = "Public IPs of workers"
  value       = aws_instance.workers[*].public_ip
}

output "worker_private_ips" {
  description = "Private IPs of workers"
  value       = aws_instance.workers[*].private_ip
}

output "presto_ui_url" {
  description = "Presto Web UI URL"
  value       = "http://${aws_instance.coordinator.public_ip}:8080"
}

output "ssh_coordinator" {
  description = "SSH command for coordinator"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.coordinator.public_ip}"
}

output "ssh_workers" {
  description = "SSH commands for workers"
  value       = [for i, ip in aws_instance.workers[*].public_ip : "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${ip}"]
}

output "hms_enabled" {
  description = "Is Hive Metastore Service enabled?"
  value       = var.enable_hms
}

output "hms_db_endpoint" {
  description = "HMS MySQL endpoint (if enabled)"
  value       = var.enable_hms ? module.hms.hms_db_endpoint : "N/A"
}

output "hive_metastore_uri" {
  description = "Thrift URI for Hive Metastore"
  value       = var.enable_hms ? "thrift://${aws_instance.coordinator.private_ip}:9083" : "file-based"
}

