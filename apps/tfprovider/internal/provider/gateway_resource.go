package provider

import (
	"context"
	"errors"
	"fmt"
	"net/http"

	"github.com/fluxvale/fluxvale/apps/tfprovider/internal/client"
	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

var _ resource.ResourceWithImportState = (*gatewayResource)(nil)

// gatewayResource manages fluxvale_access_gateway — the org's
// singleton private-access gateway. A skin over the routed surface:
// create, the singleton read, and the attachment pairing verbs. The
// API has NO gateway-delete route (the scope table's whole gateway
// section), so destroy is remove-from-state with an honest warning.
type gatewayResource struct {
	pd *providerData
}

// NewGatewayResource returns the resource factory provider.go
// registers.
func NewGatewayResource() resource.Resource {
	return &gatewayResource{}
}

func (r *gatewayResource) Metadata(_ context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_access_gateway"
}

// gatewayModel mirrors the schema. Config identity fields (organization,
// tailnet_domain) and the write-only auth_key are never overwritten
// from the wire; instances is config-authoritative — the wire has no
// attachment list, so reads keep the configured set verbatim.
type gatewayModel struct {
	Organization   types.String `tfsdk:"organization"`
	TailnetDomain  types.String `tfsdk:"tailnet_domain"`
	AuthKey        types.String `tfsdk:"auth_key"`
	Instances      types.Set    `tfsdk:"instances"`
	ID             types.String `tfsdk:"id"`
	OrganizationID types.String `tfsdk:"organization_id"`
	Hostname       types.String `tfsdk:"hostname"`
	Provider       types.String `tfsdk:"provider"`
	State          types.String `tfsdk:"state"`
	StatusMessage  types.String `tfsdk:"status_message"`
	MonthlyCents   types.Int64  `tfsdk:"monthly_cents"`
	ProvisionedAt  types.String `tfsdk:"provisioned_at"`
}

func (r *gatewayResource) Schema(_ context.Context, _ resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "The organization's private-access gateway — the always-on pod that puts the org's private instances on your tailnet. One per organization. Destroying this resource removes it from state only: the API exposes no gateway-delete route, so the platform keeps the gateway running (and billing).",
		Attributes: map[string]schema.Attribute{
			"organization": schema.StringAttribute{
				Optional: true,
				MarkdownDescription: "Organization to enable the gateway in — its id or slug. Falls back to the provider-level " +
					"`organization`, then to your sole organization (several memberships without a name is an error). " +
					"Changing it replaces the resource (the API has no org-change route).",
				PlanModifiers: []planmodifier.String{stringplanmodifier.RequiresReplace()},
			},
			"tailnet_domain": schema.StringAttribute{
				Required: true,
				MarkdownDescription: "Your tailnet's MagicDNS suffix (`<tailnet>.ts.net`) — visible in your Tailscale admin " +
					"console on every device name. Create-only (the API's only PATCH verb is resume), so changing it replaces " +
					"the resource — which cannot destroy the existing gateway (no delete route); opt out via the panel first.",
				PlanModifiers: []planmodifier.String{stringplanmodifier.RequiresReplace()},
			},
			"auth_key": schema.StringAttribute{
				Required:  true,
				Sensitive: true,
				MarkdownDescription: "The Tailscale auth key the gateway joins your tailnet with. Write-only: the API never " +
					"echoes it, and the configured value is kept verbatim in state. Create-only — rotation is the panel's " +
					"re-paste (no API route), so changing it replaces the resource; opt out via the panel first.",
				PlanModifiers: []planmodifier.String{stringplanmodifier.RequiresReplace()},
			},
			"instances": schema.SetAttribute{
				ElementType: types.StringType,
				Optional:    true,
				MarkdownDescription: "Instance ids to attach — one attach/detach call per added/removed id. Attach needs a " +
					"PRIVATE, deployed instance in the same org and an active gateway (the platform refuses anything else, " +
					"its wording surfaces verbatim). Config-authoritative: the API has no attachment list, so reads keep the " +
					"configured set and out-of-band attach/detach (the panel) is invisible to the provider.",
			},
			"id": schema.StringAttribute{
				Computed:    true,
				Description: "The gateway id — the attachment verbs' path key.",
			},
			"organization_id": schema.StringAttribute{
				Computed:    true,
				Description: "The org the gateway serves (the wire's echo of the resolution).",
			},
			"hostname": schema.StringAttribute{
				Computed:    true,
				Description: "The opaque fv-<8 hex> node name — minted at create, never derived from org or app names.",
			},
			"provider": schema.StringAttribute{
				Computed:    true,
				Description: "The access provider (tailscale).",
			},
			"state": schema.StringAttribute{
				Computed: true,
				MarkdownDescription: "The gateway's state machine: provisioning → active (the observer promotes within about a " +
					"minute); needs_attention, suspended, destroying possible. A suspended gateway is the zero-balance " +
					"ladder's out-of-band platform state — resume via the panel or MCP (`resume_gateway`); this resource " +
					"deliberately does not manage it.",
			},
			"status_message": schema.StringAttribute{
				Computed:    true,
				Description: "The panel's friendly copy for the current state (null when there is nothing to say).",
			},
			"monthly_cents": schema.Int64Attribute{
				Computed:    true,
				Description: "The live monthly rate in cents — snapshotted at create from the platform's config (never caller-supplied).",
			},
			"provisioned_at": schema.StringAttribute{
				Computed:    true,
				Description: "When the cluster objects were provisioned (null until then).",
			},
		},
	}
}

func (r *gatewayResource) Configure(_ context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
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
func (r *gatewayResource) data(diags *diag.Diagnostics) *providerData {
	if r.pd == nil {
		diags.AddError(
			"Provider not configured",
			"The provider was not configured before this resource was used — please report this bug.",
		)
	}
	return r.pd
}

func (r *gatewayResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var data gatewayModel
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

	gw, err := pd.client.CreateGateway(ctx, client.CreateGatewayInput{
		OrganizationID: orgID,
		TailnetDomain:  data.TailnetDomain.ValueString(),
		AuthKey:        data.AuthKey.ValueString(),
	})
	if err != nil {
		resp.Diagnostics.AddError("Unable to create the access gateway", err.Error())
		return
	}
	mapGateway(&data, gw)

	// Attach needs a serving gateway — create lands :provisioning and
	// the observer (a one-minute cadence) is the only promoter to
	// :active, so the attach sequence waits it out first.
	instances, d := instanceSet(ctx, data.Instances)
	resp.Diagnostics.Append(d...)
	if resp.Diagnostics.HasError() {
		return
	}
	applyInstanceDiff(ctx, pd, orgID, gw.ID, nil, instances, &resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}

	resp.Diagnostics.Append(resp.State.Set(ctx, &data)...)
}

// applyInstanceDiff converges the attachments onto the configured set:
// one POST per added id, one DELETE per removed id. A non-empty add
// side first waits the gateway to :active — the attach verb refuses a
// gateway that is not serving.
func applyInstanceDiff(ctx context.Context, pd *providerData, orgID, gatewayID string, current, configured []string, diags *diag.Diagnostics) {
	added, removed := instanceSetDiff(current, configured)

	if len(added) > 0 {
		waitGatewayActive(ctx, pd, orgID, diags)
		if diags.HasError() {
			return
		}
	}
	for _, id := range added {
		if err := pd.client.AttachGatewayInstance(ctx, gatewayID, id); err != nil {
			diags.AddError("Unable to attach instance "+id, fmt.Sprintf("gateway %s: %v", gatewayID, err))
			return
		}
	}
	for _, id := range removed {
		if err := pd.client.DetachGatewayInstance(ctx, gatewayID, id); err != nil {
			diags.AddError("Unable to detach instance "+id, fmt.Sprintf("gateway %s: %v", gatewayID, err))
			return
		}
	}
}

// waitGatewayActive polls the singleton read until the gateway serves.
// needs_attention is terminal for the wait — status_message is the
// whole story the API tells (the instance deploy wait's stance).
func waitGatewayActive(ctx context.Context, pd *providerData, orgID string, diags *diag.Diagnostics) {
	var lastState string
	err := pollWithDeadline(ctx, pd.pollInterval, pd.pollTimeout, func(ctx context.Context) (bool, error) {
		gw, err := pd.client.GetOrgGateway(ctx, orgID)
		if err != nil {
			return false, err
		}
		lastState = gw.State
		switch gw.State {
		case "active":
			return true, nil
		case "needs_attention":
			msg := "no message"
			if gw.StatusMessage != nil {
				msg = *gw.StatusMessage
			}
			return false, fmt.Errorf("the gateway landed in needs_attention: %s", msg)
		}
		return false, nil
	})
	if err != nil {
		diags.AddError(
			"Access gateway did not become active",
			fmt.Sprintf("gateway for org %s: %v (last state %q)", orgID, err, lastState),
		)
	}
}

// readGateway refreshes the model from the singleton read (resolved
// through the org) and returns true when the org has no gateway (404 —
// the caller removes it from state).
func readGateway(ctx context.Context, pd *providerData, data *gatewayModel, diags *diag.Diagnostics) bool {
	orgID := resolveOrgID(ctx, pd.client, data.Organization, pd.organization, diags)
	if diags.HasError() {
		return false
	}
	gw, err := pd.client.GetOrgGateway(ctx, orgID)
	if err != nil {
		var apiErr *client.APIError
		if errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound {
			return true
		}
		diags.AddError("Unable to read the access gateway", err.Error())
		return false
	}
	mapGateway(data, gw)
	return false
}

// mapGateway writes the wire's fields into the model. The write-only
// auth_key, the config identity organization, and the
// config-authoritative instances have no wire source — the configured
// values survive Read untouched.
func mapGateway(data *gatewayModel, gw client.AccessGateway) {
	data.ID = types.StringValue(gw.ID)
	data.OrganizationID = types.StringValue(gw.OrganizationID)
	data.Hostname = types.StringValue(gw.Hostname)
	data.TailnetDomain = types.StringValue(gw.TailnetDomain)
	data.Provider = types.StringValue(gw.Provider)
	data.State = types.StringValue(gw.State)
	data.StatusMessage = types.StringPointerValue(gw.StatusMessage)
	data.MonthlyCents = types.Int64Value(gw.MonthlyCents)
	data.ProvisionedAt = types.StringPointerValue(gw.ProvisionedAt)
}

func (r *gatewayResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var data gatewayModel
	resp.Diagnostics.Append(req.State.Get(ctx, &data)...)
	if resp.Diagnostics.HasError() {
		return
	}

	pd := r.data(&resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}

	if readGateway(ctx, pd, &data, &resp.Diagnostics) {
		resp.State.RemoveResource(ctx)
		return
	}
	if resp.Diagnostics.HasError() {
		return
	}
	resp.Diagnostics.Append(resp.State.Set(ctx, &data)...)
}

func (r *gatewayResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan, state gatewayModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	pd := r.data(&resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}

	orgID := resolveOrgID(ctx, pd.client, plan.Organization, pd.organization, &resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}

	configured, d := instanceSet(ctx, plan.Instances)
	resp.Diagnostics.Append(d...)
	current, d := instanceSet(ctx, state.Instances)
	resp.Diagnostics.Append(d...)
	if resp.Diagnostics.HasError() {
		return
	}

	applyInstanceDiff(ctx, pd, orgID, plan.ID.ValueString(), current, configured, &resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}

	// Fresh read for state — the observer may have moved state or
	// status_message underneath the attach/detach calls. instances is
	// config-authoritative and has no wire source, so the plan's set
	// survives the read untouched.
	readGateway(ctx, pd, &plan, &resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *gatewayResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state gatewayModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	// The honest delete: the /api/v1 route table has no gateway-delete
	// route (the only DELETE is per-attachment), so there is nothing to
	// call. The platform keeps the gateway — serving, attached, and
	// billing. Terraform forgets it; the warning is the record.
	resp.Diagnostics.AddWarning(
		"The access gateway is kept by the platform",
		fmt.Sprintf("The FluxVale API exposes no gateway-delete route, so gateway %s stays provisioned (and billing) "+
			"after this destroy — its attachments too. To actually remove it, opt out via the panel's Access tab, "+
			"then import is unnecessary: just delete this resource from your config.", state.ID.ValueString()),
	)
	resp.State.RemoveResource(ctx)
}

func (r *gatewayResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	// By organization id or slug — the singleton read's path key:
	// terraform import fluxvale_access_gateway.x <org_id_or_slug>.
	// Read fills the wire-mirrored fields; auth_key and instances stay
	// null — keep your config matching what you deployed or the plan
	// will show a replacement.
	resource.ImportStatePassthroughID(ctx, path.Root("organization"), req, resp)
}

// instanceSet converts the schema's instances into a slice. null and
// unknown both mean "nothing configured".
func instanceSet(ctx context.Context, v types.Set) ([]string, diag.Diagnostics) {
	if v.IsNull() || v.IsUnknown() {
		return nil, diag.Diagnostics{}
	}
	var elems []types.String
	diags := v.ElementsAs(ctx, &elems, false)
	if diags.HasError() {
		return nil, diags
	}
	out := make([]string, len(elems))
	for i, val := range elems {
		out[i] = val.ValueString()
	}
	return out, diag.Diagnostics{}
}

// instanceSetDiff computes the attach/detach lists, preserving the
// input order of each side (deterministic call sequences for tests and
// logs).
func instanceSetDiff(current, configured []string) (added, removed []string) {
	currentSet := make(map[string]bool, len(current))
	for _, id := range current {
		currentSet[id] = true
	}
	configuredSet := make(map[string]bool, len(configured))
	for _, id := range configured {
		configuredSet[id] = true
	}
	for _, id := range configured {
		if !currentSet[id] {
			added = append(added, id)
		}
	}
	for _, id := range current {
		if !configuredSet[id] {
			removed = append(removed, id)
		}
	}
	return added, removed
}
