package provider

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/fluxvale/fluxvale/apps/tfprovider/internal/client"
	"github.com/hashicorp/terraform-plugin-framework-timeouts/resource/timeouts"
	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

var _ resource.ResourceWithImportState = (*customDomainResource)(nil)

// createWaitDefault bounds the wait_for_verification poll: the
// platform's observer pass verifies on its ~15-minute cadence, so
// three passes is the honest default.
const createWaitDefault = 45 * time.Minute

// customDomainResource manages fluxvale_custom_domain — the caller's
// own domain registered on the private-access edge. A skin over the
// register/read/remove surface: register lands the row :pending
// :custom and mints the wildcard Certificate inside the create's
// transaction (failure = no row); verification is issuance — the
// platform's observer pass is the ONLY promoter to :verified; remove
// is the full teardown server-side. Every refusal (paywall, scope,
// duplicate name) surfaces verbatim.
type customDomainResource struct {
	pd *providerData
}

// NewCustomDomainResource returns the resource factory provider.go
// registers.
func NewCustomDomainResource() resource.Resource {
	return &customDomainResource{}
}

func (r *customDomainResource) Metadata(_ context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_custom_domain"
}

// customDomainModel mirrors the schema. organization is written back
// only when the config leaves it null (the import-convergence seed);
// wait_for_verification is config-only posture — the wire has no echo,
// and reads keep the configured value verbatim.
type customDomainModel struct {
	Domain              types.String   `tfsdk:"domain"`
	Organization        types.String   `tfsdk:"organization"`
	WaitForVerification types.Bool     `tfsdk:"wait_for_verification"`
	Timeouts            timeouts.Value `tfsdk:"timeouts"`
	ID                  types.String   `tfsdk:"id"`
	Kind                types.String   `tfsdk:"kind"`
	State               types.String   `tfsdk:"state"`
	OrganizationID      types.String   `tfsdk:"organization_id"`
}

func (r *customDomainResource) Schema(ctx context.Context, _ resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Your own domain registered on the private-access edge. Register lands the row `pending` and mints the wildcard Certificate in the same transaction; verification is issuance — the platform's observer pass (about a 15-minute cadence) promotes pending → verified once your DNS delegation answers the DNS-01 challenge, and fails the row past its issuance window (~72h). VERIFIED IS NOT RESOLUTION: a verified domain does not answer on the tailnet — claiming (split-DNS + serving) is a separate platform capability on a later slice. This resource registers, verifies (DNS-01), and tears down, nothing more.",
		Attributes: map[string]schema.Attribute{
			"domain": schema.StringAttribute{
				Required: true,
				MarkdownDescription: "The domain to register — e.g. `apps.example.com`. The platform canonicalizes the name " +
					"(trimmed, downcased) and stores THAT: write it lowercase, or every plan shows a replacement. Names are " +
					"platform-wide unique across ALL organizations — the duplicate 400 surfaces verbatim (the name may " +
					"belong to another org). Changing it replaces the resource: a different name is a different row, and " +
					"destroy really removes it.",
				PlanModifiers: []planmodifier.String{stringplanmodifier.RequiresReplace()},
			},
			"organization": schema.StringAttribute{
				Optional: true,
				Computed: true,
				MarkdownDescription: "Organization to register the domain in — its id or slug. Falls back to the provider-level " +
					"`organization`, then to your sole organization (several memberships without a name is an error). " +
					"The resolved id is written back when the config leaves this unset, so imports converge. Changing it " +
					"replaces the resource (the register takes the org only at create).",
				PlanModifiers: []planmodifier.String{stringplanmodifier.RequiresReplace()},
			},
			"wait_for_verification": schema.BoolAttribute{
				Optional: true,
				MarkdownDescription: "Wait out verification before create finishes. Default false: create returns at `pending` " +
					"and refreshes show the progression via `state` — the janitor verifies on its ~15-minute cadence after " +
					"your DNS delegation answers. When true, create polls `state` until `verified` (bounded by the " +
					"`timeouts.create`, default 45m; a timeout leaves tainted state — the domain keeps verifying " +
					"server-side, and the next apply/refresh resolves it) or fails fast on `failed` (terminal: remove " +
					"and re-register). Nothing is PATCHable, so flipping this later only re-reads.",
			},
			"id": schema.StringAttribute{
				Computed:    true,
				Description: "The access-domain id — the read/remove path key, and the terraform import argument.",
			},
			"kind": schema.StringAttribute{
				Computed:    true,
				Description: "Always \"custom\" — platform rows are system-minted, never registered.",
			},
			"state": schema.StringAttribute{
				Computed: true,
				MarkdownDescription: "pending → verified ⇄ suspended, plus failed, needs_attention. A `suspended` domain is " +
					"the zero-balance ladder's out-of-band state — resume via the panel (the API's " +
					"`PATCH /access-domains/:id/resume` underneath); this resource deliberately does not manage it.",
			},
			"organization_id": schema.StringAttribute{
				Computed:    true,
				Description: "The org the domain registers under (the wire's echo of the resolution).",
			},
		},
		Blocks: map[string]schema.Block{
			"timeouts": timeouts.Block(ctx, timeouts.Opts{
				Create: true,
				CreateDescription: "How long create waits for verification when wait_for_verification is true — a duration " +
					"like \"30m\" or \"2h\". Defaults to 45m (three observer passes); a pending row that never verifies " +
					"fails server-side after its ~72h issuance window either way.",
			}),
		},
	}
}

func (r *customDomainResource) Configure(_ context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	pd, ok := req.ProviderData.(*providerData)
	if !ok {
		resp.Diagnostics.AddError(
			"Unexpected provider data type",
			fmt.Sprintf("Got %T, want *providerData. Please report this bug.", req.ProviderData),
		)
		return
	}
	r.pd = pd
}

// data returns the configured providerData or a diagnostic — every
// CRUD path starts here.
func (r *customDomainResource) data(diags *diag.Diagnostics) *providerData {
	if r.pd == nil {
		diags.AddError(
			"Provider not configured",
			"The provider was not configured before this resource was used — please report this bug.",
		)
	}
	return r.pd
}

func (r *customDomainResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var data customDomainModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &data)...)
	if resp.Diagnostics.HasError() {
		return
	}

	pd := r.data(&resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}

	orgID := resolveOrgID(ctx, pd.client, data.Organization, pd.organization, &resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}
	seedDomainOrganization(&data, orgID)

	dom, err := pd.client.CreateAccessDomain(ctx, client.CreateAccessDomainInput{
		Domain:         data.Domain.ValueString(),
		OrganizationID: orgID,
	})
	if err != nil {
		// Pre-POST: nothing landed (a failed register rolls the
		// Certificate mint back with the row) — no state write. The
		// duplicate 400 surfaces verbatim; no adoption probe — the name
		// is unique across ALL organizations, so the row behind the
		// refusal may belong to another org entirely.
		resp.Diagnostics.AddError(
			"Unable to register the custom domain",
			err.Error()+" — names are unique platform-wide, across all organizations: the registered name may belong to another org.",
		)
		return
	}
	data.ID = types.StringValue(dom.ID)
	mapDomain(&data, dom)

	// The platform now has this row (Certificate minted inside the
	// transaction). Tainted tracked state beats an untracked leak (the
	// gateway's post-POST stance): write what we know so every later
	// failure — wait timeout, the failed arm, the final read — leaves a
	// tracked resource the next apply updates or forgets. mapDomain
	// fills every computed field, so no unknowns remain to clear.
	resp.Diagnostics.Append(resp.State.Set(ctx, &data)...)
	if resp.Diagnostics.HasError() {
		return
	}

	// Verification is issuance: the observer pass (about a 15-minute
	// cadence, after the owner delegates DNS) is the only promoter.
	// wait_for_verification only decides whether create waits out that
	// cadence. VERIFIED IS NOT RESOLUTION — see waitDomainVerified.
	if desiredWait(data.WaitForVerification) {
		waitFor, d := data.Timeouts.Create(ctx, createWaitDefault)
		resp.Diagnostics.Append(d...)
		if resp.Diagnostics.HasError() {
			return
		}
		waitDomainVerified(ctx, pd, dom.ID, waitFor, &resp.Diagnostics)
		if resp.Diagnostics.HasError() {
			return
		}
	}

	// Fresh read for state — the wait (when one ran) just saw the row
	// move, and a lingering :pending state would misdescribe it.
	if readDomain(ctx, pd, &data, &resp.Diagnostics) {
		resp.Diagnostics.AddError(
			"Custom domain disappeared during creation",
			fmt.Sprintf("domain %s was removed between register and its final read — refresh and re-apply", dom.ID),
		)
		return
	}
	if resp.Diagnostics.HasError() {
		return
	}
	resp.Diagnostics.Append(resp.State.Set(ctx, &data)...)
}

// waitDomainVerified polls GET /access-domains/:id until the row
// verifies. VERIFIED IS NOT RESOLUTION: verified means the wildcard
// Certificate issued (DNS-01) — the domain still answers nothing on
// the tailnet until the separate claiming capability lands. failed
// fails fast: the wire's public surface carries no status message (the
// pinned field set), so the state string is the whole story the API
// tells — and failed is terminal for a registration; the fix is remove
// and re-register. Everything else keeps polling to the deadline.
func waitDomainVerified(ctx context.Context, pd *providerData, id string, waitFor time.Duration, diags *diag.Diagnostics) {
	var lastState string
	err := pollWithDeadline(ctx, pd.pollInterval, waitFor, func(ctx context.Context) (bool, error) {
		dom, err := pd.client.GetAccessDomain(ctx, id)
		if err != nil {
			return false, err
		}
		lastState = dom.State
		switch dom.State {
		case "verified":
			return true, nil
		case "failed":
			return false, errors.New("the domain landed in failed — DNS-01 issuance never completed inside the " +
				"platform's window, and failed is terminal for a registration: remove and re-register " +
				"(terraform apply -replace)")
		}
		return false, nil
	})
	if err != nil {
		diags.AddError(
			"Custom domain did not verify",
			fmt.Sprintf("domain %s: %v (last state %q)", id, err, lastState),
		)
	}
}

func (r *customDomainResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var data customDomainModel
	resp.Diagnostics.Append(req.State.Get(ctx, &data)...)
	if resp.Diagnostics.HasError() {
		return
	}

	pd := r.data(&resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}

	if readDomain(ctx, pd, &data, &resp.Diagnostics) {
		resp.State.RemoveResource(ctx)
		return
	}
	if resp.Diagnostics.HasError() {
		return
	}
	resp.Diagnostics.Append(resp.State.Set(ctx, &data)...)
}

// readDomain resolves the org (seeding it when the config left it
// null — the import-convergence seed), then reads by id. It maps the
// wire's fields and returns true when the row is gone (404 — the
// caller removes it from state). organization and
// wait_for_verification are config-only — both survive Read untouched.
func readDomain(ctx context.Context, pd *providerData, data *customDomainModel, diags *diag.Diagnostics) bool {
	orgID := resolveOrgID(ctx, pd.client, data.Organization, pd.organization, diags)
	if diags.HasError() {
		return false
	}
	seedDomainOrganization(data, orgID)

	dom, err := pd.client.GetAccessDomain(ctx, data.ID.ValueString())
	if err != nil {
		var apiErr *client.APIError
		if errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound {
			return true
		}
		diags.AddError("Unable to read the custom domain", err.Error())
		return false
	}
	mapDomain(data, dom)
	return false
}

// mapDomain writes the wire's fields into the model. The wire's domain
// is the platform's canonical form (trimmed, downcased) — mapping it
// is what makes imports converge (and what a non-canonical config
// keeps diffing against). organization and wait_for_verification have
// no wire source; the configured values survive Read untouched.
func mapDomain(data *customDomainModel, dom client.AccessDomain) {
	data.ID = types.StringValue(dom.ID)
	data.Domain = types.StringValue(dom.Domain)
	data.Kind = types.StringValue(dom.Kind)
	data.State = types.StringValue(dom.State)
	data.OrganizationID = types.StringValue(dom.OrganizationID)
}

// seedDomainOrganization writes the org the resolution actually used
// into a null organization — the import-convergence seed. A config-set
// value (slug or id) is kept verbatim: it already resolved at
// create/read.
func seedDomainOrganization(data *customDomainModel, orgID string) {
	if data.Organization.IsNull() {
		data.Organization = types.StringValue(orgID)
	}
}

// desiredWait is what wait_for_verification asks for: null means the
// default (false — return at pending).
func desiredWait(v types.Bool) bool {
	return !v.IsNull() && !v.IsUnknown() && v.ValueBool()
}

// Update is the re-read-and-set no-op: nothing is PATCHable (the only
// PATCH verb is resume, deliberately not exposed), and the one thing
// that can change — domain — RequiresReplace, so an update is only
// ever wait_for_verification's flag flipping. A fresh read settles
// state; 404 removes — gone is gone, never plan-over-ghost.
func (r *customDomainResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan customDomainModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	pd := r.data(&resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}

	if readDomain(ctx, pd, &plan, &resp.Diagnostics) {
		resp.State.RemoveResource(ctx)
		return
	}
	if resp.Diagnostics.HasError() {
		return
	}
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *customDomainResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state customDomainModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	pd := r.data(&resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}

	// The full teardown server-side — hostname pre-check, tailnet
	// unclaim, row destroy, CoreDNS re-render, Certificate safe-delete
	// — one synchronous DELETE, so there is nothing to poll: the 200
	// is done. A 404 is already-gone: idempotent destroy (a panel
	// remove between refresh and apply must not fail the plan). The
	// platform-kind 400 is unreachable for provider-created rows
	// (register forces :custom) but surfaces verbatim if ever seen.
	if err := pd.client.DeleteAccessDomain(ctx, state.ID.ValueString()); err != nil {
		var apiErr *client.APIError
		if errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound {
			resp.State.RemoveResource(ctx) // already gone
			return
		}
		resp.Diagnostics.AddError("Unable to delete the custom domain", err.Error())
		return
	}
	resp.State.RemoveResource(ctx)
}

func (r *customDomainResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	// By domain id: terraform import fluxvale_custom_domain.x <id>.
	// Read fills the wire-mirrored fields — domain (the canonical
	// name), kind, state, organization_id — and seeds organization from
	// the resolution, so a config that leaves it unset converges.
	// wait_for_verification stays null; set it (and the timeouts) in
	// your config if you want the next create-armed apply to wait.
	resource.ImportStatePassthroughID(ctx, path.Root("id"), req, resp)
}
