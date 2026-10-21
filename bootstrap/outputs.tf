output "state_bucket_name" {
  description = "Backend bucket ka naam (Task 1.3 mein use hoga)"
  value       = aws_s3_bucket.tfstate.id
}

output "github_plan_role_arn" {
  description = "Workflow mein use hoga (Task 4.3)"
  value       = aws_iam_role.github_plan.arn
}