variable "community_name" {
  type        = string
  description = "Name of the community — becomes the ZITADEL organization (the shared identity pool)."
}

variable "associations" {
  type = list(object({
    name  = string
    roles = list(string)
  }))
  description = <<-EOT
    Clubs / subgroups. Each becomes a ZITADEL project with the listed roles.
    Roles end up as claims in tokens; apps authorize on them.
    Keep the structure flat — ZITADEL has no nested groups. Deeper structures
    are modeled as role conventions ("football:board"), not trees.
  EOT
}
