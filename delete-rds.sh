#!/usr/bin/env bash
set -euo pipefail

: "${AWS_REGION:?Set AWS_REGION}"
: "${DB_INSTANCE_ID:=jerney-pg}"
: "${DB_SUBNET_GROUP:=jerney-rds-subnets}"
: "${RDS_SG_NAME:=jerney-rds-sg}"

echo "Deleting RDS instance: $DB_INSTANCE_ID"

aws rds delete-db-instance \
  --region "$AWS_REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --skip-final-snapshot \
  --delete-automated-backups

echo "Waiting for RDS instance to be deleted..."
aws rds wait db-instance-deleted \
  --region "$AWS_REGION" \
  --db-instance-identifier "$DB_INSTANCE_ID"

echo "Deleting DB subnet group: $DB_SUBNET_GROUP"
aws rds delete-db-subnet-group \
  --region "$AWS_REGION" \
  --db-subnet-group-name "$DB_SUBNET_GROUP" || true

echo "Finding RDS security group: $RDS_SG_NAME"
RDS_SG_ID=$(
  aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=group-name,Values=$RDS_SG_NAME" \
    --query "SecurityGroups[0].GroupId" \
    --output text
)

if [[ "$RDS_SG_ID" != "None" && -n "$RDS_SG_ID" ]]; then
  echo "Deleting security group: $RDS_SG_ID"
  aws ec2 delete-security-group \
    --region "$AWS_REGION" \
    --group-id "$RDS_SG_ID"
else
  echo "Security group not found, skipping."
fi

echo "Done."
