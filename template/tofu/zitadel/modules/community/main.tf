terraform {
  required_providers {
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 2.0"
    }
  }
}

# One org = the community = the shared identity pool. One person, one
# account, usable across every association.
resource "zitadel_org" "community" {
  name = var.community_name
}

# One project per association.
resource "zitadel_project" "association" {
  for_each = { for a in var.associations : a.name => a }

  org_id                   = zitadel_org.community.id
  name                     = each.key
  project_role_assertion   = true
  project_role_check       = false
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"
}

locals {
  project_roles = flatten([
    for a in var.associations : [
      for r in a.roles : {
        association = a.name
        role        = r
      }
    ]
  ])
}

# Roles per project — asserted into tokens as claims.
resource "zitadel_project_role" "role" {
  for_each = { for pr in local.project_roles : "${pr.association}/${pr.role}" => pr }

  org_id       = zitadel_org.community.id
  project_id   = zitadel_project.association[each.value.association].id
  role_key     = each.value.role
  display_name = each.value.role
}
