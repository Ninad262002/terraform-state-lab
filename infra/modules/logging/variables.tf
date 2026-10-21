variable "bucket_name" {
  description = "S3 bucket ka poora naam"
  type        = string
}

variable "tags" {
  description = "S3 bucket ke liye tags"
  type        = map(string)
  default     = {}
}
