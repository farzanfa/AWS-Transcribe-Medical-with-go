# EC2 Infrastructure for Medical Transcription Backend

# Key pair for SSH access (using existing key or create new)
variable "key_pair_name" {
  description = "Name of the EC2 key pair for SSH access"
  type        = string
  default     = "" # Leave empty to create a new key pair
}

# VPC and Networking
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.project_name}-${var.environment}-vpc"
    Environment = var.environment
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-igw"
    Environment = var.environment
  }
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.project_name}-${var.environment}-public-subnet"
    Environment = var.environment
  }
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-public-rt"
    Environment = var.environment
  }
}

# Route Table Association
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Group for Backend
resource "aws_security_group" "backend" {
  name        = "${var.project_name}-${var.environment}-backend-sg"
  description = "Security group for medical transcription backend"
  vpc_id      = aws_vpc.main.id

  # SSH access (restrict this to your IP in production)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # IMPORTANT: Restrict this to your IP in production
  }

  # Backend API port
  ingress {
    description = "Backend API"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow from anywhere for client access
  }

  # Outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-backend-sg"
    Environment = var.environment
  }
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Data source for Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Generate new key pair if not provided
resource "tls_private_key" "ec2_key" {
  count     = var.key_pair_name == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated" {
  count      = var.key_pair_name == "" ? 1 : 0
  key_name   = "${var.project_name}-${var.environment}-key"
  public_key = tls_private_key.ec2_key[0].public_key_openssh
}

# Save private key locally
resource "local_file" "private_key" {
  count           = var.key_pair_name == "" ? 1 : 0
  content         = tls_private_key.ec2_key[0].private_key_pem
  filename        = "${path.module}/${var.project_name}-${var.environment}-key.pem"
  file_permission = "0400"
}

# EC2 Instance for Backend
resource "aws_instance" "backend" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.medium" # Adjust based on your needs
  key_name      = var.key_pair_name != "" ? var.key_pair_name : aws_key_pair.generated[0].key_name
  
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.backend.id]
  associate_public_ip_address = true

  # Root block device configuration for 10 GB storage
  root_block_device {
    volume_type = "gp3"
    volume_size = 10
    encrypted   = true
    delete_on_termination = true
  }

  # Add IAM instance profile for AWS service access
  iam_instance_profile = aws_iam_instance_profile.backend.name

  # User data script to set up the backend
  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    aws_access_key_id       = aws_iam_access_key.app_user.id
    aws_secret_access_key   = aws_iam_access_key.app_user.secret
    transcribe_region       = var.transcribe_region
    s3_bucket              = aws_s3_bucket.transcriptions.id
    s3_prefix              = "medical-transcriptions"
  }))

  tags = {
    Name        = "${var.project_name}-${var.environment}-backend"
    Environment = var.environment
  }
}

# IAM Role for EC2 Instance
resource "aws_iam_role" "backend_instance" {
  name = "${var.project_name}-${var.environment}-backend-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "backend" {
  name = "${var.project_name}-${var.environment}-backend-profile"
  role = aws_iam_role.backend_instance.name
}

# Attach policies to instance role
resource "aws_iam_role_policy_attachment" "backend_s3" {
  role       = aws_iam_role.backend_instance.name
  policy_arn = aws_iam_policy.s3_access.arn
}

resource "aws_iam_role_policy_attachment" "backend_transcribe" {
  role       = aws_iam_role.backend_instance.name
  policy_arn = aws_iam_policy.transcribe_access.arn
}

# Elastic IP for consistent public IP
resource "aws_eip" "backend" {
  instance = aws_instance.backend.id
  domain   = "vpc"

  tags = {
    Name        = "${var.project_name}-${var.environment}-backend-eip"
    Environment = var.environment
  }
}

# Outputs for EC2
output "backend_public_ip" {
  description = "Public IP address of the backend EC2 instance"
  value       = aws_eip.backend.public_ip
}

output "backend_public_dns" {
  description = "Public DNS of the backend EC2 instance"
  value       = aws_instance.backend.public_dns
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = var.key_pair_name == "" ? "ssh -i ${path.module}/${var.project_name}-${var.environment}-key.pem ubuntu@${aws_eip.backend.public_ip}" : "ssh -i <your-key.pem> ubuntu@${aws_eip.backend.public_ip}"
}

output "backend_url" {
  description = "Backend API URL"
  value       = "http://${aws_eip.backend.public_ip}:8000"
}

output "websocket_url" {
  description = "WebSocket URL for the backend"
  value       = "ws://${aws_eip.backend.public_ip}:8000/ws"
}