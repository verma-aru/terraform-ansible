# Part 2 Solution using Terraform and Ansible
provider "aws" {
  region = "us-east-1"
}

# CREATING VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "MainVPC"
  }
}
# Data Source for Availability Zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Subnets
resource "aws_subnet" "subnets" {
  count = 3  # Create 3 subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)  # Dynamic CIDR blocks
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "Subnet-${count.index + 1}"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "MainInternetGateway"
  }
}
# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"  # Route for all internet traffic
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "PublicRouteTable"
  }
}

# Associate Route Table with Subnets
resource "aws_route_table_association" "subnet1" {
  subnet_id      = aws_subnet.subnets[0].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "subnet2" {
  subnet_id      = aws_subnet.subnets[1].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "subnet3" {
  subnet_id      = aws_subnet.subnets[2].id
  route_table_id = aws_route_table.public.id
}

# Security Group for Web Servers
resource "aws_security_group" "web_sg" {
  vpc_id = aws_vpc.main.id
  name   = "WebSecurityGroup"

  # Ingress Rules (Inbound Traffic)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Allow SSH from anywhere
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Allow HTTP from anywhere
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Allow HTTPS from anywhere
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Allow custom app traffic on port 8080
  }

  # Egress Rules (Outbound Traffic)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]  # Allow all outbound traffic
  }

  tags = {
    Name = "WebSecurityGroup"
  }
}

# Code to create custom AMI with required packages using Ansible script
resource "null_resource" "ansible_provisioner" {
  depends_on = [aws_security_group.web_sg, aws_subnet.subnets]

  provisioner "local-exec" {
    environment = {
      TF_VAR_vpc_id           = aws_vpc.main.id
      TF_VAR_subnet_id        = aws_subnet.subnets[0].id
      TF_VAR_security_group_id = aws_security_group.web_sg.id
    }
    
    command = "ansible-playbook playbook-ami.yaml"
  }
}

# Data source to get the AMI created by Ansible
data "aws_ami" "custom_ami" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = ["Tele6420-AMI"]
  }

  depends_on = [null_resource.ansible_provisioner]
}

# Launch Template
resource "aws_launch_template" "web_template" {
  name_prefix   = "web-template"
  image_id      = data.aws_ami.custom_ami.id
  instance_type = "t2.micro"

  vpc_security_group_ids = [aws_security_group.web_sg.id]

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "WebServer-ASG"
    }
  }

  depends_on = [data.aws_ami.custom_ami]
}

# Auto Scaling Group
resource "aws_autoscaling_group" "web_asg" {
  name                = "web-asg"
  desired_capacity    = 1
  max_size           = 3
  min_size           = 1
  vpc_zone_identifier = [aws_subnet.subnets[0].id, aws_subnet.subnets[1].id, aws_subnet.subnets[2].id]

  launch_template {
    id      = aws_launch_template.web_template.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "WebServer-ASG"
    propagate_at_launch = true
  }
}

# Scale Up Policy
resource "aws_autoscaling_policy" "scale_up" {
  name                   = "web-scale-up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown              = 10
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
}

# Scale Down Policy
resource "aws_autoscaling_policy" "scale_down" {
  name                   = "web-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown              = 10
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
}

# CloudWatch Alarm - High CPU
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "high-cpu-usage"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2      # Number of consecutive periods
  metric_name         = "CPUUtilization"
  namespace          = "AWS/EC2"
  period             = 10     # 60 seconds = 1 minute
  statistic          = "Average"
  threshold          = 70

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web_asg.name
  }

  alarm_description = "Scale up if CPU > 70% for 2 minutes"
  alarm_actions     = [aws_autoscaling_policy.scale_up.arn]
}

# CloudWatch Alarm - Low CPU
resource "aws_cloudwatch_metric_alarm" "low_cpu" {
  alarm_name          = "low-cpu-usage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2      # Number of consecutive periods
  metric_name         = "CPUUtilization"
  namespace          = "AWS/EC2"
  period             = 10     # 60 seconds = 1 minute
  statistic          = "Average"
  threshold          = 40

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web_asg.name
  }

  alarm_description = "Scale down if CPU < 40% for 2 minutes"
  alarm_actions     = [aws_autoscaling_policy.scale_down.arn]
}

# Output for Auto Scaling Group Name
output "asg_name" {
  value = aws_autoscaling_group.web_asg.name
  description = "The name of the Auto Scaling Group"
}