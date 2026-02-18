# ─── terraform/main.tf ───────────────────────────────────────────
# SmartDoor AWS Infrastructure — EKS + VPC + RDS + ElastiCache

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes",  version = "~> 2.0" }
    helm       = { source = "hashicorp/helm",        version = "~> 2.0" }
    random     = { source = "hashicorp/random",      version = "~> 3.0" }
  }

  # Remote state: S3 + DynamoDB locking
  backend "s3" {
    bucket         = "smartdoor-terraform-state"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "smartdoor-tf-lock"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "SmartDoor"
      Environment = var.environment
      ManagedBy   = "Terraform"
      CostCenter  = "smartdoor-facility"   # FinOps: tag every resource
    }
  }
}

# ── VPC ────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "smartdoor-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  # FinOps: single NAT in staging, one per AZ in prod
  single_nat_gateway   = var.environment != "production"
  enable_dns_hostnames = true
  enable_flow_log      = true       # Security audit trail

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = 1
    "kubernetes.io/cluster/smartdoor-eks"         = "owned"
  }
  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = 1
    "kubernetes.io/cluster/smartdoor-eks"         = "shared"
  }
}

# ── EKS Cluster ────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "smartdoor-eks"
  cluster_version = "1.29"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  enable_irsa = true   # IAM Roles for Service Accounts

  eks_managed_node_groups = {
    # FinOps: Spot instances for app workloads (up to 70% cheaper)
    spot = {
      name            = "smartdoor-spot"
      instance_types  = ["t3.medium", "t3a.medium", "t3.large"]
      capacity_type   = "SPOT"
      min_size        = 1
      max_size        = 8
      desired_size    = 2
      labels = { role = "app", "spot" = "true" }
    }

    # On-demand for system-critical pods only
    on_demand = {
      name           = "smartdoor-system"
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      max_size       = 3
      desired_size   = 1
      taints = [{ key = "CriticalAddonsOnly", effect = "NO_SCHEDULE" }]
      labels = { role = "system" }
    }
  }

  cluster_addons = {
    coredns            = { most_recent = true }
    kube-proxy         = { most_recent = true }
    vpc-cni            = { most_recent = true }
    aws-ebs-csi-driver = { most_recent = true }
  }
}

# ── RDS PostgreSQL ─────────────────────────────────────────────────
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier        = "smartdoor-postgres"
  engine            = "postgres"
  engine_version    = "16.2"
  # FinOps: smaller instance in staging
  instance_class    = var.environment == "production" ? "db.t3.medium" : "db.t3.micro"

  db_name  = "smartdoor_db"
  username = "smartdoor"
  password = var.db_password

  vpc_security_group_ids = [module.rds_sg.security_group_id]
  subnet_ids             = module.vpc.private_subnets

  multi_az                = var.environment == "production"  # HA only in prod
  deletion_protection     = var.environment == "production"
  backup_retention_period = var.environment == "production" ? 7 : 1
  storage_encrypted       = true
  performance_insights_enabled = true

  # FinOps: Reserved Instance recommendation tag
  tags = {
    ReservedInstance = "candidate"
    CostAllocation   = "database"
  }
}

# ── ElastiCache Redis ──────────────────────────────────────────────
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "smartdoor-redis"
  description          = "SmartDoor Redis — session cache and pub/sub"

  # FinOps: t3.micro is sufficient for this load
  node_type           = "cache.t3.micro"
  num_cache_clusters  = var.environment == "production" ? 2 : 1
  port                = 6379

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  automatic_failover_enabled = var.environment == "production"

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [module.redis_sg.security_group_id]

  tags = {
    Environment    = var.environment
    CostAllocation = "cache"
  }
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "smartdoor-redis-subnet"
  subnet_ids = module.vpc.private_subnets
}

# ── Cluster Autoscaler (FinOps: scale-to-zero off-peak) ───────────
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"

  set { name = "autoDiscovery.clusterName";          value = "smartdoor-eks" }
  set { name = "awsRegion";                           value = var.aws_region }
  set { name = "extraArgs.scale-down-enabled";        value = "true" }
  set { name = "extraArgs.scale-down-delay-after-add";value = "10m" }
  set { name = "extraArgs.skip-nodes-with-system-pods";value = "false" }
}

# ── S3 for Terraform State ─────────────────────────────────────────
resource "aws_s3_bucket" "tf_state" {
  bucket = "smartdoor-terraform-state"
  tags   = { Purpose = "terraform-state", CostAllocation = "infrastructure" }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "smartdoor-tf-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute { name = "LockID"; type = "S" }
}


# ─── terraform/variables.tf ──────────────────────────────────────
variable "aws_region"   { default = "us-east-1" }
variable "environment"  { description = "staging | production"; type = string }
variable "db_password"  { description = "RDS password";         type = string; sensitive = true }
variable "cluster_name" { default = "smartdoor-eks" }

# ─── terraform/outputs.tf ────────────────────────────────────────
output "eks_cluster_endpoint"  { value = module.eks.cluster_endpoint }
output "eks_cluster_name"      { value = module.eks.cluster_name }
output "rds_endpoint"          { value = module.rds.db_instance_endpoint }
output "redis_endpoint"        { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
output "vpc_id"                { value = module.vpc.vpc_id }
