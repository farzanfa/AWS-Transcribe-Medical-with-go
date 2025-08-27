# Medical Transcription Service

A production-grade POC for real-time medical transcription using Amazon Transcribe Medical. The service consists of a Go backend and a web client that streams audio from the browser to AWS Transcribe Medical for real-time transcription.

## Architecture

- **Backend**: Go 1.22 with Gorilla WebSocket, AWS SDK v2
- **Client**: HTML5 + JavaScript with AudioWorklet API
- **AWS Services**: Amazon Transcribe Medical (streaming), Amazon S3
- **Deployment**: Docker Compose

## Features

- Real-time audio streaming from browser to backend via WebSocket
- Live transcription with partial and final results
- Medical specialty and transcription type selection
- Automatic S3 upload of completed transcriptions
- Docker-based deployment

## Prerequisites

- Docker and Docker Compose installed
- Terraform >= 1.0 (for automated AWS provisioning)
- AWS account with appropriate permissions for:
  - Amazon Transcribe Medical
  - Amazon S3
  - IAM (if using Terraform)
- AWS CLI configured (if using Terraform)

## Setup

### Option 1: Automated Setup with Terraform (Recommended)

1. Clone the repository and navigate to the project directory

2. Provision AWS resources using Terraform:
   ```bash
   cd terraform
   terraform init
   terraform apply
   ```
   Type `yes` when prompted. This will create:
   - S3 bucket with encryption and lifecycle policies
   - IAM user with minimal required permissions
   - Access keys for the application

3. Generate the .env file automatically:
   ```bash
   terraform output -raw env_file_content > ../.env
   cd ..
   ```

### Option 2: Manual Setup

1. Clone the repository and navigate to the project directory

2. Create an S3 bucket in AWS for storing transcriptions

3. Create an IAM user with the following policies:
   - S3 access to your bucket (PutObject, GetObject, ListBucket)
   - Transcribe Medical streaming access

4. Copy the example environment file and configure it:
   ```bash
   cp .env.example .env
   ```

5. Edit `.env` with your AWS credentials and configuration:
   - `AWS_ACCESS_KEY_ID`: Your AWS access key
   - `AWS_SECRET_ACCESS_KEY`: Your AWS secret key
   - `TRANSCRIBE_REGION`: Use `us-east-1` or `eu-west-1` (Transcribe Medical real-time is not available in all regions)
   - `S3_BUCKET`: Your S3 bucket name for storing transcriptions
   - Other settings can be left as defaults or customized as needed

## Running the Application

1. Start the services using Docker Compose:
   ```bash
   docker compose up --build
   ```

2. Open your browser and navigate to:
   ```
   http://localhost:8080
   ```

3. Grant microphone permissions when prompted

4. Select medical specialty and transcription type

5. Click "Start Recording" to begin transcription

6. Speak into your microphone - you'll see partial and final transcriptions appear in real-time

7. Click "Stop Recording" to end the session and save the transcription to S3

## WebSocket Protocol

The client and backend communicate using the following WebSocket protocol:

### Client → Backend

**Audio Data (Binary)**
- Raw PCM audio frames
- Format: 16kHz, mono, 16-bit signed integer, little-endian
- Sent in ~20ms chunks

**Control Messages (JSON)**
```json
{
  "type": "control",
  "action": "stop"
}
```

### Backend → Client

**Partial Transcript**
```json
{
  "type": "partial",
  "text": "partial transcription text..."
}
```

**Final Transcript**
```json
{
  "type": "final",
  "text": "final transcription text..."
}
```

**Save Confirmation**
```json
{
  "type": "saved",
  "key": "medical-transcriptions/transcription_2024-01-15_10-30-45.txt"
}
```

**Error Message**
```json
{
  "type": "error",
  "text": "error description"
}
```

## Project Structure

```
.
├── backend/
│   ├── main.go           # Go backend implementation
│   ├── go.mod            # Go module definition
│   ├── go.sum            # Go module checksums
│   └── Dockerfile        # Backend Docker configuration
├── client/
│   ├── index.html        # Web interface
│   ├── app.js            # Client-side application logic
│   ├── audio-processor.js # AudioWorklet processor
│   ├── nginx.conf        # Nginx configuration
│   └── Dockerfile        # Client Docker configuration
├── terraform/
│   ├── main.tf           # Terraform configuration
│   ├── terraform.tfvars.example # Example Terraform variables
│   └── README.md         # Terraform documentation
├── docker-compose.yml    # Docker Compose orchestration
├── .env.example          # Example environment variables
├── .gitignore            # Git ignore file
└── README.md             # This file
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `AWS_ACCESS_KEY_ID` | AWS access key | Required |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key | Required |
| `TRANSCRIBE_REGION` | AWS region for Transcribe | `us-east-1` |
| `TRANSCRIBE_LANGUAGE_CODE` | Language for transcription | `en-US` |
| `TRANSCRIBE_SPECIALTY` | Medical specialty | `PRIMARYCARE` |
| `TRANSCRIBE_TYPE` | Transcription type | `DICTATION` |
| `SAMPLE_RATE_HZ` | Audio sample rate | `16000` |
| `S3_BUCKET` | S3 bucket for saving | Required |
| `S3_BUCKET_REGION` | AWS region for S3 bucket | `us-east-1` |
| `S3_PREFIX` | S3 key prefix | `medical-transcriptions` |
| `PORT` | Backend server port | `8000` |

## Medical Specialties

Available specialties for transcription:
- `PRIMARYCARE` - Primary Care
- `CARDIOLOGY` - Cardiology
- `NEUROLOGY` - Neurology
- `ONCOLOGY` - Oncology
- `RADIOLOGY` - Radiology
- `UROLOGY` - Urology

## Troubleshooting

1. **WebSocket connection fails**
   - Ensure backend is running on port 8000
   - Check Docker logs: `docker compose logs backend`

2. **No audio input**
   - Verify microphone permissions in browser
   - Check browser console for errors

3. **AWS errors**
   - Verify AWS credentials in `.env`
   - Ensure region supports Transcribe Medical streaming
   - Check IAM permissions for Transcribe and S3

4. **Transcription not working**
   - Verify audio is being captured (check browser console)
   - Ensure AWS region supports Transcribe Medical real-time

## Terraform Resources

The included Terraform configuration (`terraform/` directory) automates the provisioning of:

- **S3 Bucket**: With encryption, versioning, and lifecycle policies
- **IAM User**: With minimal required permissions
- **IAM Policies**: For S3 and Transcribe Medical access
- **Access Keys**: Automatically generated and output to .env file

To destroy all AWS resources created by Terraform:
```bash
cd terraform
terraform destroy
```

## Security Considerations

- This POC allows all WebSocket origins for development
- In production, implement proper CORS policies
- Use HTTPS/WSS for secure communication
- Implement authentication and authorization
- Rotate AWS credentials regularly
- Use IAM roles in production environments
- The Terraform configuration follows AWS security best practices:
  - S3 bucket encryption enabled
  - Public access blocked
  - Minimal IAM permissions
  - Sensitive outputs marked appropriately

## Performance Notes

- Audio is downsampled to 16kHz for optimal Transcribe performance
- WebSocket frames are buffered to ~20ms chunks
- Partial transcripts update in real-time
- Final transcripts are more accurate but have slight delay

## License

This is a proof of concept for demonstration purposes.