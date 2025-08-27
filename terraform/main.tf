terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

# Variables
variable "aws_region" {
  description = "AWS region for S3 bucket"
  type        = string
  default     = "us-east-1"
}

variable "transcribe_region" {
  description = "AWS region for Transcribe Medical (must support real-time streaming)"
  type        = string
  default     = "us-east-1"
  validation {
    condition     = contains(["us-east-1", "us-east-2", "us-west-2", "eu-west-1", "eu-central-1", "ap-southeast-2"], var.transcribe_region)
    error_message = "Transcribe Medical real-time streaming is only available in specific regions."
  }
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "medical-transcribe"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "poc"
}

# Provider configuration
provider "aws" {
  region = var.aws_region
}

# Random suffix for unique resource names
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# S3 Bucket for storing transcriptions
resource "aws_s3_bucket" "transcriptions" {
  bucket = "${var.project_name}-${var.environment}-transcriptions-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "${var.project_name}-transcriptions"
    Environment = var.environment
    Purpose     = "Medical transcription storage"
  }
}

# S3 Bucket versioning
resource "aws_s3_bucket_versioning" "transcriptions" {
  bucket = aws_s3_bucket.transcriptions.id

  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Bucket encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "transcriptions" {
  bucket = aws_s3_bucket.transcriptions.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# S3 Bucket public access block
resource "aws_s3_bucket_public_access_block" "transcriptions" {
  bucket = aws_s3_bucket.transcriptions.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 Bucket lifecycle rule for old transcriptions
resource "aws_s3_bucket_lifecycle_configuration" "transcriptions" {
  bucket = aws_s3_bucket.transcriptions.id

  rule {
    id     = "archive-old-transcriptions"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365 # Delete after 1 year
    }
  }
}

# IAM User for the application
resource "aws_iam_user" "app_user" {
  name = "${var.project_name}-${var.environment}-app-user"
  path = "/"

  tags = {
    Name        = "${var.project_name}-app-user"
    Environment = var.environment
  }
}

# IAM Access Key for the application user
resource "aws_iam_access_key" "app_user" {
  user = aws_iam_user.app_user.name
}

# IAM Policy for S3 access
resource "aws_iam_policy" "s3_access" {
  name        = "${var.project_name}-${var.environment}-s3-access"
  path        = "/"
  description = "IAM policy for S3 access to transcriptions bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetObjectVersion"
        ]
        Resource = [
          aws_s3_bucket.transcriptions.arn,
          "${aws_s3_bucket.transcriptions.arn}/*"
        ]
      }
    ]
  })
}

# IAM Policy for Transcribe Medical access
resource "aws_iam_policy" "transcribe_access" {
  name        = "${var.project_name}-${var.environment}-transcribe-access"
  path        = "/"
  description = "IAM policy for Amazon Transcribe Medical access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "transcribe:StartMedicalStreamTranscription",
          "transcribe:StartMedicalStreamTranscriptionWebSocket"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach policies to the IAM user
resource "aws_iam_user_policy_attachment" "s3_attach" {
  user       = aws_iam_user.app_user.name
  policy_arn = aws_iam_policy.s3_access.arn
}

resource "aws_iam_user_policy_attachment" "transcribe_attach" {
  user       = aws_iam_user.app_user.name
  policy_arn = aws_iam_policy.transcribe_access.arn
}

# Create a CORS configuration for the S3 bucket (optional, for direct browser access)
resource "aws_s3_bucket_cors_configuration" "transcriptions" {
  bucket = aws_s3_bucket.transcriptions.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["http://localhost:8080", "http://localhost:8000"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# Outputs
output "s3_bucket_name" {
  description = "Name of the S3 bucket for transcriptions"
  value       = aws_s3_bucket.transcriptions.id
}

output "s3_bucket_region" {
  description = "Region of the S3 bucket"
  value       = aws_s3_bucket.transcriptions.region
}

output "iam_user_name" {
  description = "Name of the IAM user"
  value       = aws_iam_user.app_user.name
}

output "iam_access_key_id" {
  description = "Access key ID for the application"
  value       = aws_iam_access_key.app_user.id
  sensitive   = true
}

output "iam_secret_access_key" {
  description = "Secret access key for the application"
  value       = aws_iam_access_key.app_user.secret
  sensitive   = true
}

output "transcribe_region" {
  description = "Region to use for Transcribe Medical"
  value       = var.transcribe_region
}

# Output environment variables for the application
output "env_file_content" {
  description = "Content for .env file"
  value = <<-EOT
# AWS Credentials (Generated by Terraform)
AWS_ACCESS_KEY_ID=${aws_iam_access_key.app_user.id}
AWS_SECRET_ACCESS_KEY=${aws_iam_access_key.app_user.secret}

# AWS Transcribe Configuration
TRANSCRIBE_REGION=${var.transcribe_region}
TRANSCRIBE_LANGUAGE_CODE=en-US
TRANSCRIBE_SPECIALTY=PRIMARYCARE
TRANSCRIBE_TYPE=DICTATION
SAMPLE_RATE_HZ=16000

# S3 Configuration
S3_BUCKET=${aws_s3_bucket.transcriptions.id}
S3_PREFIX=medical-transcriptions

# Server Configuration
PORT=8000
EOT
  sensitive = true
}