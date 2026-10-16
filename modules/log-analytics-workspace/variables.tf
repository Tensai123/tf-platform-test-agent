variable "name" {
  description = "Workspace name."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the workspace."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "retention_in_days" {
  description = "How long logs are kept, in days. Azure accepts 30 to 730."
  type        = number
  default     = 30

  validation {
    condition     = var.retention_in_days >= 30 && var.retention_in_days <= 730
    error_message = "Retention must be between 30 and 730 days."
  }
}

variable "daily_quota_gb" {
  description = "Daily ingestion cap in GB. -1 means no cap."
  type        = number
  default     = -1
}

variable "tags" {
  description = "Tags for all resources."
  type        = map(string)
  default     = {}
}
