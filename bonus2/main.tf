# Provider configuration for AWS
provider "aws" {
    region = "us-east-1"  # Specifies the AWS region
}

# Fetches available availability zones in the selected region
data "aws_availability_zones" "available" {}

# Creates a Virtual Private Cloud (VPC) with a specified CIDR block
resource "aws_vpc" "main" {
    cidr_block           = "10.0.0.0/16"  # IP range for the VPC
    enable_dns_support   = true           # Enables DNS resolution
    enable_dns_hostnames = true           # Enables DNS hostnames

    tags = {
        Name = "MainVPC"  # Tag for easy identification
    }
}

# Creates subnets within the VPC, one in each availability zone
resource "aws_subnet" "subnets" {
    count = 3  # Creates three subnets

    vpc_id                  = aws_vpc.main.id  # Links to the main VPC
    cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 4, count.index)  # Subnet IP range
    availability_zone       = data.aws_availability_zones.available.names[count.index]  # Maps to AZ
    map_public_ip_on_launch = true  # Assigns public IPs to instances launched in the subnet

    tags = {
        Name = "Subnet-${count.index}"  # Tag each subnet uniquely
    }
}

# Creates an Internet Gateway (IGW) for internet access
resource "aws_internet_gateway" "igw" {
    vpc_id = aws_vpc.main.id  # Associates IGW with the VPC

    tags = {
        Name = "MainIGW"  # Tag for identification
    }
}

# Configures a public route table for the VPC
resource "aws_route_table" "public" {
    vpc_id = aws_vpc.main.id  # Links to the VPC

    # Adds a route to send traffic to the IGW
    route {
        cidr_block = "0.0.0.0/0"  # Route all traffic
        gateway_id = aws_internet_gateway.igw.id
    }

    tags = {
        Name = "PublicRouteTable"  # Tag for identification
    }
}

# Associates each subnet with the public route table
resource "aws_route_table_association" "subnet_associations" {
    count          = length(aws_subnet.subnets)  # Number of associations matches the number of subnets
    subnet_id      = aws_subnet.subnets[count.index].id
    route_table_id = aws_route_table.public.id
}

# Creates a security group for web servers
resource "aws_security_group" "web_sg" {
    vpc_id = aws_vpc.main.id  # Links to the VPC

    # Allow SSH access
    ingress {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    # Allow HTTP access
    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    # Allow HTTPS access
    ingress {
        from_port   = 443
        to_port     = 443
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    # Allow custom port 8080
    ingress {
        from_port   = 8080
        to_port     = 8080
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    # Allow all outbound traffic
    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
        Name = "WebSecurityGroup"  # Tag for identification
    }
}

# Fetches the latest Amazon Linux 2 AMI
data "aws_ami" "amazon_linux" {
    most_recent = true  # Fetches the most recent AMI
    owners      = ["amazon"]  # Owned by Amazon

    filter {
        name   = "name"
        values = ["amzn2-ami-hvm-2.*-x86_64-gp2"]  # Filters by AMI name pattern
    }
}

# Creates a launch template for EC2 instances
resource "aws_launch_template" "app_template" {
    name_prefix   = "app-launch-template"  # Template prefix
    image_id      = data.aws_ami.amazon_linux.id  # Amazon Linux 2 AMI ID
    instance_type = "t2.micro"  # Instance type

    # User data to configure the instance on startup
    user_data = base64encode(<<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Hello from GROUP 1 of TELE6420 Fall 2024</h1>" > /var/www/html/index.html
              EOF
    )

    network_interfaces {
        associate_public_ip_address = true  # Assigns a public IP
        security_groups             = [aws_security_group.web_sg.id]  # Applies the web security group
    }

    tags = {
        Name = "AppLaunchTemplate"  # Tag for identification
    }
}

# Creates an Auto Scaling Group to manage EC2 instances
resource "aws_autoscaling_group" "app_asg" {
    launch_template {
        id      = aws_launch_template.app_template.id
        version = "$Latest"  # Uses the latest version of the launch template
    }

    vpc_zone_identifier = aws_subnet.subnets[*].id  # Subnets for the ASG instances
    min_size            = 1
    max_size            = 3
    desired_capacity    = 2

    # Registers instances with the ALB target group
    target_group_arns = [aws_lb_target_group.app_tg.arn]

    tag {
        key                 = "Name"
        value               = "AutoScalingGroupInstance"  # Tag for instances
        propagate_at_launch = true
    }
}

# Creates an Application Load Balancer (ALB)
resource "aws_lb" "app_alb" {
    name               = "app-alb"
    internal           = false  # Externally accessible
    load_balancer_type = "application"  # ALB type
    security_groups    = [aws_security_group.web_sg.id]  # Associated security group
    subnets            = aws_subnet.subnets[*].id  # ALB spans all subnets

    tags = {
        Name = "AppLoadBalancer"  # Tag for identification
    }
}

# Creates a target group for the ALB
resource "aws_lb_target_group" "app_tg" {
    name     = "app-target-group"
    port     = 80  # Listens on port 80
    protocol = "HTTP"
    vpc_id   = aws_vpc.main.id  # Target group is part of the main VPC

    # Health check configuration
    health_check {
        path                = "/"  # Health check path
        interval            = 30  # Interval between checks
        timeout             = 5   # Timeout for response
        healthy_threshold   = 2   # Threshold for healthy status
        unhealthy_threshold = 2   # Threshold for unhealthy status
        matcher             = "200"  # Expected status code
    }
}

# Configures a listener for the ALB
resource "aws_lb_listener" "app_listener" {
    load_balancer_arn = aws_lb.app_alb.arn  # Links to the ALB
    port              = 80  # Listens on port 80
    protocol          = "HTTP"

    # Forwards traffic to the target group
    default_action {
        type             = "forward"
        target_group_arn = aws_lb_target_group.app_tg.arn
    }
}

# Outputs the ALB DNS name
output "alb_dns_name" {
    value = aws_lb.app_alb.dns_name
}
