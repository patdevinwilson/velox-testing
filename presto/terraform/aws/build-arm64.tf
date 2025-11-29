# ARM64 (Graviton) Build Instance
# Used to compile Presto Native for ARM64 architecture

resource "aws_instance" "build_arm64" {
  count = var.build_arm64 ? 1 : 0

  ami           = data.aws_ami.amazon_linux_arm64[0].id
  instance_type = "c7g.8xlarge"  # 32 vCPU, 64GB RAM - needed for heavy C++ compilation
  key_name      = var.key_name
  subnet_id     = aws_subnet.presto_subnet.id

  vpc_security_group_ids = [aws_security_group.presto_sg.id]

  root_block_device {
    volume_size = 200  # Need space for build artifacts
    volume_type = "gp3"
    throughput  = 250
    iops        = 4000
  }

  user_data = templatefile("${path.module}/user-data/build_arm64.sh", {
    aws_access_key_id     = var.aws_access_key_id
    aws_secret_access_key = var.aws_secret_access_key
    aws_session_token     = var.aws_session_token
    aws_region            = var.aws_region
  })

  tags = {
    Name = "${var.cluster_name}-build-arm64"
    Role = "build-arm64"
  }
}

# ARM64 AMI lookup
data "aws_ami" "amazon_linux_arm64" {
  count       = var.build_arm64 ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# Output for ARM64 build instance
output "build_arm64_ip" {
  description = "ARM64 build instance public IP"
  value       = var.build_arm64 && length(aws_instance.build_arm64) > 0 ? aws_instance.build_arm64[0].public_ip : "N/A"
}

output "build_arm64_ssh" {
  description = "SSH command for ARM64 build instance"
  value       = var.build_arm64 && length(aws_instance.build_arm64) > 0 ? "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.build_arm64[0].public_ip}" : "N/A"
}

