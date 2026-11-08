# Staging proof: private access on a real tailnet (#273)

Owner: Terence. Time: ~15 minutes, plus the idle wait in criterion 2.

**The local proof is partial.** `scripts/private-access-local-proof.sh`
proves the serve table and the live wake endpoint on this box, with no
tailnet (the transcript rides the S3 PR). It cannot prove a gateway pod
joining a real tailnet, the `.ts.net` certificate, a per-app port reached
from a tailnet device, or a real serve-to-platform request waking a slept
app. **This runbook is the real-tailnet half** — [ADR-0039 §6](../adr/00039-private-access-layer-tailscale.md)
and [Amendment 2](../adr/00039-private-access-layer-tailscale.md) are the
decision text.

Pass criteria: both criteria below have their evidence, the gateway is
removed, and the access namespace is back to its **1/17** baseline — the
1 is the `access-dns` resolver, which is not this proof's object.

## Preconditions (before the clock starts)

Do these first; each one is a documented cause of a gateway that never
serves.

1. **Tailnet tag and `tagOwners`.** In the Tailscale admin console →
   **Access controls** → **Tags**, the tailnet has `tag:fluxvale` (the
   panel's own example tag) and its `tagOwners` includes your tailnet
   user. The staging auth key must carry that tag.
2. **MagicDNS on.** Admin console → **DNS** → **MagicDNS** enabled.
3. **HTTPS on.** Admin console → **DNS** → **HTTPS Certificates**
   enabled. Without a cert domain, `containerboot` silently declines to
   apply the serve config ([ADR-0039 References and §8](../adr/00039-private-access-layer-tailscale.md)).
4. **Staging key in BWS.** The key is the Bitwarden Secrets Manager entry
   named `tailscale-authkey-staging`. Open it in the BWS UI and copy it;
   never print it. It must be tagged `tag:fluxvale` and non-ephemeral. If
   it has expired, mint a replacement with the same tag and non-ephemeral
   setting; record that you did.
5. **Staging sign-in is passwordless.** No password exists to find:
   `https://staging.fluxvale.com/sign-in` → enter your staging email →
   enter the code from the inbox.
6. **Dogfood org access.** You are an owner of the dogfood org (the
   Access tab is owner-only in the panel).

Optional read-only baseline (staging cluster context; do not apply):

```sh
kubectl config current-context                 # must be the staging cluster
kubectl -n fluxvale-access get deploy,secret,pvc
kubectl -n fluxvale-access get resourcequota access-quota \
  -o jsonpath='{.status.used.count/deployments\.apps}/{.status.hard.count/deployments\.apps}{"\n"}'
```

Expected baseline: `deployment.apps/access-dns` is present, no
`gateway-*` / `serve-config-*` / `credential-*` / `state-*` objects, and
the quota reads **1/17**. The issue's `0/16` text predates infra#136;
staging counts the resolver's slot.

## Criterion 1 — sign in, paste the key, reach the app from the tailnet

1. Sign in at `https://staging.fluxvale.com/sign-in`. Expected: the
   dashboard for your account.
2. Open the dogfood org → **Settings** → **Access** (direct shape:
   `https://staging.fluxvale.com/organizations/<dogfood-slug>/settings/access`).
3. Record the start time: `date -u +%H:%M:%SZ`.
4. Paste the BWS key into **Auth key** (the field is masked and write-only;
   it is never read back), enter your MagicDNS suffix as **Tailnet
   domain** (`your-tailnet.ts.net`), and submit **Enable private access**.
5. Expected progression: **Connecting** (row state `:provisioning`), then **Connected** (`:active`).
   The row is `:active` only after the observer sees the gateway pod
   ready, so this is the real join signal.
   - Record the time when Connected appears: `date -u +%H:%M:%SZ`.
   - **Pass:** Connected within 10 minutes; record `minutes-to-active`.
   - On failure: capture the card's status message and read-only pod
     evidence (`kubectl -n fluxvale-access get pods -l
     app.kubernetes.io/name=access-gateway`), then use Rollback below.
6. Attach a **private** instance. If the dogfood org has no private
   instance, open an instance page → **Availability** → set exposure to
   **Private** first (it must have no public route). Back on **Settings →
   Access**, choose that instance and **Attach**.
   - Expected: a route row with the address the panel renders from
     hostname + tailnet domain + port (`fv-xxxxxxxx.<tailnet>.ts.net:<port>`;
     the first attach is usually `:8443`).
   - **Pass:** the address appears and the instance shows **Private**.
   - Record the full address (host and port) — the later commands use it.
7. From a device that is signed in to the same tailnet:

   ```sh
   tailscale status | grep -i 'fv-'      # the gateway node is listed
   curl -sS -o /dev/null -w '%{http_code}\n' 'https://<address-from-step-6>/'
   ```

   Expected: `200`, and the app's own page in a browser. **Pass:** the
   app serves at the full `.ts.net` address (the port recorded in step 6)
   from the tailnet device.

Evidence: screenshot the Connected card (key field masked — it cannot
echo, and do not capture the clipboard), and one screenshot of the app at
the tailnet URL with the URL bar visible. Record the minutes-to-active.

## Criterion 2 — let it sleep, revisit, wake it

1. Make sure the instance is not **always-on**, then leave it alone. Send
   no requests (no health checks, no browser tabs refreshing it).
2. Wait for the idle sweep. The default threshold is one hour
   (`idle_sleep_after_seconds: 3600`); staging may override it with
   `IDLE_SLEEP_AFTER_SECONDS`. Check the panel's instance/Access status
   until it reads **Sleeping**; record the timestamp.
3. Revisit the **same** address recorded in step 6 (the port the route
   row shows, not a fixed 8443) from the tailnet device.
   - Expected first response: the waking interstitial — title
     **Waking up…**, body **Waking <app name> up…**, with a 2-second
     self-refresh.
   - Expected next response: the app itself, at the same URL.
   - **Pass:** both states observed; record seconds from first request to
     the app. (The ADR's stated worst case is the kubelet's config sync
     period; the revisit trigger is a measured flip above ~10s.)
4. Capture the waking page **and** the app at the same URL, plus the two
   timestamps. If the first request raced the sleep landing, wait for
   **Sleeping** again and retry once; record that.

Evidence: two screenshots (waking page, app), timestamps, seconds-to-app.

## Cleanup — leave staging as found

1. **Settings → Access** → **Remove** → **Remove private access**.
   Expected: the card disappears; the attached instance is detached and
   returns to the private floor; the gateway's Deployment, Secrets and
   PVC are deleted.
2. Verify from the cluster (read-only; the platform does the deletion):

   ```sh
   kubectl -n fluxvale-access get deploy,secret,pvc
   kubectl -n fluxvale-access get resourcequota access-quota \
     -o jsonpath='{.status.used.count/deployments\.apps}/{.status.hard.count/deployments\.apps}{"\n"}'
   ```

   **Pass:** the namespace is back to its **1/17** baseline — the 1 is
   `access-dns` — and no `gateway-*` / `serve-config-*` / `credential-*` /
   `state-*` objects remain. The load-bearing claim is *back to baseline*,
   not zero used.
3. If the instance existed only for this proof, stop or delete it from
   its page so it stops billing.

Evidence: the `1/17` quota output and an access-namespace listing showing
only `access-dns`.

## Rollback

- **Key rejected / NeedsLogin:** paste a fresh tagged key from BWS via
   **Settings → Access → Reconnect** (the `:needs_attention` toggle label;
   `Re-paste key` is the active/provisioning label). Re-paste is the
   recovery path; it restarts the pod with the persisted node state.
- **Stuck Connecting >10 min (row state `:provisioning`):** capture the card's message and
  read-only pod describe/logs, then remove it from the panel (**Remove**
  → **Remove private access**). Do not patch or restart the Deployment by
  hand; a fresh paste is the supported repair.
- **Attach refused:** check the instance is **Private**, same org, and
  the gateway is Connected, then retry.
- **Wake does not flip after 90 seconds:** record the timing, find the
  gateway's serve Secret (`kubectl -n fluxvale-access get secret | grep
  serve-config`; use its NAME column — the hostname is unrelated to the
  Secret suffix), and read its target (`kubectl -n fluxvale-access get
  secret <name-from-the-NAME-column> -o jsonpath='{.data.serve\.json}' |
  base64 -d`), then re-paste or detach/attach once to force regeneration.
  If it still fails, remove the gateway and report; do not hand-edit the
  Secret.
- **Removal fails or parks in `:destroying`:** retry the remove (or the
  **Retry removal** button when it appears); the retry is idempotent.
  Capture read-only evidence; never force-delete the namespace or the row.

## Evidence to paste on #273

- signed-in confirmation and the dogfood org slug;
- start/Connected timestamps and `minutes-to-active`;
- the tailnet URL shape (hostname + tailnet suffix) and the device name
  you tested from;
- the Connected card screenshot (key masked) and the app-at-URL
  screenshot;
- sleep timestamp, waking-page screenshot, app screenshot, and
  seconds-to-app;
- cleanup quota output showing numerator 0;
- any failure log, with the exact command that produced it.

**Do not paste the key**, a screenshot of it, or the BWS token into the
issue, the PR, chat, or a terminal transcript.

## Do-not list

- Do not print, echo, `cat`, `tee`, or screenshot the BWS key.
- Do not apply, patch, scale, or delete staging objects by hand; the
  panel and its teardown own every write. The `kubectl` commands above
  are read-only except the panel's own removal.
- Do not use port 443/80 or a public hostname for the private URL; the
  proof is the per-app port on the `.ts.net` name (the first attach is
  usually `8443`).
- Do not attach a public instance, an instance from another org, or an
  always-on instance for criterion 2.
- Do not disable HTTPS/MagicDNS to "make it work"; that is the documented
  serve-config failure.
- Do not leave the gateway up after the proof — it bills by existence.
- Do not treat the local proof as a tailnet proof, or this runbook as a
  license to apply production manifests.
