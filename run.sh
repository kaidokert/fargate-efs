#!/bin/bash

set -euo pipefail

# VPC_ID=abc-1232
# PUBLIC_SUBNET_ID=abc-1234
# PRIVATE_SUBNET_ID=abc-1234

## Create security group
SG_ID=$(aws ec2 create-security-group --group-name fargate-efs-sg \
  --description "Security group for fargate efs example" --vpc-id "$VPC_ID" | jq -r '.GroupId')

echo "Created SG_ID: $SG_ID"

# Authorise your ip only.
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr "$(curl -s checkip.amazonaws.com)/32"

# Ingress to efs via sg only
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 2049 \
  --source-group "$SG_ID"

# Create efs filesystem
FILE_SYSTEM_ID=$(aws efs create-file-system | jq -r '.FileSystemId')

echo "Created FILE_SYSTEM_ID_ID: $FILE_SYSTEM_ID"

echo "Sleep for 60 until EFS settles"
sleep 60

# Create a mount target in a private subnet.
aws efs create-mount-target \
--file-system-id "$FILE_SYSTEM_ID" \
--subnet-id "$PRIVATE_SUBNET_ID" \
--security-group "$SG_ID"

# Put the fs-id into the fargate task
sed "s/fs-abc123/$FILE_SYSTEM_ID/g" fargate-task.json > fargate-task.json.local

# Create the cluster, this is idempotent
aws ecs create-cluster --cluster-name fargate-cluster

# Register the task definition
TASK_ARN=$(aws ecs register-task-definition --requires-compatibilities FARGATE \
  --cli-input-json file://fargate-task.json.local | jq -r '.taskDefinition.taskDefinitionArn')

# Create the service.
aws ecs create-service --cluster fargate-cluster \
  --service-name fargate-service --task-definition "$TASK_ARN" \
  --desired-count 1 --launch-type "FARGATE" \
  --network-configuration \
    "awsvpcConfiguration={subnets=[$PUBLIC_SUBNET_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --platform-version 1.4.0 \
  --tags key=Name,value=fargate-efs \
  --enable-ecs-managed-tags # need this for tags and finding public ip a little easier

# Sleep a bit as service takes a minute or so to start
echo "Sleep for 90 to give the service a chance to start"
sleep 90

# Get the public ip of the eni via tags of the task.

PUBLIC_IP=$(aws ec2 describe-network-interfaces \
    --filters Name=tag:"aws:ecs:serviceName",Values=fargate-service \
    | jq -r '.NetworkInterfaces[].PrivateIpAddresses[].Association.PublicIp')

# Test, this should return df output of the filesystem.
curl --retry-connrefused --retry 10 http://$PUBLIC_IP
