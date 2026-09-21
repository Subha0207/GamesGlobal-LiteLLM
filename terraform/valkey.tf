resource "aws_security_group" "valkey" {
  name        = "${var.name}-valkey"
  description = "Valkey access from the EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Valkey from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_elasticache_subnet_group" "valkey" {
  name       = "${var.name}-valkey"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id = "${var.name}-valkey"
  description          = "Valkey cache + router state for LiteLLM"

  engine         = "valkey"
  engine_version = var.valkey_version
  node_type      = var.valkey_node_type
  port           = 6379

  # POC: single node, no failover. For production use at least 2 nodes with
  # automatic_failover_enabled = true and multi_az_enabled = true.
  num_cache_clusters         = 1
  automatic_failover_enabled = false

  parameter_group_name = "default.valkey7"
  subnet_group_name    = aws_elasticache_subnet_group.valkey.name
  security_group_ids   = [aws_security_group.valkey.id]

  at_rest_encryption_enabled = true

  # Transit encryption is off so LiteLLM connects with a plain redis:// URL.
  # The cluster is only reachable from the node security group. To enable TLS,
  # set transit_encryption_enabled = true here and REDIS_SSL="True" on the pods.
  transit_encryption_enabled = false

  apply_immediately = true
}
