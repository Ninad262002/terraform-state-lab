

#Bucket ka naam globally unique hona chahiye, isliye random_id ka use kiya hai
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "demo" {
  bucket = "tfstate-lab-demo-${random_id.suffix.hex}"

  tags = {
    Project   = "terraform-state-lab"
    ManagedBy = "Terraform"
    Owner     = "ninad"
  }
}

resource "aws_s3_bucket" "rescued" {
  bucket = "tfstate-lab-practice-b299d01e"
  tags = {
    Project   = "terraform-state-lab"
    ManagedBy = "terraform"
  }
}

import {
  to = aws_s3_bucket.rescued
  id = "tfstate-lab-practice-b299d01e"
}


resource "aws_s3_bucket" "drift_test" {
  bucket = "tfstate-lab-drift-${random_id.suffix.hex}"

  tags = {
    Project     = "terraform-state-lab"
    ManagedBy   = "terraform"
    Environment = "dev"
  }
}