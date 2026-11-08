# Plan: private access v1 — the remaining slices (#273)

Status: **APPROVED — PA gate, Nov 9 2026.** All decisions D1–D10 settled as recommended; the four riders are recorded in §8. Slices fan out per §6.
Evidence base: issue #273, [ADR-0039](../adr/00039-private-access-layer-tailscale.md) (including Amendments 2 and 3), the merged slices #269–#311, the fleet repo's `access/staging` manifests (infra#105/#136), and live probes of the local k3d cluster at app HEAD `badd3534`.
Issue: fluxvale/fluxvale#273. Parent: #268 (closed by slice 2, exit criteria carried here).

## 1. What actually remains — the issue text is stale

The issue lists three unbuilt items. Two of them are built and merged; the fleet item is built for staging and missing only locally and in production. This plan does not rebuild shipped work; it closes the real gaps and proves the exit criteria.

| Scope item | Shipped | What is genuinely left |
|---|---|---|
| Wake intercept | [PR #301](https://github.com/fluxvale/fluxvale/pull/301), `a6fe38b`; flag ships `true` at `config/config.exs:225`; controller at `/internal/access/:gateway_id/:instance_id/*path` | Nothing in code. Prove it locally in halves; the real tailnet leg is the staging proof. |
| Panel | [PR #300](https://github.com/fluxvale/fluxvale/pull/300), `c361b7b` (core) + [PR #311](https://github.com/fluxvale/fluxvale/pull/311), `73264f4` (attach/detach + instance page) | Nothing. Opt-in, Running/NeedsAttention + re-paste, per-instance attach/detach and the write-only key intake all exist with 53 LiveView tests. |
| Fleet | infra [#105](https://github.com/fluxvale/infrastructure/pull/105), `60f3a8f` — staging namespace, PSA baseline, quota, platform Role/RoleBinding | Local `deploy/local/` has the namespace and an older Role that grants only `pods list` + `configmaps create/patch`; no gateway Deployment/Secret/PVC verbs, no quota, no PSA labels. Production is deliberately unbound (fleet comment), pending the per-env decision. |
| P3 C1 namespace resolver | #307, `9f3b3dd` — one `InstanceK8s.gateway_access_namespace/0`, eager resolve before writes | Verify and close. |
| P3 C2 teardown 404 | #306, `20fa6c2` — a 404 on disadmit reads `:ok` | Verify and close. |
| P3 C3 policy spec types | #305, `9da3d99` — union type describes both real shapes | Verify and close. |
| P3 C4 observer churn | **Not fixed** — `ObserveAccessGateway` still writes and broadcasts every minute for an unchanged `:active` row | Fix in this work (slice S1). |
| Exit criteria | Neither proven end-to-end on a real tailnet | Split: local proofs tonight; the staging tailnet transcript needs Terence. |

The issue's "refused-backend detection" phrasing is also stale: [ADR-0039 Amendment 2](../adr/00039-private-access-layer-tailscale.md) records why the shipped shape is status-driven (while asleep the serve target *is* the platform, so there is no refusal to detect; a running-but-dead app's 502 is correct and must not wake anything).

## 2. Ground truth verified at `badd3534` (probed, not assumed)

- `apps/platform/lib/flux_vale_web/live/org_live/access.ex` is 2,046 lines with routes at `router.ex:403` (org) and `:433` (personal); `test/.../org_live/access_test.exs` carries 53 tests including every state, key non-echo, broadcast, attach/detach and re-paste arm.
- `serve_config.ex` builds the asleep target only when `wake_intercept_enabled` is true; the shipped config is true. `access_wake_controller_test.exs` has 30+ tests covering the pair gate, wake, flip, debounce, probes and byte-identical 404s.
- `ObserveAccessGateway.apply_status/3` has no quiet arm for `:active`; its own test asserts "one write, then no-op" without counting writes, so the churn is invisible to today's suite.
- Local k3d (`k3d-fluxvale`) is up: platform and CNPG pods Running. `kubectl auth can-i` for `system:serviceaccount:fluxvale-dev:fluxvale-platform` in `fluxvale-access` returns **no** for `create/get/patch/delete` on Deployments, Secrets and PVCs. The namespace has no PSA labels, no ResourceQuota, no Role or RoleBinding.
- The fleet repo has `access/staging/{namespace,resourcequota,role,rolebinding}.yaml` wired by `cluster/access.yaml`; there is no `access/production/`. The staging RoleBinding intentionally binds only `fluxvale-staging`, because the app resolves one namespace name in every env.
- The app toolchain is present (`Elixir 1.20.4 / OTP 29`); this fresh worktree has no `deps`/`_build` yet.

## 3. Slices

### S0 / S1 — Fix-first: the carried P3s (C4 is the only open one)

One code change: make the observer quiet when the observed state already matches the committed row, without reintroducing the stale-record bug.

- Re-read the row at the top of the observation decision, then return the fresh row with **no write and no broadcast** when it is `:active`, `needs_attention_since` is nil, `metering_since` and `provisioned_at` are set, and `status_message` already equals the settled copy.
- Every real transition keeps the existing `expected_state` filter; a concurrent suspend still wins (the filter refuses the write and the retry re-decides).
- A skipped write cannot clobber a concurrent writer, which is what makes the quiet arm safe — the old shortcut's bug was deciding from a stale struct with no comparison to the committed row, not the absence of a write itself.
- Verify C1/C2/C3 by re-running their named suites at HEAD and recording the result in the PR body. No code changes there.

*Done when:* new tests subscribe to `access_gateways:<org>` and refute a broadcast on an unchanged active observation, and assert `updated_at` is unchanged; the stale-suspend and stale-write tests still pass; `mix ci` is green and this slice adds no uncovered line (the repo's current `[TOTAL] 99.9%` total — three pre-existing unrelated misses, base-reproduced and named in the PR body — is recorded rather than claimed as 100.0%); the C1/C2/C3 suite transcript is pasted.

### S2 — Local fleet parity (the app repo's deliverable)

The fleet repo owns staging/production; the app repo keeps the local-dev mirror per [ADR-0020 Amendment 2](../adr/00020-local-dev-parity.md). Add one file, `deploy/local/k8s/02-access-fleet.yaml`, holding the local mirror of the fleet's `access/staging` objects:

- `Namespace fluxvale-access` with `pod-security.kubernetes.io/{enforce,warn,audit}: baseline` and `app.kubernetes.io/part-of: fluxvale`. Move the namespace out of `01-platform-rbac.yaml` so one file owns the access objects.
- `ResourceQuota access-quota` at the fleet's 16-gateway + resolver numbers (requests 95m/1072Mi, limits 1750m/3232Mi, 16 PVCs / 1Gi, 17 Deployments incl. the resolver slot). Local does not run the resolver today; the slot is headroom, not a claim.
- `Role fluxvale-platform-access` with exactly the provider's called verbs: Deployments `create/get/patch/delete`; Secrets `create/get/patch/delete`; PVCs `create/patch/delete` (no `get`: no call site); Pods `list` (the resolver render pass); ConfigMaps `create/patch` (zones); Certificates `create/get/patch/delete` — [ADR-0040](../adr/00040-strong-private-access-and-custom-domains.md) §2/§6 puts the domain registry's verification and reconcile writes (`RegisterAccessDomain`, `VerifyAccessDomains`, `RemoveAccessDomain`, `EdgeRoutes`) in `certificate_namespace`, the platform's access namespace, so the local mirror carries the fleet's infra#148 verbs. No `resourcequotas`, `networkpolicies`, Services or IngressRoutes in this namespace.
- `RoleBinding` to `system:serviceaccount:fluxvale-dev:fluxvale-platform`.
- Add the file to `Tiltfile`'s `k8s_yaml` list and `scripts/e2e-bootstrap.sh`'s apply list.

The production handoff is a file, not an apply: `docs/plans/273-access-production-handoff.yaml` carries the `fluxvale-access-prod` namespace/quota/PSA/Role/RoleBinding (D2's per-env name) with a header naming it a handoff for the owner-stack repo. It is a named morning item beside #482; nothing in this work applies it to staging or production.

*Done when:* `kubectl apply -f deploy/local/k8s/02-access-fleet.yaml` succeeds; the per-verb `kubectl auth can-i` matrix returns yes only for the granted verbs (the comma-verb form is rejected by this kubectl — use per-verb loops); `kubectl create ... --as=system:serviceaccount:fluxvale-dev:fluxvale-platform --dry-run=server` succeeds for a Deployment, Secret and PVC in `fluxvale-access`; `kubectl get ns fluxvale-access --show-labels` shows the PSA labels; the prod handoff file exists and is explicitly marked do-not-apply.

### S3 — Exit-criteria proof: local halves tonight, staging tailnet for Terence

Local (provable on this box, no tailnet):

1. The serve table: with a seeded gateway row (`tailnet_domain` set) and one attached `:sleeping` private instance, inspect the `serve-config-*` Secret. It must contain the platform's `/internal/access/<gateway>/<instance>` target; after flipping the instance to `:running` and calling `refresh_routes/1`, the same port must target `http://app.<ns>.svc.cluster.local:80`.
2. The endpoint: reset the instance to `:sleeping` first (or use a separate sleeping pair) — a GET while `:running` only flips the route and does not prove a wake. Then `GET /internal/access/<gateway>/<instance>` against the running dev app returns the wake page (200 or the documented status arm) and triggers `wake_instance`; a non-pairing triple returns the byte-identical 404.
3. The panel: the LiveView suite is the local proof of the opt-in, state, re-paste and attach/detach behavior. No new UI code, so no new captures are required.

Not provable locally, and not faked: the gateway pod joining a real tailnet, the `.ts.net` HTTPS cert, a per-app port reached from a tailnet device, and a real serve-to-platform request waking a slept app.

Staging (Terence, ~10 minutes, after this work's PRs land): sign in to staging, open Settings → Access on the dogfood org, paste the staging key already in BWS (`tailscale-authkey-staging`), confirm the gateway reaches `:active` and record minutes-to-active; attach a private instance and visit the `.ts.net` address the panel shows for that instance (its allocated port — `8443` is only the first attach, not a fixed port); let it sleep, visit again, capture the wake page then the app; remove the gateway and confirm the namespace returns to its 1/17 baseline (the 1 is the `access-dns` resolver from infra#136; the issue's 0/16 text predates it). Paste the transcript into the issue; that closes the exit.

The staging runbook rides S3 as a doc section with exact commands, expected outputs and pass criteria, so the human step is a 15-minute exercise rather than an investigation: key location (BWS name only), the panel clicks, the tailnet URL shape, the sleep trigger, the wake evidence to capture, the removal check, and the rollback. No secrets, no cluster writes from this work.

*Done when:* the local proof transcript is pasted in the PR; the staging runbook is reviewed; the PR body states plainly which criterion is proven and which is still waiting on Terence.

## 4. Decision list

Each decision carries the options, the lean, and the reason. The lean is a recommendation, not a settlement.

**D1 — Fleet provisioning ownership.** Options: (a) app-managed at boot — the platform SA creates the access namespace, quota and PSA labels itself; (b) owner-stack declarative manifests, app only consumes; (c) hybrid — owner-stack owns staging/production, the app repo keeps the local-dev mirror (ADR-0020 Am. 2).
**Lean: (c).** ADR-0007's rule is "if it runs on the cluster, it lives in the fleet repo"; an app that can create its own namespace/quota is self-granting cluster permissions, which is exactly what this work must not improvise. Staging is shipped in infra#105 and its Role corrected in infra#148 (the cert-manager Certificate verbs the ADR-0040 registry needs). The app-side deliverable is the local mirror plus the exact prod manifest in `docs/plans/273-access-production-handoff.yaml` — a file plus a named morning item, never an apply.

**D2 — Production namespace isolation.** Options: (a) bind both SAs to the single `fluxvale-access`; (b) add an `ACCESS_GATEWAY_NAMESPACE` runtime override (default `fluxvale-access`) and give production its own `fluxvale-access-prod`, with `access_domains.certificate_namespace` following the same value; (c) rename staging to `fluxvale-access-staging` and let production keep the name.
**Lean: (b).** One shared namespace across environments puts production gateway pods and PVCs under staging's quota and lets a staging SA list production pods; the fleet comment already flags this. (b) needs no staging migration and keeps the default for local. This is a production handoff decision, not a blocker for the staging proof.

**D3 — Local manifest shape.** Options: (a) extend `01-platform-rbac.yaml`; (b) add `02-access-fleet.yaml` and move the namespace/Role there.
**Lean: (b).** One owner per object set, the file mirrors `access/staging`'s layout, and `01` stays the platform bootstrap file. The Tilt and e2e bootstrap lists both learn the new file.

**D4 — Wake endpoint shape and CI proof.** Options: (a) status-driven endpoint — while asleep the serve target is the platform; the request that finds the instance running flips the config (shipped, ADR-0039 §6 + Am. 2); (b) refused-backend detection at the gateway; (c) a platform proxy container in the gateway pod.
**Lean: (a).** (b) is a category error: an asleep app has no backend to refuse, and a running-dead app's 502 must not wake. (c) puts FluxVale in the data path and adds a second image; both are rejected in the ADR. CI proves a wake by driving the controller and the serve-config builder with a sleeping pair and a mocked provider — the wake call and the target flip — not by pretending a tailnet exists. The local endpoint probe adds the live HTTP wiring; the real tailnet leg is staging only.

**D5 — Panel surface placement.** Options: (a) keep Settings → Access (org settings tab + `/settings/access` personal head), as shipped; (b) add a new top-level "Private access" section beside the resource console's domains.
**Lean: (a).** The panel is per-org billing, identity and owner consent; it belongs with the other Settings tabs and next to the instance page's Availability card. The console's domain-divided Sections doctrine governs `/admin/resources` (operator CRUD), not user account settings. Moving it would split the opt-in, key and pairing flow from the org settings that authorize them.

**D6 — Key custody for re-paste.** Options: (a) current write-only K8s Secret, no read-back, no Postgres copy, re-paste replaces the Secret and restarts the pod; (b) a new append-only `AccessGatewayKeyEvent` ledger modelled on the PocketID custody events; (c) store the key in Postgres encrypted.
**Lean: (a) for v1, with named revisit triggers.** ADR-0039 §4 settles the Secret-as-home and the no-read-back rule; the key is a join credential, not a runtime dependency, so a second copy buys nothing. The PocketID ledger is instance-scoped and has a consumer (the instance audit surface); a gateway ledger would be a new table with no reader. **Revisit triggers: (1) a second admin can rotate a key; (2) a support case needs a queryable who/when rotation trail.** This deferral is a recorded decision, not an omission.

**D7 — Observer write churn.** Options: (a) accept ~1,440 row writes + broadcasts per gateway per day; (b) fresh-read no-op when the observed values already match, keeping the filtered write for every real transition; (c) drop the periodic write entirely and rely on the panel's refetch.
**Lean: (b).** (a) is needless write amplification and noise on the per-org topic. (c) loses the `:active` observation cadence that arms settlement and clears the attention clock. (b) removes the churn without weakening the stale-record protection: the no-op path writes nothing, so it cannot clobber; every transition still runs through `expected_state`.

**D8 — Exit-proof split.** Options: (a) wait for one staging session and prove everything there; (b) prove the platform halves locally tonight, hand the real-tailnet half to Terence with a runbook; (c) stand up a local headscale to claim an end-to-end tailnet.
**Lean: (b), reject (c).** (a) leaves the work idle for a proof whose code is already merged. (c) is a different tailnet and a different product path; calling it the exit proof would be faking it. (b) gives an honest transcript now and leaves exactly one criterion open, owned by the person who owns the tailnet and the staging sign-in.

**D9 — Close semantics.** Options: (a) close #273 when this work's PRs merge; (b) keep #273 open, reference it from every PR, close only on the staging transcript.
**Lean: (b).** The issue's own exit is the tailnet proof; merging code is not the exit. PR bodies reference #273 without a closing keyword until Terence's transcript lands.

**D10 — P3 close-out evidence.** Options: (a) trust the merged C1–C3 PRs; (b) re-run their named suites at the current HEAD and paste the counts.
**Lean: (b).** It is minutes, and the carried findings were the price of an earlier hostile review; the close-out should read as proof, not a link.

## 5. Risks

- **Local proof flakiness.** Seeding a funded org, a gateway and a sleeping instance touches the dev DB; if the seed path fights the dev data, fall back to the provider-level test harness plus the server dry-run RBAC matrix, and report the gap honestly. Never substitute a mocked "proof" for the live endpoint probe without saying so.
- **Quota parity.** The local quota copies the fleet's 16-gateway numbers; the local box also runs the platform, CNPG and MinIO, which the staging quota does not. Sizing is object-count headroom, not a capacity plan for this box; if it pinches, the local file can shrink without touching the fleet.
- **Prod handoff drift.** The prod manifest in the handoff note is a proposal; the app's single namespace config is the real dependency. D2's runtime override must land with the fleet change or production will 403 at its first gateway op (the fleet comment calls this the fail-safe).
- **Observer quiet arm hiding a lag.** Quiet means the row already says what the cluster says; a stale cluster read is still corrected on the next transition. The test pins the no-broadcast path, and the transition tests keep the write path honest.

## 6. Order and ownership

S1 (P3 close-out) → S2 (local fleet) → S3 (proof). S2 and S3 can overlap once S1's plan doc lands; S3 depends on S2 only for the RBAC half of the local probe. One slice per PR, each with a fresh independent review and the gate re-run before merge; merge rides the overnight standing grant.

## 7. What this plan does not do

- It does not rebuild the wake intercept, the panel or the staging fleet objects; it verifies and closes them.
- It does not apply production cluster manifests; it decides the split and hands over the manifest.
- It does not claim the tailnet exit proof locally; it proves the two platform halves and leaves the real-tailnet transcript to Terence.
- It does not add key-custody storage or a new audit table.

## 8. PA riders (Nov 9 2026)

1. The inventory correction — wake #301, panel #300/#311, fleet staging infra#105 already shipped — appears in this plan's assumptions and in the first PR body, so the morning reader sees that the issue overstated what was missing. No standalone issue comments tonight; #273 stays open reference-only (D9).
2. D6's revisit triggers are written verbatim in the decision above: a second admin can rotate a key, or a support case needs a queryable who/when rotation trail. The deferral is a recorded decision, not an omission; hostile review may probe custody and the answer lives there.
3. D1's production manifest is `docs/plans/273-access-production-handoff.yaml`, a file plus a named morning item beside #482 on Terence's owner-stack apply list. Nothing in this work applies anything to staging or production clusters.
4. S3's runbook gives Terence exact commands, expected outputs and pass criteria, so the staging transcript is a 15-minute exercise, not an investigation.
