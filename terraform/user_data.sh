#!/bin/bash
set -e

# Log output for debugging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "Starting backend deployment setup..."

# Update system
sudo apt-get update -y
sudo apt-get upgrade -y

# Install required packages
echo "Installing required packages..."
# Install Docker prerequisites
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin git

# Start and enable Docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -a -G docker ubuntu


# Create app directory
echo "Setting up application directory..."
sudo mkdir -p /opt/medical-transcription
sudo chown ubuntu:ubuntu /opt/medical-transcription

# Clone the repository (you'll need to update this with your repo URL)
cd /opt/medical-transcription
# git clone https://github.com/your-username/your-repo.git .

# For now, create the backend directory structure manually
mkdir -p backend

# Copy backend files (we'll create a deployment script to handle this)
# For initial setup, we'll create the files directly

# Create .env file
cat > /opt/medical-transcription/.env << 'EOF'
# AWS Credentials
AWS_ACCESS_KEY_ID=${aws_access_key_id}
AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}

# AWS Transcribe Configuration
TRANSCRIBE_REGION=${transcribe_region}
TRANSCRIBE_LANGUAGE_CODE=en-US
TRANSCRIBE_SPECIALTY=PRIMARYCARE
TRANSCRIBE_TYPE=DICTATION
SAMPLE_RATE_HZ=16000

# S3 Configuration
S3_BUCKET=${s3_bucket}
S3_PREFIX=${s3_prefix}

# Server Configuration
PORT=8000
EOF

# Create a systemd service for the backend
sudo tee /etc/systemd/system/medical-transcription.service > /dev/null << 'EOF'
[Unit]
Description=Medical Transcription Backend Service
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/medical-transcription
ExecStart=/usr/local/bin/docker-compose up backend
ExecStop=/usr/local/bin/docker-compose down
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Note: The actual backend deployment will be handled by the deploy script
echo "Initial setup complete. Use the deploy script to deploy the backend code."