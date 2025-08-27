# Terraform Configuration for Medical Transcription Service

This Terraform configuration provisions the necessary AWS resources for the medical transcription service.

## Resources Created

1. **S3 Bucket**
   - Stores transcription files
   - Versioning enabled
   - Server-side encryption (AES256)
   - Public access blocked
   - Lifecycle rules for archiving and expiration
   - CORS configuration for local development

2. **IAM User**
   - Dedicated user for the application
   - Access key and secret key generated

3. **IAM Policies**
   - S3 access policy for the transcriptions bucket
   - Transcribe Medical access policy for streaming transcription

## Prerequisites

- Terraform >= 1.0
- AWS CLI configured with appropriate credentials
- AWS account with permissions to create IAM users, policies, and S3 buckets

## Usage

1. **Initialize Terraform**
   ```bash
   cd terraform
   terraform init
   ```

2. **Create a variables file**
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```
   Edit `terraform.tfvars` if you want to customize the values.

3. **Review the plan**
   ```bash
   terraform plan
   ```

4. **Apply the configuration**
   ```bash
   terraform apply
   ```
   Type `yes` when prompted to create the resources.

5. **Generate .env file**
   After successful apply, generate the .env file:
   ```bash
   terraform output -raw env_file_content > ../.env
   ```

## Configuration Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region for S3 bucket | `us-east-1` |
| `transcribe_region` | AWS region for Transcribe Medical | `us-east-1` |
| `project_name` | Project name for resource naming | `medical-transcribe` |
| `environment` | Environment name | `poc` |

## Outputs

After running `terraform apply`, you'll get:

- `s3_bucket_name`: Name of the created S3 bucket
- `s3_bucket_region`: Region of the S3 bucket
- `iam_user_name`: Name of the IAM user
- `iam_access_key_id`: Access key ID (sensitive)
- `iam_secret_access_key`: Secret access key (sensitive)
- `transcribe_region`: Region for Transcribe Medical
- `env_file_content`: Complete .env file content (sensitive)

## Security Considerations

1. **Credentials**: The IAM access keys are marked as sensitive outputs. Handle them carefully.
2. **Least Privilege**: The IAM policies grant only the minimum required permissions.
3. **Encryption**: S3 bucket is encrypted at rest with AES256.
4. **Public Access**: S3 bucket has public access blocked.

## S3 Lifecycle Policy

The S3 bucket includes lifecycle rules to manage costs:
- After 30 days: Move to Infrequent Access storage
- After 90 days: Move to Glacier storage
- After 365 days: Delete objects

Adjust these in `main.tf` if needed.

## Supported Transcribe Regions

Amazon Transcribe Medical real-time streaming is available in:
- `us-east-1` (N. Virginia)
- `us-east-2` (Ohio)
- `us-west-2` (Oregon)
- `eu-west-1` (Ireland)
- `eu-central-1` (Frankfurt)
- `ap-southeast-2` (Sydney)

## Cleanup

To destroy all created resources:
```bash
terraform destroy
```

## Important Notes

1. **Costs**: This will create AWS resources that incur costs:
   - S3 storage costs
   - Transcribe Medical usage costs
   - Data transfer costs

2. **Region Selection**: Ensure you select a region that supports Transcribe Medical real-time streaming.

3. **Backup**: The generated credentials are shown only once. Back them up securely.

## Integration with Docker Application

After running Terraform:
1. Generate the .env file: `terraform output -raw env_file_content > ../.env`
2. Navigate back to the project root: `cd ..`
3. Run the application: `docker compose up --build`