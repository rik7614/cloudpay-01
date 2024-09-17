provider "aws" {
  region = "us-east-1"
}

# VPC
resource "aws_vpc" "app_vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "AppVPC"
  }
}

# Subnets
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.app_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "PublicSubnet"
  }
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.app_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
  tags = {
    Name = "PrivateSubnet"
  }
}

#additional public subnet
resource "aws_subnet" "another_public_subnet" {
  vpc_id            = aws_vpc.app_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1c"  # Different AZ
  tags = {
    Name = "AnotherPublicSubnet"
  }
}

#additional subnet for RDS private 
resource "aws_subnet" "another_private_subnet" {
  vpc_id            = aws_vpc.app_vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "us-east-1c"  # Different AZ
  tags = {
    Name = "AnotherPrivateSubnet"
  }
}

#adding internet gateway to the VPC
resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.app_vpc.id

  tags = {
    Name = "AppInternetGateway"
  }
}


# Security Groups
resource "aws_security_group" "web_sg" {
  vpc_id = aws_vpc.app_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

    ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "WebServiceSG"
  }
}

resource "aws_security_group" "lb_sg" {
  vpc_id = aws_vpc.app_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "LoadBalancerSG"
  }
}


#adding network ACL config
resource "aws_network_acl" "web_acl" {
  vpc_id = aws_vpc.app_vpc.id

  tags = {
    Name = "WebNetworkACL"
  }
}

resource "aws_network_acl_rule" "ingress_http" {
  network_acl_id = aws_network_acl.web_acl.id
  rule_number     = 100
  egress          = false
  protocol        = "tcp"
  rule_action     = "allow"
  cidr_block      = "0.0.0.0/0"
  from_port       = 80
  to_port         = 80
}

resource "aws_network_acl_rule" "egress_all" {
  network_acl_id = aws_network_acl.web_acl.id
  rule_number     = 100
  egress          = true
  protocol        = "-1"
  rule_action     = "allow"
  cidr_block      = "0.0.0.0/0"
}


#route table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.app_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gateway.id
  }

  tags = {
    Name = "PublicRouteTable"
  }
}

resource "aws_route_table_association" "public_subnet_association" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}



#S3 Bucket for state file
resource "aws_s3_bucket" "terraform_state" {
  bucket = "my-terraform-state-bucket-cloudpay"
  acl    = "private"

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

  tags = {
    Name = "TerraformStateBucket"
  }
}
#DynamoDB table for state locking
resource "aws_dynamodb_table" "terraform_state_lock" {
  name         = "terraform-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name = "TerraformStateLockTable"
  }
}

# Elastic IP
resource "aws_eip" "web_eip" {
  instance = aws_instance.web_instance.id
  tags = {
    Name = "WebInstanceEIP"
  }
}

# EC2 Instance
resource "aws_instance" "web_instance" {
  ami           = "ami-0ebfd941bbafe70c6"
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]  # Update here
  tags = {
    Name = "WebServiceInstance"
  }
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "Hello, Terraform!" > /var/www/html/index.html
            EOF
}


# Launch Configuration
resource "aws_launch_configuration" "web_lc" {
  name          = "web-lc"
  image_id      = "ami-0ebfd941bbafe70c6"
  instance_type = "t3.micro"
  security_groups = [aws_security_group.web_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "Hello from ASG!" > /var/www/html/index.html
            EOF

  lifecycle {
    create_before_destroy = true
  }
}


# Auto Scaling Group
resource "aws_autoscaling_group" "web_asg" {
  desired_capacity     = 2
  max_size             = 3
  min_size             = 1
  vpc_zone_identifier  = [aws_subnet.public_subnet.id]
  launch_configuration = aws_launch_configuration.web_lc.id
  target_group_arns = [aws_lb_target_group.app_tg.arn]
  tag {
    key                 = "Name"
    value               = "WebInstance"
    propagate_at_launch = true
  }
}

# Load Balancer
resource "aws_lb" "app_lb" {
  name               = "app-load-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = [
    aws_subnet.public_subnet.id,
    aws_subnet.another_public_subnet.id   # Add another subnet in a different AZ
  ]
  tags = {
    Name = "AppLoadBalancer"
  }
}


resource "aws_lb_target_group" "app_tg" {
  name     = "app-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.app_vpc.id
  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
  }
  tags = {
    Name = "AppTargetGroup"
  }
}

resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# RDS
resource "aws_db_instance" "app_db" {
  engine            = "mysql"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  db_name           = "appdb"
  username          = "admin"
  password          = "password"
  multi_az          = true
  backup_retention_period = 7
  vpc_security_group_ids  = [aws_security_group.web_sg.id]
  db_subnet_group_name     = aws_db_subnet_group.db_subnet_group.name
  skip_final_snapshot     = false # changed from false to true to skip the final snapshot

  tags = {
    Name = "AppDatabase"
  }
}


resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "rds-subnet-group"
  subnet_ids = [
    aws_subnet.private_subnet.id,
    aws_subnet.another_private_subnet.id   # Add another subnet in a different AZ
  ]
  tags = {
    Name = "RDSSubnetGroup"
  }
}


# CloudWatch Alarm
resource "aws_cloudwatch_metric_alarm" "high_cpu_alarm" {
  alarm_name          = "HighCPUUsage"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "60"
  statistic           = "Average"
  threshold           = "75"
  alarm_actions       = [aws_sns_topic.alarm_topic.arn]
  dimensions = {
    InstanceId = aws_instance.web_instance.id
  }
  tags = {
    Name = "HighCPUAlarm"
  }
}

# SNS Topic
resource "aws_sns_topic" "alarm_topic" {
  name = "alarm-topic"
  tags = {
    Name = "AlarmTopic"
  }
}

# Outputs
output "web_url" {
  value = aws_instance.web_instance.public_dns
}

output "s3_bucket_name" {
  value = aws_s3_bucket.terraform_state.bucket
}
