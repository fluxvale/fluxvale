# The custom domain lives in its own file, with its output: pre-#548
# validation (the resource isn't in main yet) drops this whole file —
# the scratch-copy seam is one rm, not an edit.

resource "fluxvale_custom_domain" "personal" {
  domain = var.custom_domain

  # Wait out verification: DNS-01 against your DNS delegation, promoted
  # pending → verified by the platform's ~15-minute observer cadence
  # (timeouts.create bounds the wait). VERIFIED IS NOT RESOLUTION — a
  # verified domain still answers nothing on the tailnet; the split-DNS
  # claim has no API surface yet. See this example's README.
  wait_for_verification = true

  timeouts {
    create = "45m"
  }
}

variable "custom_domain" {
  description = "The domain to register on the private-access edge (e.g. apps.example.com) — canonicalized server-side (trim + downcase)."
  type        = string
}

output "domain_state" {
  description = "The custom domain's verification state. verified = issuance, NOT resolution — see the README."
  value       = fluxvale_custom_domain.personal.state
}
