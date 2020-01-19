# Prometheus Assets S3 Bucket
resource "aws_s3_bucket" "prometheus" {
  bucket_prefix = "prometheus-vgh"
  acl           = "private"

  versioning {
    enabled = true
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule {
    id      = "Remove old versions"
    prefix  = ""
    enabled = true

    noncurrent_version_expiration {
      days = 7
    }
  }

  tags = var.common_tags
}

# Prometheus Instance Security Group
resource "aws_security_group" "prometheus" {
  name        = "Prometheus"
  description = " Prometheus Security Group"
  vpc_id      = module.vpc.vpc_id

  tags = var.common_tags
}

resource "aws_security_group_rule" "prometheus_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  security_group_id = aws_security_group.prometheus.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "prometheus_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = aws_security_group.prometheus.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "prometheus_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.prometheus.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "prometheus_ping" {
  type              = "ingress"
  from_port         = 8
  to_port           = 0
  protocol          = "icmp"
  security_group_id = aws_security_group.prometheus.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "prometheus_self" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.prometheus.id
  source_security_group_id = aws_security_group.prometheus.id
}

resource "aws_security_group_rule" "prometheus_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.prometheus.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# Prometheus Role
resource "aws_iam_role" "prometheus" {
  name               = "prometheus"
  description        = "Prometheus"
  assume_role_policy = data.aws_iam_policy_document.prometheus_trust.json
}

data "aws_iam_policy_document" "prometheus_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "prometheus" {
  name   = "prometheus"
  role   = aws_iam_role.prometheus.name
  policy = data.aws_iam_policy_document.prometheus_role.json
}

data "aws_iam_policy_document" "prometheus_role" {
  statement {
    sid = "AllowScalingOperations"

    actions = [
      "ec2:Describe*",
      "autoscaling:Describe*",
      "autoscaling:EnterStandby",
      "autoscaling:ExitStandby",
      "elasticloadbalancing:ConfigureHealthCheck",
      "elasticloadbalancing:DescribeLoadBalancers",
    ]

    resources = ["*"]
  }

  statement {
    sid = "AllowLogging"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]

    resources = ["arn:aws:logs:*:*:*"]
  }

  statement {
    sid       = "AllowS3ListAllBuckets"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["arn:aws:s3:::*"]
  }

  statement {
    sid     = "AllowS3AccessToAssetsBucket"
    actions = ["*"]

    resources = [
      "arn:aws:s3:::${aws_s3_bucket.prometheus.id}",
      "arn:aws:s3:::${aws_s3_bucket.prometheus.id}/*",
    ]
  }
}

# Prometheus Instance
resource "aws_iam_instance_profile" "prometheus" {
  name = "prometheus"
  role = aws_iam_role.prometheus.name
}

data "aws_ami" "prometheus" {
  most_recent = true
  owners      = ["self"]
  name_regex  = "^Prometheus_.*"

  filter {
    name   = "tag:Group"
    values = ["vgh"]
  }

  filter {
    name   = "tag:Project"
    values = ["vgh"]
  }
}

resource "aws_eip" "prometheus" {
  vpc        = true
  instance   = aws_instance.prometheus.id
  depends_on = [module.vpc]

  tags = merge(
    var.common_tags,
    {
      "Name" = "Prometheus"
    },
  )
}

data "null_data_source" "prometheus" {
  inputs = {
    public_dns = "ec2-${replace(join("", aws_eip.prometheus.*.public_ip), ".", "-")}.${data.aws_region.current.name == "us-east-1" ? "compute-1" : "${data.aws_region.current.name}.compute"}.amazonaws.com"
  }
}

resource "cloudflare_record" "prometheus" {
  zone_id = var.cloudflare_zone_id
  name    = "prometheus"
  value   = data.null_data_source.prometheus.outputs["public_dns"]
  type    = "CNAME"
}

resource "cloudflare_record" "logs" {
  zone_id = var.cloudflare_zone_id
  name    = "logs"
  value   = data.null_data_source.prometheus.outputs["public_dns"]
  type    = "CNAME"
}

resource "aws_instance" "prometheus" {
  instance_type               = "t2.micro"
  ami                         = data.aws_ami.prometheus.id
  subnet_id                   = element(module.vpc.public_subnets, 0)
  vpc_security_group_ids      = [aws_security_group.prometheus.id]
  iam_instance_profile        = aws_iam_instance_profile.prometheus.name
  key_name                    = "vgh"
  associate_public_ip_address = true

  user_data = <<DATA
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Send the log output from this script to user-data.log, syslog, and the console
# From: https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo 'Update APT'
export DEBIAN_FRONTEND=noninteractive
while ! apt-get -y update; do sleep 1; done
sudo apt-get -q -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' --allow-remove-essential upgrade

echo 'Mount EBS'
sudo mkdir -p /data
echo '/dev/xvdg  /data  ext4  defaults,nofail  0  2' | sudo tee -a /etc/fstab
sudo mount -a

echo 'Restore Swarm'
sudo service docker stop
sudo mkdir -p /var/lib/docker/swarm
echo '/data/swarm  /var/lib/docker/swarm  none  defaults,bind  0  2' | sudo tee -a /etc/fstab
sudo mount -a
sudo service docker start

echo 'Reinitialize cluster'
sudo docker swarm init --force-new-cluster --advertise-addr $(curl -s  http://169.254.169.254/latest/meta-data/local-ipv4)

echo 'Restart services'
sudo service docker restart

echo "FINISHED @ $(date "+%m-%d-%Y %T")" | sudo tee /var/lib/cloud/instance/deployed
DATA


  tags = merge(
    var.common_tags,
    {
      "Name" = "Prometheus"
    },
  )
}

resource "aws_ebs_volume" "prometheus_data" {
  availability_zone = "us-east-1a"
  type              = "gp2"
  snapshot_id       = "snap-0f19073579f63ba93"
  encrypted         = true

  tags = merge(
    var.common_tags,
    {
      "Name"     = "Prometheus Data"
      "Snapshot" = "true"
    },
  )
}

resource "aws_volume_attachment" "prometheus_data_attachment" {
  device_name  = "/dev/sdg"
  instance_id  = aws_instance.prometheus.id
  volume_id    = aws_ebs_volume.prometheus_data.id
  skip_destroy = true
}
