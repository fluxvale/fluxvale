# ADR-00022: Talos Linux — the OS *is* the cluster; Ansible exits

**Status**: Accepted (amended — see Amendment 1)
**Date**: 2026-09-01

**Context**: the v2 charter is "do it right, then go faster than ever." A
provisioning audit (Ansible as right-sized OS bootstrapper vs bash, OpenTofu,
NixOS, Talos) surfaced that v1's original goal was always *provision a k8s
cluster, then do everything through Kubernetes/Flux* — and Talos is the
purpose-built expression of exactly that: an immutable, minimal, API-managed
node OS. No shell, no SSH, no sshd/fail2ban/ufw hardening domain at all; the
node's entire identity is a declarative machine config; upgrades and joins
are API operations.

**Pre-adoption verification (2026-09-01, against the actual NetCup SCP)**:
RS 2000 G12 is KVM-virtualized with VIRTIO disks; the SCP's **DVD Drive tab
natively supports custom ISO upload** (ISO files officially supported;
drag-drop or generated curl URL; auto-delete after 48h — ideal install
media); a `Screen` noVNC console exists; an SCP API exists for future
automation. Server data is disposable (pre-launch). No blockers.

**Decision**:

1. **Talos Linux replaces Debian + k3s + Ansible.** Talos runs upstream
   Kubernetes (amends [ADR-00004](00004-bare-metal-netcup-k3s.md)); the
   bare-metal/Netcup/reject-managed-k8s reasoning there is untouched.
2. **Machine configs**: patches live in the fleet repo (`talos/`); full
   configs, `talosconfig`, and cluster PKI are **values → Bitwarden**
   (references-vs-values rule, [ADR-00018](00018-repo-visibility.md)).
3. **Bootstrap/DR runbook**: SCP → custom ISO upload
   (stock `metal-amd64.iso` from the Talos release — hybrid BIOS/UEFI;
   `metal-amd64.raw.zst` is the dd-fallback artifact (`zstd -d` first),
   `sha256sum.txt` verifies; UKI/SecureBoot/cloud/nocloud variants not used;
   `talosctl` version always matches the node. Note: GitHub's UI truncates
   the asset list — the files are all there; expand it) → reboot →
   Talos maintenance mode → `talosctl apply-config --insecure
   --cert-fingerprint <fp>` from the laptop (TCP 50000). The fingerprint is
   displayed on the node console (`Screen` tab) — passing it authenticates
   the *node* even though maintenance mode's TLS cert is self-signed;
   `--insecure` alone skips verification and invites MITM impersonation.
   Defense in depth: also restrict TCP 50000 to your workstation IP via the
   SCP Firewall tab during the install window. Once config is applied the
   API requires mTLS, closing the window entirely. → **wait for node readiness**: apply-config
   triggers install-to-disk + reboot; poll the now-mTLS-authenticated API
   (`talosctl status` / `talosctl health`) until the node reports ready —
   never bootstrap a node that hasn't come back → `talosctl bootstrap`
   (etcd + control-plane init) → wait for k8s API readiness
   (`talosctl health --k8s`) → `talosctl kubeconfig` → `flux bootstrap` →
   apply BWS-operator token
   Secrets (tiny script) → (DR: restore DB from R2). Fallback if the ISO
   path ever disappears: Rescue System → `dd` the Talos metal image → same
   apply-config flow.
4. **Fleet repo deltas vs the k3s plan**: Traefik becomes a plain
   HelmRelease (no bundled instance to fight); local-path-provisioner is a
   chart (CNPG storage class); wireguard flannel is a machine-config patch.
   The `ansible/` directory does not exist.
5. **First install happens on the box itself** — pre-launch there is no
   production data to save, so no rehearsal server is bought
   ([ADR-00016](00016-deferred-triggers.md) discipline: no second box until
   it is a happy problem). Optional zero-cost fluency run beforehand:
   `talosctl cluster create` (QEMU VMs) locally.

**Translations (mechanics superseded by this ADR)**:

| Old (k3s/Ansible) | Talos |
|---|---|
| Ansible roles: ssh/ufw/fail2ban/k3s/k3s_prereqs | do not exist (no SSH; ingress firewall is machine-config rules) |
| `k3s agent` join, node tokens | boot worker ISO + apply worker config; joins via API |
| Control-plane HA: 3 k3s server nodes | 3 control-plane machine configs; Talos rolls control-plane upgrades itself |
| k3s version pin via install script | k8s version is a machine-config field |
| fnox bootstraps BWS tokens via Ansible role | a small script applies the two Secrets post-bootstrap (amends [ADR-00021](00021-secrets-bws-operator.md)) |

**Consequences**: debugging is `talosctl logs/dmesg/health` — no SSH ever;
Netcup's rescue mode is the break-glass layer. Single control plane remains
the same SPOF single-node k3s was (unchanged until the HA trigger). Local
dev: k3d drift note added to [ADR-00020](00020-local-dev-parity.md). Salvage
map: the 5 Ansible roles and their traps move to leave-behind.

**Omni — deferred, not adopted** ([ADR-00016](00016-deferred-triggers.md)
trigger added): Sidero's fleet manager (machine enrollment, cluster
lifecycle, etcd backups, UI/`omnictl`) is the right tool from the
second-cluster / sustained-multi-node era. At one box it would be another
stateful service (self-hosted) or third-party holding cluster-control state
(hosted), covering chores our fleet repo + `talosctl` already do
declaratively. Evaluate hosted first when the trigger fires; the demoted box
([ADR-00006](00006-single-cluster-multi-region-ready.md)) is the natural
self-hosted home.
