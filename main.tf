#############################################
# main.tf — Minimal ECS Fargate weekly rclone
# Google Drive -> S3
#############################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

########################
# Variables
########################

variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "backup_bucket_name" {
  type = string
}

variable "rclone_conf_secret_id" {
  type = string
}

variable "weekly_cron" {
  type    = string
  default = "cron(30 2 ? * SUN *)"
}

variable "assign_public_ip" {
  type    = bool
  default = true
}

variable "log_retention_days" {
  type    = number
  default = 30
}

########################
# ECS Cluster
########################

resource "aws_ecs_cluster" "cluster" {
  name = "gdrive-backup-cluster"
}

########################
# IAM Roles
########################

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution Role (pull container)
resource "aws_iam_role" "execution_role" {
  name               = "gdrive-backup-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_policy" {
  role       = aws_iam_role.execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "execution_secrets_policy" {
  statement {
    sid     = "ReadRcloneConfSecret"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]

    # IMPORTANT: your var.rclone_conf_secret_id should be the SECRET ARN
    resources = [var.rclone_conf_secret_id]
  }
}

resource "aws_iam_role_policy" "execution_secrets_inline" {
  name   = "gdrive-backup-execution-secrets"
  role   = aws_iam_role.execution_role.id
  policy = data.aws_iam_policy_document.execution_secrets_policy.json
}

# Task Role (S3 + Secrets)
resource "aws_iam_role" "task_role" {
  name               = "gdrive-backup-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "task_policy" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]
    resources = ["*"]
  }

  statement {
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::${var.backup_bucket_name}",
      "arn:aws:s3:::${var.backup_bucket_name}/*"
    ]
  }
}

resource "aws_iam_role_policy" "task_inline" {
  role   = aws_iam_role.task_role.id
  policy = data.aws_iam_policy_document.task_policy.json
}

###############################
# Create a CloudWatch log group
###############################

resource "aws_cloudwatch_log_group" "ecs_rclone" {
  name              = "/ecs/gdrive-rclone-backup"
  retention_in_days = var.log_retention_days
}

########################
# ECS Task Definition
########################

resource "aws_ecs_task_definition" "task" {
  family                   = "gdrive-rclone-backup"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.execution_role.arn
  task_role_arn            = aws_iam_role.task_role.arn

  container_definitions = jsonencode([
    {
      name      = "rclone"
      image     = "rclone/rclone:latest"
      essential = true

      entryPoint = ["sh", "-c"]
      command = [
        "set -euo pipefail; mkdir -p /config/rclone; printf '%s' \"$RCLONE_CONF\" > /config/rclone/rclone.conf; STAMP=$(date +%F); rclone sync Google: S3Bucket:${var.backup_bucket_name}/$STAMP --config /config/rclone/rclone.conf --fast-list --transfers 8 --checkers 16 --tpslimit 8 --retries 10 --low-level-retries 20"
      ]

      secrets = [
        {
          name      = "RCLONE_CONF"
          valueFrom = var.rclone_conf_secret_id
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_rclone.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "rclone"
        }
      }
    }
  ])
}

########################
# EventBridge Schedule
########################

resource "aws_cloudwatch_event_rule" "weekly" {
  name                = "gdrive-backup-weekly"
  schedule_expression = var.weekly_cron
}

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_role" {
  name               = "gdrive-backup-events-role"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

data "aws_iam_policy_document" "events_policy" {
  statement {
    actions   = ["ecs:RunTask"]
    resources = [aws_ecs_task_definition.task.arn]
  }

  statement {
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.execution_role.arn,
      aws_iam_role.task_role.arn
    ]
  }
}

resource "aws_iam_role_policy" "events_inline" {
  role   = aws_iam_role.events_role.id
  policy = data.aws_iam_policy_document.events_policy.json
}

resource "aws_cloudwatch_event_target" "ecs_target" {
  rule     = aws_cloudwatch_event_rule.weekly.name
  arn      = aws_ecs_cluster.cluster.arn
  role_arn = aws_iam_role.events_role.arn

  ecs_target {
    task_definition_arn = aws_ecs_task_definition.task.arn
    launch_type         = "FARGATE"
    task_count          = 1

    network_configuration {
      subnets          = var.subnet_ids
      security_groups  = [var.security_group_id]
      assign_public_ip = var.assign_public_ip
    }
  }
}
