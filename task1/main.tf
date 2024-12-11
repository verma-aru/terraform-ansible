# Choose Region
provider "aws" {
  region = "us-east-1"
}

# Create the organization
resource "aws_organizations_organization" "root" {
  feature_set = "ALL" # Enables all features, including consolidated billing and service control policies
}

# Create an IAM group
resource "aws_iam_group" "no_cli_access_group" {
  name = "no_cli_access_group"
}

# Attach a no_cli_access_policy to deny CLI access to 'no_cli_access_group' group
resource "aws_iam_group_policy" "no_cli_access_policy" {
  group = aws_iam_group.no_cli_access_group.name

  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Deny",
        "Action": [
          "iam:CreateAccessKey",
          "iam:UpdateAccessKey",
          "iam:DeleteAccessKey"
        ],
        "Resource": "*"
      }
    ]
  })
}

# Attach AdministratorAccess or ReadOnlyAccess policy to the 'no_cli_access_group' group
resource "aws_iam_group_policy_attachment" "no_cli_access_group_admin_access" {
  group      = aws_iam_group.no_cli_access_group.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  # policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Create IAM user: prof
resource "aws_iam_user" "prof" {
  name = "prof"
}

# Add 'prof' to the 'no_cli_access_group'
resource "aws_iam_user_group_membership" "prof_group_membership" {
  user = aws_iam_user.prof.name
  groups = [
    aws_iam_group.no_cli_access_group.name
  ]
}
l2
# Create a login profile for the user (console access)
resource "aws_iam_user_login_profile" "prof_login_profile" {
  user                    = aws_iam_user.prof.name
  password_length         = 8                 # Generates a random password
  password_reset_required = true               # Enforce password change on first login
}

# Output the generated password for the 'prof' user
output "prof_password" {
  value       = aws_iam_user_login_profile.prof_login_profile.password
  description = "The generated password for the prof user"
  sensitive   = true
}

# Create VPC
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

# 3 Subnets
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

# Amazon Linux 2 AMI data source
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# EC2 Instance with Apache
resource "aws_instance" "web_server" {
  ami           = data.aws_ami.amazon_linux_2.id
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.subnets[0].id

  vpc_security_group_ids = [aws_security_group.web_sg.id]
  
  # User data script to install and start Apache
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Hello from GORUP 1 of TELE6420 Fall 2024</h1>" > /var/www/html/index.html

              # Add environment variables
              echo "RDS_USERNAME=admin" >> /etc/environment
              echo "RDS_PASSWORD=password123" >> /etc/environment
              echo "RDS_DBNAME=mydb" >> /etc/environment
              echo "RDSHOST_NAME=localhost" >> /etc/environment

              # Reload environment variables
              source /etc/environment
              EOF

  # You might want to add your key pair name here
  # key_name = "your-key-pair-name"

  tags = {
    Name = "ApacheWebServer"
  }
}

# Output the public IP of the instance
output "web_server_public_ip" {
  value = aws_instance.web_server.public_ip
}

# Output the public DNS of the instance
output "web_server_public_dns" {
  value = aws_instance.web_server.public_dns
}

# Security Group for Database - only allowing traffic from web servers
resource "aws_security_group" "db_sg" {
  vpc_id = aws_vpc.main.id
  name   = "DatabaseSecurityGroup"

  # Ingress rule - allow traffic from web servers only
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]  # Only allow traffic from web security group
  }

  # Egress Rules
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "DatabaseSecurityGroup"
  }
}