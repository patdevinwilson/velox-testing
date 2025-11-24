# HMS Module Outputs

output "hms_db_endpoint" {
  description = "HMS database endpoint"
  value       = var.enable_hms ? aws_db_instance.hms_db[0].endpoint : "N/A"
}

output "hms_db_address" {
  description = "HMS database address (without port)"
  value       = var.enable_hms ? aws_db_instance.hms_db[0].address : "N/A"
}

output "hms_thrift_uri" {
  description = "HMS Thrift URI for Presto configuration"
  value       = var.enable_hms ? "thrift://localhost:9083" : "N/A"
}

output "hms_enabled" {
  description = "Whether HMS is enabled"
  value       = var.enable_hms
}

