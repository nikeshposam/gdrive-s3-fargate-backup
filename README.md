# Terraform: Google Drive Backup to S3 (ECS Fargate + rclone)

This project provisions a minimal, scheduled backup job that syncs Google Drive to Amazon S3 using `rclone` running on ECS Fargate. A weekly EventBridge rule triggers the task, and logs are sent to CloudWatch Logs.

## What It Creates

- ECS cluster and Fargate task definition
- EventBridge rule (weekly schedule) and target to run the task
- CloudWatch log group for rclone logs
- IAM roles/policies for ECS task execution, task access, and EventBridge

## Requirements

- Terraform `>= 1.5`
- AWS account with:
  - VPC subnets (at least 2) and a security group
  - An S3 bucket for backups
  - A Secrets Manager secret that stores your `rclone.conf`

## How It Works

The task uses the `rclone/rclone:latest` container image. On start:

1. The task reads a Secrets Manager secret containing your `rclone.conf`.
2. It writes the config to `/config/rclone/rclone.conf`.
3. It runs `rclone sync` from the `Google` remote to the `S3Bucket` remote with a date prefix:
   - `s3://<backup_bucket_name>/<YYYY-MM-DD>/`

## Configuration

All required inputs live in `terraform.tfvars`:

```hcl
backup_bucket_name    = "my-backup-bucket" # S3 bucket name
rclone_conf_secret_id = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:RCLONE_CONF-abc123"
security_group_id     = "sg-0123456789abcdef0"
subnet_ids            = ["subnet-aaa111", "subnet-bbb222"]
```

Optional variables (defaults in `main.tf`):

- `aws_region` (default `ap-south-1`)
- `weekly_cron` (default `cron(30 2 ? * SUN *)`) — AWS cron is UTC
- `assign_public_ip` (default `true`)
- `log_retention_days` (default `30`)

## rclone.conf (Secrets Manager)

Create a Secrets Manager secret that contains the full `rclone.conf` content. This repo includes a template in `rclone.conf`. Make sure the remote names match the task:

- Source remote: `Google`
- Destination remote: `S3Bucket`

Example snippet (store the entire file as the secret value):

```ini
[Google]
type = drive
scope = drive
token = <generated_token>
team_drive =

[S3Bucket]
type = s3
provider = AWS
region = ap-south-1
endpoint =
access_key_id = <aws_access_key>
secret_access_key = <aws_secret_key>
```

## Deploy

```powershell
terraform init
terraform plan
terraform apply
```

## Logs and Monitoring

Logs are written to CloudWatch Logs:

- Log group: `/ecs/gdrive-rclone-backup`
- Stream prefix: `rclone`

## Security Notes

- Do not commit real `rclone.conf` credentials to the repo.
- Use Secrets Manager for `rclone.conf` and restrict access to the execution role.

## Cleanup

```powershell
terraform destroy
```
