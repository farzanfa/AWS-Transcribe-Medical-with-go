#!/bin/bash

# Deploy backend to EC2 instance
# Usage: ./deploy-backend.sh <EC2_PUBLIC_IP>

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if EC2 IP is provided
if [ -z "$1" ]; then
    echo -e "${RED}Error: EC2 public IP address required${NC}"
    echo "Usage: ./deploy-backend.sh <EC2_PUBLIC_IP>"
    echo ""
    echo "You can get the EC2 IP from Terraform output:"
    echo "cd terraform && terraform output backend_public_ip"
    exit 1
fi

EC2_IP=$1
KEY_PATH=""

# Check for SSH key
if [ -f "terraform/medical-transcribe-poc-key.pem" ]; then
    KEY_PATH="terraform/medical-transcribe-poc-key.pem"
    echo -e "${GREEN}Found SSH key at: $KEY_PATH${NC}"
else
    echo -e "${YELLOW}SSH key not found at default location.${NC}"
    read -p "Enter path to your SSH private key: " KEY_PATH
    if [ ! -f "$KEY_PATH" ]; then
        echo -e "${RED}Error: SSH key not found at $KEY_PATH${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}Deploying backend to EC2 instance at $EC2_IP${NC}"

# Create temporary directory for deployment files
TEMP_DIR=$(mktemp -d)
echo "Creating deployment package in $TEMP_DIR"

# Copy backend files
cp -r backend/* $TEMP_DIR/
cp docker-compose.yml $TEMP_DIR/

# Create a modified docker-compose for production (backend only)
cat > $TEMP_DIR/docker-compose.prod.yml << 'EOF'
services:
  backend:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "8000:8000"
    environment:
      - PORT=8000
    env_file:
      - .env
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
EOF

# Create deployment archive
cd $TEMP_DIR
tar -czf backend-deployment.tar.gz *
cd -

echo -e "${YELLOW}Uploading backend files to EC2...${NC}"

# Upload the deployment archive
scp -i "$KEY_PATH" -o StrictHostKeyChecking=no $TEMP_DIR/backend-deployment.tar.gz ubuntu@$EC2_IP:/tmp/

# Deploy on EC2
echo -e "${YELLOW}Deploying on EC2...${NC}"

ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$EC2_IP << 'ENDSSH'
set -e

echo "Extracting backend files..."
cd /opt/medical-transcription
sudo rm -rf backend docker-compose.yml docker-compose.prod.yml
sudo tar -xzf /tmp/backend-deployment.tar.gz
sudo chown -R ubuntu:ubuntu .

echo "Checking if .env file exists..."
if [ ! -f .env ]; then
    echo "ERROR: .env file not found!"
    echo "Please create .env file at /opt/medical-transcription/.env with your AWS credentials"
    exit 1
fi

echo "Building Docker image..."
docker compose -f docker-compose.prod.yml build

echo "Starting backend service..."
docker compose -f docker-compose.prod.yml down 2>/dev/null || true
docker compose -f docker-compose.prod.yml up -d

echo "Waiting for service to start..."
sleep 10

echo "Checking service status..."
if docker compose -f docker-compose.prod.yml ps | grep -q "Up"; then
    echo "Backend service started successfully!"
    
    # Test health endpoint
    if curl -s http://localhost:8000/health > /dev/null; then
        echo "Health check passed!"
    else
        echo "Warning: Health check failed, but service is running"
    fi
else
    echo "ERROR: Backend service failed to start"
    docker compose -f docker-compose.prod.yml logs
    exit 1
fi

# Enable systemd service (optional)
sudo systemctl daemon-reload
sudo systemctl enable medical-transcription.service 2>/dev/null || true

echo "Deployment complete!"
ENDSSH

# Cleanup
rm -rf $TEMP_DIR

echo -e "${GREEN}Backend deployed successfully!${NC}"
echo -e "${GREEN}Backend API available at: http://$EC2_IP:8000${NC}"
echo -e "${GREEN}WebSocket endpoint: ws://$EC2_IP:8000/ws${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Update your client configuration to use the EC2 backend URL"
echo "2. Ensure security group allows traffic from your IP"
echo "3. Monitor logs with: ssh -i $KEY_PATH ubuntu@$EC2_IP 'cd /opt/medical-transcription && docker compose -f docker-compose.prod.yml logs -f'"