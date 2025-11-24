# Build Instance for Presto Native
# This is a one-time instance to build the Docker image on Linux

resource "aws_instance" "build_instance" {
  count = var.create_build_instance ? 1 : 0

  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "c7i.4xlarge"  # 16 vCPU, 32GB RAM - good for building
  key_name               = var.key_name
  subnet_id              = aws_subnet.presto_subnet.id
  vpc_security_group_ids = [aws_security_group.presto_sg.id]

  root_block_device {
    volume_size = 200
    volume_type = "gp3"
  }

  user_data = var.create_build_instance ? templatefile("${path.module}/user-data/build_instance.sh", {
    aws_access_key_id     = var.aws_access_key_id
    aws_secret_access_key = var.aws_secret_access_key
    aws_session_token     = var.aws_session_token
    aws_region            = var.aws_region
    ecr_repository        = var.presto_native_image
  }) : null

  tags = {
    Name = "${var.cluster_name}-build-instance"
    Role = "build"
  }

  lifecycle {
    ignore_changes = [user_data]
  }
}

output "build_instance_ip" {
  value       = var.create_build_instance ? aws_instance.build_instance[0].public_ip : "N/A"
  description = "Public IP of build instance"
}

