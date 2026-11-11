# Every value the owner supplies, in one file. Required variables
# carry no default on purpose: `tofu plan` with nothing filled in
# errors on exactly them — that error list IS the pairing checklist
# (README.md has the where-to-mint column). Choices with a sensible
# default (the instances, the bucket name) are overridable from
# terraform.tfvars.

variable "api_url" {
  description = "FluxVale API base URL. Production by default; point at staging to rehearse."
  type        = string
  default     = "https://fluxvale.com"
}

variable "fluxvale_pat" {
  description = "FluxVale PAT (fvpat_…). Leave null and export FLUXVALE_PAT — the token never belongs in a file."
  type        = string
  sensitive   = true
  default     = null
}

# ── Cloudflare / R2 ──────────────────────────────────────────────────────

variable "cloudflare_api_token" {
  description = "Cloudflare API token with R2 edit on the account (creates the backups bucket)."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account id — also composes the R2 S3 endpoint in main.tf."
  type        = string
}

variable "r2_bucket_name" {
  description = "The R2 bucket every instance's backups land in (per-instance prefixes keep them apart)."
  type        = string
  default     = "fluxvale-backups"
}

variable "r2_access_key_id" {
  description = "R2 access key id — an account-level R2 token's credential, minted in the Cloudflare dashboard (no TF resource manages it)."
  type        = string
}

variable "r2_secret_access_key" {
  description = "R2 secret access key — write-only to the platform API (set means rotated with each save)."
  type        = string
  sensitive   = true
}

# ── Tailscale ────────────────────────────────────────────────────────────

variable "tailnet_domain" {
  description = "The tailnet's MagicDNS suffix (<tailnet>.ts.net) — the Tailscale admin console shows it on every device name."
  type        = string
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key the gateway joins the tailnet with (write-only; required to enable the gateway)."
  type        = string
  sensitive   = true
}

# ── The stack itself ─────────────────────────────────────────────────────

variable "instances" {
  description = <<-EOT
    The instances, keyed by instance name (the key is the name and the backups prefix). Defaults are three representative shapes: a public always-on forgejo, memos and kavita private behind the gateway. Override the whole map in terraform.tfvars to differ.
    version: null tracks the catalog's newest; pin a string to freeze it. A version change replaces the instance (create-only identity).
    retention_keep: days of backups per instance; null is the server's default.
  EOT
  type = map(object({
    app            = string
    version        = optional(string)
    cpu_cores      = number
    memory_mb      = number
    storage_gb     = number
    exposure       = string
    always_on      = bool
    running        = bool
    retention_keep = optional(number)
  }))
  default = {
    forgejo = { app = "forgejo", version = null, cpu_cores = 1.0, memory_mb = 1024, storage_gb = 5, exposure = "public", always_on = true, running = true, retention_keep = 14 }
    memos   = { app = "memos", version = null, cpu_cores = 0.25, memory_mb = 512, storage_gb = 5, exposure = "private", always_on = false, running = true, retention_keep = null }
    kavita  = { app = "kavita", version = null, cpu_cores = 0.5, memory_mb = 512, storage_gb = 10, exposure = "private", always_on = false, running = true, retention_keep = null }
  }
  validation {
    condition     = alltrue([for k, v in var.instances : contains(["public", "private"], v.exposure)])
    error_message = "Each instance's exposure must be public or private."
  }
}
