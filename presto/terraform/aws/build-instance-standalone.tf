# Standalone Build Instance with Internet Access
# Separate from main cluster VPC to ensure internet connectivity

# Get default VPC (has internet gateway by default)
data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "default" {
  vpc_id            = data.aws_vpc.default.id
  default_for_az    = true
  availability_zone = data.aws_availability_zones.available.names[0]
}

# Security group for build instance (in default VPC)
resource "aws_security_group" "build_sg" {
  count = var.create_build_instance ? 1 : 0
  
  name        = "${var.cluster_name}-build-sg"
  description = "Security group for Presto build instance"
  vpc_id      = data.aws_vpc.default.id

  # SSH from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  # Outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Internet access for downloading packages and repos"
  }

  tags = {
    Name = "${var.cluster_name}-build-sg"
  }
}

# Build instance in default VPC
resource "aws_instance" "build_standalone" {
  count = var.create_build_instance ? 1 : 0

  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "c7i.8xlarge"  # 32 vCPU, 64GB RAM for faster builds
  key_name               = var.key_name
  subnet_id              = data.aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.build_sg[0].id]
  
  associate_public_ip_address = true

  root_block_device {
    volume_size = 200
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user-data/build_s3a_complete.sh", {
    aws_access_key_id     = var.aws_access_key_id
    aws_secret_access_key = var.aws_secret_access_key
    aws_session_token     = var.aws_session_token
    aws_region            = var.aws_region
    ecr_repository        = var.presto_native_image
  })

  tags = {
    Name = "${var.cluster_name}-build-standalone"
    Role = "presto-native-build"
  }

  lifecycle {
    ignore_changes = [user_data]
  }
}

output "build_standalone_ip" {
  value       = var.create_build_instance ? aws_instance.build_standalone[0].public_ip : "N/A"
  description = "Public IP of standalone build instance (default VPC)"
}

output "build_standalone_ssh" {
  value       = var.create_build_instance ? "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.build_standalone[0].public_ip}" : "N/A"
  description = "SSH command for build instance"
}


