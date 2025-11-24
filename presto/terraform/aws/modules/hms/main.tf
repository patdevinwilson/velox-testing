# Hive Metastore Service (HMS) Module
# Enables external S3 table support for Presto

# RDS MySQL for HMS backend
resource "aws_db_instance" "hms_db" {
  count = var.enable_hms ? 1 : 0

  identifier        = "${var.cluster_name}-hms-db"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = var.hms_db_instance_class
  allocated_storage = 20
  storage_type      = "gp3"
  
  db_name  = "metastore"
  username = "hive"
  password = var.hms_db_password
  
  # Network
  db_subnet_group_name   = aws_db_subnet_group.hms[0].name
  vpc_security_group_ids = [aws_security_group.hms_db[0].id]
  
  # Availability
  multi_az               = false
  publicly_accessible    = false
  skip_final_snapshot    = true
  
  tags = {
    Name = "${var.cluster_name}-hms-db"
    Role = "metastore"
  }
}

# DB Subnet Group
resource "aws_db_subnet_group" "hms" {
  count = var.enable_hms ? 1 : 0

  name       = "${var.cluster_name}-hms-subnet-group"
  subnet_ids = var.subnet_ids
  
  tags = {
    Name = "${var.cluster_name}-hms-subnet-group"
  }
}

# Security Group for HMS Database
resource "aws_security_group" "hms_db" {
  count = var.enable_hms ? 1 : 0

  name        = "${var.cluster_name}-hms-db-sg"
  description = "Security group for HMS database"
  vpc_id      = var.vpc_id
  
  # Allow MySQL from Presto instances
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.presto_security_group_id]
    description     = "MySQL from Presto cluster"
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.cluster_name}-hms-db-sg"
  }
}

