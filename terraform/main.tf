terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

#  Variables 

variable "aws_region" {
  description = "AWS region"
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name (used for tagging)"
}

variable "public_key" {
  description = "SSH public key for EC2 key pair"
}

variable "instance_type" {
  description = "EC2 instance type"
  default     = "t3.micro"
}

#  Key Pair 

resource "aws_key_pair" "app" {
  key_name   = "${var.project_name}-keypair"
  public_key = var.public_key
}

#  VPC 

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

#  Subnets 

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true

  depends_on = [aws_vpc.main]

  tags = {
    Name    = "${var.project_name}-public-subnet"
    Project = var.project_name
  }
}

resource "aws_subnet" "private_subnet" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = false

  depends_on = [aws_vpc.main]

  tags = {
    Name    = "${var.project_name}-private-subnet"
    Project = var.project_name
  }
}

#  Internet Gateway 

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

#  Public Route Table 

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name    = "${var.project_name}-public-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public.id
}

#  NAT Gateway 

resource "aws_eip" "nat_eip" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name    = "${var.project_name}-nat-eip"
    Project = var.project_name
  }
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id

  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name    = "${var.project_name}-nat-gw"
    Project = var.project_name
  }
}

#  Private Route Table 

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }

  depends_on = [aws_nat_gateway.nat_gw]

  tags = {
    Name    = "${var.project_name}-private-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private.id
}

#  Security Groups 

resource "aws_security_group" "alb_sg" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP inbound to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
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
    Name    = "${var.project_name}-alb-sg"
    Project = var.project_name
  }
}

resource "aws_security_group" "app_sg" {
  name        = "${var.project_name}-app-sg"
  description = "Allow traffic from ALB to app instance"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-app-sg"
    Project = var.project_name
  }
}

# Break the SG cycle with a standalone rule: ALB -> app on port 80
resource "aws_security_group_rule" "app_ingress_from_alb_http" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app_sg.id
  source_security_group_id = aws_security_group.alb_sg.id
  description              = "HTTP from ALB"
}

# Allow SSH from anywhere (needed for Ansible via bastion or direct - private subnet only reachable via SSM or bastion)
resource "aws_security_group_rule" "app_ingress_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  security_group_id = aws_security_group.app_sg.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "SSH for Ansible (via SSH proxy through NAT)"
}

#  EC2 Instance 

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private_subnet.id
  associate_public_ip_address = false
  key_name                    = aws_key_pair.app.key_name
  vpc_security_group_ids      = [aws_security_group.app_sg.id]

  tags = {
    Name    = "${var.project_name}-app"
    Project = var.project_name
  }
}

#  Target Group 

resource "aws_lb_target_group" "app_tg" {
  name        = "${var.project_name}-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name    = "${var.project_name}-tg"
    Project = var.project_name
  }
}

#  ALB 

resource "aws_lb" "alb" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_subnet.id]

  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name    = "${var.project_name}-alb"
    Project = var.project_name
  }
}

#  ALB Listener 

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }

  depends_on = [aws_lb_target_group.app_tg]
}

#  Target Group Attachment 

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app_tg.arn
  target_id        = aws_instance.app.id
  port             = 80
}

#  Outputs 

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.alb.dns_name
}

output "instance_private_ip" {
  description = "Private IP of the EC2 instance"
  value       = aws_instance.app.private_ip
}

output "app_url" {
  description = "Public URL of the application"
  value       = "http://${aws_lb.alb.dns_name}"
}