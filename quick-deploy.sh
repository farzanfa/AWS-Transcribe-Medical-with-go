#!/bin/bash

# Quick deployment script for backend on EC2 and client local
# This script automates the entire deployment process

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Medical Transcription Service - Quick Deploy${NC}"
echo -e "${BLUE}===========================================${NC}"
echo ""

# Function to check prerequisites
check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    # Check Terraform
    if ! command -v terraform &> /dev/null; then
        echo -e "${RED}Error: Terraform is not installed${NC}"
        echo "Please install Terraform: https://www.terraform.io/downloads"
        exit 1
    fi
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        echo -e "${RED}Error: AWS CLI is not installed${NC}"
        echo "Please install AWS CLI: https://aws.amazon.com/cli/"
        exit 1
    fi
    
    # Check Python 3
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Error: Python 3 is not installed${NC}"
        echo "Please install Python 3"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        echo -e "${RED}Error: AWS credentials not configured${NC}"
        echo "Please run: aws configure"
        exit 1
    fi
    
    echo -e "${GREEN}All prerequisites met!${NC}"
}

# Function to deploy infrastructure
deploy_infrastructure() {
    echo ""
    echo -e "${YELLOW}Step 1: Deploying AWS Infrastructure${NC}"
    
    cd terraform
    
    # Initialize Terraform if needed
    if [ ! -d ".terraform" ]; then
        echo "Initializing Terraform..."
        terraform init
    fi
    
    # Check if terraform.tfvars exists
    if [ ! -f "terraform.tfvars" ]; then
        echo "Creating terraform.tfvars from example..."
        cp terraform.tfvars.example terraform.tfvars
        echo -e "${YELLOW}Please review terraform/terraform.tfvars and update if needed${NC}"
        read -p "Press Enter to continue after reviewing the file..."
    fi
    
    # Plan and apply
    echo "Planning infrastructure changes..."
    terraform plan
    
    echo ""
    read -p "Do you want to apply these changes? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "${RED}Deployment cancelled${NC}"
        exit 1
    fi
    
    terraform apply -auto-approve
    
    # Get outputs
    EC2_IP=$(terraform output -raw backend_public_ip)
    
    # Save .env file
    echo "Saving environment configuration..."
    terraform output -raw env_file_content > ../.env
    
    cd ..
    
    echo -e "${GREEN}Infrastructure deployed successfully!${NC}"
    echo -e "${GREEN}EC2 Public IP: $EC2_IP${NC}"
}

# Function to deploy backend
deploy_backend() {
    echo ""
    echo -e "${YELLOW}Step 2: Deploying Backend to EC2${NC}"
    
    echo "Waiting for EC2 instance to initialize (30 seconds)..."
    sleep 30
    
    ./deploy-backend.sh $EC2_IP
    
    echo -e "${GREEN}Backend deployed successfully!${NC}"
}


# Main execution
main() {
    check_prerequisites
    
    # Check if infrastructure already exists
    if [ -f "terraform/terraform.tfstate" ] && [ -s "terraform/terraform.tfstate" ]; then
        echo ""
        echo -e "${YELLOW}Terraform state file exists. Infrastructure may already be deployed.${NC}"
        read -p "Do you want to redeploy infrastructure? (yes/no): " redeploy
        
        if [ "$redeploy" == "yes" ]; then
            deploy_infrastructure
        else
            # Try to get EC2 IP from existing state
            cd terraform
            EC2_IP=$(terraform output -raw backend_public_ip 2>/dev/null || echo "")
            cd ..
            
            if [ -z "$EC2_IP" ]; then
                echo -e "${RED}Error: Could not get EC2 IP from Terraform state${NC}"
                echo "Please run: cd terraform && terraform output backend_public_ip"
                exit 1
            fi
            
            echo -e "${GREEN}Using existing EC2 instance: $EC2_IP${NC}"
        fi
    else
        deploy_infrastructure
    fi
    
    # Ask if user wants to deploy backend
    echo ""
    read -p "Do you want to deploy/update the backend? (yes/no): " deploy_be
    if [ "$deploy_be" == "yes" ]; then
        deploy_backend
    fi
    
}

# Run main function
main