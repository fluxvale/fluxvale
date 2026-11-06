package provider

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/fluxvale/fluxvale/apps/tfprovider/internal/client"
	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/float64planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/int64planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/mapplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

var _ resource.ResourceWithImportState = (*instanceResource)(nil)

// instanceResource manages fluxvale_instance — an instance of a
// catalog app version. A skin over POST /instances + the lifecycle
// PATCH verbs: every business rule (paywall, allocation bounds,
// version existence) is the server's; a 422 here is the correct
// surface, not something to pre-empt client-side.
type instanceResource struct {
	pd *providerData
}

// NewInstanceResource returns the resource factory provider.go
// registers.
func NewInstanceResource() resource.Resource {
	return &instanceResource{}
}

func (r *instanceResource) Metadata(_ context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_instance"
}

// instanceModel mirrors the schema. Config identity fields
// (organization/app/app_version/app_version_id) and the write-only
// env_vars are never overwritten from the wire; running is the
// desired posture (the observed one is status).
type instanceModel struct {
	Organization types.String  `tfsdk:"organization"`
	Name         types.String  `tfsdk:"name"`
	AppVersionID types.String  `tfsdk:"app_version_id"`
	App          types.String  `tfsdk:"app"`
	AppVersion   types.String  `tfsdk:"app_version"`
	CPUCores     types.Float64 `tfsdk:"cpu_cores"`
	MemoryMB     types.Int64   `tfsdk:"memory_mb"`
	StorageGB    types.Int64   `tfsdk:"storage_gb"`
	EnvVars      types.Map     `tfsdk:"env_vars"`
	Running      types.Bool    `tfsdk:"running"`
	AlwaysOn     types.Bool    `tfsdk:"always_on"`
	Exposure     types.String  `tfsdk:"exposure"`
	ID           types.String  `tfsdk:"id"`
	Slug         types.String  `tfsdk:"slug"`
	Namespace    types.String  `tfsdk:"namespace"`
	Status       types.String  `tfsdk:"status"`
	Port         types.Int64   `tfsdk:"port"`
	Image        types.String  `tfsdk:"image"`
	DeployedAt   types.String  `tfsdk:"deployed_at"`
}

func (r *instanceResource) Schema(_ context.Context, _ resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "An instance of a catalog app version — FluxVale's unit of workload. The version and allocation are create-only (the API has no rename/resize/version-change routes), so changing them replaces the instance.",
		Attributes: map[string]schema.Attribute{
			"organization": schema.StringAttribute{
				Optional: true,
				MarkdownDescription: "Organization to deploy into — its id or slug. Falls back to the provider-level " +
					"`organization`, then to your sole organization (several memberships without a name is an error). " +
					"Changing it replaces the instance (the API has no org-change route).",
				PlanModifiers: []planmodifier.String{stringplanmodifier.RequiresReplace()},
			},
			"name": schema.StringAttribute{
				Required:      true,
				Description:   "The instance's display name. Create-only (no rename route) — changing it replaces the instance.",
				PlanModifiers: []planmodifier.String{stringplanmodifier.RequiresReplace()},
			},
			"app_version_id": schema.StringAttribute{
				Optional: true,
				MarkdownDescription: "The catalog app_version id to deploy. Either this or `app` + `app_version` (a slug " +
					"and version string, resolved through the catalog); if both forms are set this id wins, and neither is an error. " +
					"Create-only (no version-change route) — changing it replaces the instance.",
				PlanModifiers: []planmodifier.String{stringplanmodifier.RequiresReplace()},
			},
			"app": schema.StringAttribute{
				Optional:      true,
				Description:   "Catalog app slug, with app_version, the slug form of app_version_id. Create-only.",
				PlanModifiers: []planmodifier.String{stringplanmodifier.RequiresReplace()},
			},
			"app_version": schema.StringAttribute{
				Optional:      true,
				Description:   "Version string within app, the slug form of app_version_id. Create-only.",
				PlanModifiers: []planmodifier.String{stringplanmodifier.RequiresReplace()},
			},
			"cpu_cores": schema.Float64Attribute{
				Required:      true,
				Description:   "CPU cores (the platform's decimal cpu_cores field). Create-only (no resize route over the API).",
				PlanModifiers: []planmodifier.Float64{float64planmodifier.RequiresReplace()},
			},
			"memory_mb": schema.Int64Attribute{
				Required:      true,
				Description:   "Memory in MB (the platform's memory_mb field). Create-only (no resize route over the API).",
				PlanModifiers: []planmodifier.Int64{int64planmodifier.RequiresReplace()},
			},
			"storage_gb": schema.Int64Attribute{
				Required:      true,
				Description:   "Storage in GB (the platform's storage_gb field). Create-only (no resize route over the API).",
				PlanModifiers: []planmodifier.Int64{int64planmodifier.RequiresReplace()},
			},
			"env_vars": schema.MapAttribute{
				ElementType: types.StringType,
				Optional:    true,
				Sensitive:   true,
				MarkdownDescription: "Environment variables for the deploy (merged over the app version's defaults, " +
					"server-side). Write-only: the API never echoes env_vars, so plan can't see server-side drift by design, " +
					"and the configured value is kept verbatim in state. Changing it replaces the instance (the API only " +
					"accepts env vars at create).",
				PlanModifiers: []planmodifier.Map{mapplanmodifier.RequiresReplace()},
			},
			"running": schema.BoolAttribute{
				Optional:    true,
				Description: "Desired posture — defaults to true. false stops the instance after create; updates flip it via stop/start. The observed state is `status` (the platform's idle sweep may sleep a running instance on its own; this attribute never fights that).",
			},
			"always_on": schema.BoolAttribute{
				Optional:    true,
				Computed:    true,
				Description: "Opt out of scale-to-zero (the platform's always_on). Not accepted at create — applied via PATCH always-on; the state carries the server's value.",
			},
			"exposure": schema.StringAttribute{
				Optional:    true,
				Computed:    true,
				Description: "\"public\" or \"private\" (the platform's exposure; defaults to public). Not accepted at create — applied via PATCH exposure; the state carries the server's value.",
			},
			"id": schema.StringAttribute{
				Computed:    true,
				Description: "The instance id — also the terraform import argument.",
			},
			"slug": schema.StringAttribute{
				Computed:    true,
				Description: "Haikunate-generated slug; doubles as the DNS subdomain.",
			},
			"namespace": schema.StringAttribute{
				Computed:    true,
				Description: "The fluxvale-app-<id> namespace (null until deployed).",
			},
			"status": schema.StringAttribute{
				Computed:    true,
				Description: "The state machine's status: pending → deploying → starting → running ⇄ stopped (error, sleeping, deleting, lost possible).",
			},
			"port": schema.Int64Attribute{
				Computed:    true,
				Description: "The deployed app's port (from the version blueprint).",
			},
			"image": schema.StringAttribute{
				Computed:    true,
				Description: "The deployed image (from the version blueprint).",
			},
			"deployed_at": schema.StringAttribute{
				Computed:    true,
				Description: "When the current deploy was enqueued (null before the first deploy).",
			},
		},
	}
}

func (r *instanceResource) Configure(_ context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
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
func (r *instanceResource) data(diags *diag.Diagnostics) *providerData {
	if r.pd == nil {
		diags.AddError(
			"Provider not configured",
			"The provider was not configured before this resource was used — please report this bug.",
		)
	}
	return r.pd
}

func (r *instanceResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var data instanceModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &data)...)
	if resp.Diagnostics.HasError() {
		return
	}

	pd := r.data(&resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}

	createInstance(ctx, pd, &data, &resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}
	resp.Diagnostics.Append(resp.State.Set(ctx, &data)...)
}

// createInstance POSTs the instance (with the resolved org and
// version), enqueues the deploy, applies the post-create PATCHes, and
// waits for running. The order follows the wire: create leaves the row
// :pending — the deploy trigger enqueues from PATCH deploy, not
// create; always_on/exposure are not create inputs (the action's
// accept list) — they ride their PATCH verbs; stop needs the row
// running, so it comes after the wait.
func createInstance(ctx context.Context, pd *providerData, data *instanceModel, diags *diag.Diagnostics) {
	versionID, err := resolveAppVersionID(ctx, pd.client, data)
	if err != nil {
		diags.AddError("Unable to resolve the app version", err.Error())
		return
	}

	orgID := resolveOrgID(ctx, pd.client, data.Organization, pd.organization, diags)
	if diags.HasError() {
		return
	}

	envVars, d := envVarMap(ctx, data.EnvVars)
	diags.Append(d...)
	if diags.HasError() {
		return
	}

	created, err := pd.client.CreateInstance(ctx, client.CreateInstanceInput{
		Name:           data.Name.ValueString(),
		CPUCores:       data.CPUCores.ValueFloat64(),
		MemoryMB:       data.MemoryMB.ValueInt64(),
		StorageGB:      data.StorageGB.ValueInt64(),
		AppVersionID:   versionID,
		OrganizationID: orgID,
		EnvVars:        envVars,
	})
	if err != nil {
		diags.AddError("Unable to create the Instance", err.Error())
		return
	}
	data.ID = types.StringValue(created.ID)

	// The wire's create lands :pending; deploying needs the PATCH.
	if _, err := pd.client.InstanceAction(ctx, created.ID, "deploy", map[string]any{}); err != nil {
		diags.AddError("Unable to deploy the Instance", deployErr(created.ID, err))
		return
	}

	// always_on/exposure: PATCH only when the config asks for a posture
	// the created row doesn't already have (the defaults are false and
	// public — no PATCH when unset).
	if !data.AlwaysOn.IsNull() && !data.AlwaysOn.IsUnknown() && data.AlwaysOn.ValueBool() != created.AlwaysOn {
		if _, err := pd.client.InstanceAction(ctx, created.ID, "always-on", map[string]any{"always_on": data.AlwaysOn.ValueBool()}); err != nil {
			diags.AddError("Unable to set always_on", deployErr(created.ID, err))
			return
		}
	}
	if !data.Exposure.IsNull() && !data.Exposure.IsUnknown() && data.Exposure.ValueString() != created.Exposure {
		if _, err := pd.client.InstanceAction(ctx, created.ID, "exposure", map[string]any{"exposure": data.Exposure.ValueString()}); err != nil {
			diags.AddError("Unable to set exposure", deployErr(created.ID, err))
			return
		}
	}

	// Wait out the async deploy job. "error" is the only terminal
	// failure status; status_message is admin-hidden, so the status
	// string is the whole story the API tells.
	var lastStatus string
	err = pollWithDeadline(ctx, pd.pollInterval, pd.pollTimeout, func(ctx context.Context) (bool, error) {
		in, err := pd.client.GetInstance(ctx, created.ID)
		if err != nil {
			return false, err
		}
		lastStatus = in.Status
		switch in.Status {
		case "running":
			return true, nil
		case "error":
			return false, fmt.Errorf("the deploy failed — the instance is in error state (status_message is admin-only; see the panel)")
		}
		return false, nil
	})
	if err != nil {
		diags.AddError(
			"Instance deploy did not reach running",
			fmt.Sprintf("instance %s: %v (last status %q)", created.ID, err, lastStatus),
		)
		return
	}

	// The stop verb requires a running row, hence after the wait; the
	// PATCH is synchronous (its response already carries the new
	// status).
	if !desiredRunning(data.Running) {
		if _, err := pd.client.InstanceAction(ctx, created.ID, "stop", map[string]any{}); err != nil {
			diags.AddError("Unable to stop the Instance", deployErr(created.ID, err))
			return
		}
	}

	// Fresh read for state — the deployed detail surface (or the
	// stopped posture, when running=false).
	readInstance(ctx, pd, data, diags)
}

func (r *instanceResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var data instanceModel
	resp.Diagnostics.Append(req.State.Get(ctx, &data)...)
	if resp.Diagnostics.HasError() {
		return
	}

	pd := r.data(&resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}

	if readInstance(ctx, pd, &data, &resp.Diagnostics) {
		resp.State.RemoveResource(ctx)
		return
	}
	if resp.Diagnostics.HasError() {
		return
	}
	resp.Diagnostics.Append(resp.State.Set(ctx, &data)...)
}

// readInstance refreshes the model from GET /instances/:id. It maps
// the detail fields and returns true when the instance is gone
// (404 — the caller removes it from state). Config identity fields
// (organization, app, app_version, app_version_id), the write-only
// env_vars, and the desired-posture running are never touched.
func readInstance(ctx context.Context, pd *providerData, data *instanceModel, diags *diag.Diagnostics) bool {
	in, err := pd.client.GetInstance(ctx, data.ID.ValueString())
	if err != nil {
		var apiErr *client.APIError
		if errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound {
			return true
		}
		diags.AddError("Unable to read the Instance", err.Error())
		return false
	}
	mapInstance(data, in)
	return false
}

// mapInstance writes the wire's detail fields into the model. Fields
// with no wire source stay as they are — env_vars never rides
// responses (hide_fields), so the configured value survives Read
// untouched.
func mapInstance(data *instanceModel, in client.Instance) {
	data.ID = types.StringValue(in.ID)
	data.Name = types.StringValue(in.Name)
	data.Slug = types.StringValue(in.Slug)
	data.Namespace = types.StringPointerValue(in.Namespace)
	data.Status = types.StringValue(in.Status)
	data.AlwaysOn = types.BoolValue(in.AlwaysOn)
	data.Exposure = types.StringValue(in.Exposure)
	data.Image = types.StringPointerValue(in.Image)
	data.Port = types.Int64PointerValue(in.Port)
	data.CPUCores = types.Float64PointerValue(in.CPUCores)
	data.MemoryMB = types.Int64PointerValue(in.MemoryMB)
	data.StorageGB = types.Int64PointerValue(in.StorageGB)
	data.DeployedAt = types.StringPointerValue(in.DeployedAt)
}

func (r *instanceResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan, state instanceModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	pd := r.data(&resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}

	updateInstance(ctx, pd, &plan, &state, &resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

// updateInstance applies the only in-place changes the API has —
// stop/start (running), always-on, exposure — then refreshes from a
// fresh read. Only a set (non-null) plan value is managed; removing an
// attribute stops managing it.
func updateInstance(ctx context.Context, pd *providerData, plan, state *instanceModel, diags *diag.Diagnostics) {
	if !desiredRunning(plan.Running) && desiredRunning(state.Running) {
		if _, err := pd.client.InstanceAction(ctx, plan.ID.ValueString(), "stop", map[string]any{}); err != nil {
			diags.AddError("Unable to stop the Instance", err.Error())
			return
		}
	}
	if desiredRunning(plan.Running) && !desiredRunning(state.Running) {
		if _, err := pd.client.InstanceAction(ctx, plan.ID.ValueString(), "start", map[string]any{}); err != nil {
			diags.AddError("Unable to start the Instance", err.Error())
			return
		}
	}
	if !plan.AlwaysOn.IsNull() && !plan.AlwaysOn.IsUnknown() &&
		(state.AlwaysOn.IsNull() || plan.AlwaysOn.ValueBool() != state.AlwaysOn.ValueBool()) {
		if _, err := pd.client.InstanceAction(ctx, plan.ID.ValueString(), "always-on", map[string]any{"always_on": plan.AlwaysOn.ValueBool()}); err != nil {
			diags.AddError("Unable to set always_on", err.Error())
			return
		}
	}
	if !plan.Exposure.IsNull() && !plan.Exposure.IsUnknown() &&
		(state.Exposure.IsNull() || plan.Exposure.ValueString() != state.Exposure.ValueString()) {
		if _, err := pd.client.InstanceAction(ctx, plan.ID.ValueString(), "exposure", map[string]any{"exposure": plan.Exposure.ValueString()}); err != nil {
			diags.AddError("Unable to set exposure", err.Error())
			return
		}
	}

	readInstance(ctx, pd, plan, diags)
}

func (r *instanceResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state instanceModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	pd := r.data(&resp.Diagnostics)
	if resp.Diagnostics.HasError() {
		return
	}

	deleteInstance(ctx, pd, state.ID, &resp.Diagnostics)
}

// deleteInstance DELETEs and waits out the async teardown — the row
// hard-deletes only when the K8s resources are gone, so "gone" is the
// 404, not the DELETE response.
func deleteInstance(ctx context.Context, pd *providerData, id types.String, diags *diag.Diagnostics) {
	if err := pd.client.DeleteInstance(ctx, id.ValueString()); err != nil {
		diags.AddError("Unable to delete the Instance", err.Error())
		return
	}

	err := pollWithDeadline(ctx, pd.pollInterval, pd.pollTimeout, func(ctx context.Context) (bool, error) {
		_, err := pd.client.GetInstance(ctx, id.ValueString())
		var apiErr *client.APIError
		if errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound {
			return true, nil
		}
		if err != nil {
			return false, err
		}
		return false, nil
	})
	if err != nil {
		diags.AddError(
			"Instance teardown did not finish",
			fmt.Sprintf("instance %s still exists after DELETE: %v", id.ValueString(), err),
		)
	}
}

func (r *instanceResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	// By instance id: terraform import fluxvale_instance.x <id>. Read
	// fills the wire-mirrored fields; identity attributes the API does
	// not echo (organization, app, app_version, app_version_id, env_vars)
	// stay null — keep your config matching what you deployed or the
	// plan will show a replacement.
	resource.ImportStatePassthroughID(ctx, path.Root("id"), req, resp)
}

// resolveAppVersionID resolves the schema's two identity forms to a
// version id: the explicit app_version_id wins; app + app_version
// resolve through the catalog (slug → app, version string → row);
// neither form is an error. A lookup, not a rule — an unknown slug or
// version is the server's 404 surfaced verbatim.
func resolveAppVersionID(ctx context.Context, c *client.Client, data *instanceModel) (string, error) {
	if !data.AppVersionID.IsNull() && !data.AppVersionID.IsUnknown() {
		return data.AppVersionID.ValueString(), nil
	}

	hasApp := !data.App.IsNull() && !data.App.IsUnknown()
	hasVersion := !data.AppVersion.IsNull() && !data.AppVersion.IsUnknown()
	if !hasApp || !hasVersion {
		return "", errors.New("set app_version_id, or both app and app_version (a catalog slug and version string)")
	}

	app, err := c.GetAppBySlug(ctx, data.App.ValueString())
	if err != nil {
		return "", fmt.Errorf("looking up app %q: %w", data.App.ValueString(), err)
	}

	versions, err := c.ListAppVersions(ctx, app.ID)
	if err != nil {
		return "", fmt.Errorf("listing versions of app %q: %w", data.App.ValueString(), err)
	}
	version, ok := client.FindAppVersion(versions, data.AppVersion.ValueString())
	if !ok {
		available := make([]string, 0, len(versions))
		for _, v := range versions {
			available = append(available, v.Version)
		}
		return "", fmt.Errorf("app %q has no version %q (available: %s)",
			data.App.ValueString(), data.AppVersion.ValueString(), strings.Join(available, ", "))
	}
	return version.ID, nil
}

// envVarMap converts the schema's env_vars into the wire map. null ⇒
// nil (omit — the server merges the version's defaults).
func envVarMap(ctx context.Context, v types.Map) (map[string]string, diag.Diagnostics) {
	if v.IsNull() || v.IsUnknown() {
		return nil, diag.Diagnostics{}
	}
	var elems map[string]types.String
	diags := v.ElementsAs(ctx, &elems, false)
	if diags.HasError() {
		return nil, diags
	}
	out := make(map[string]string, len(elems))
	for k, val := range elems {
		out[k] = val.ValueString()
	}
	return out, diag.Diagnostics{}
}

// desiredRunning is the posture a running value asks for: null means
// the default (true).
func desiredRunning(v types.Bool) bool {
	return v.IsNull() || v.IsUnknown() || v.ValueBool()
}

func deployErr(id string, err error) string {
	return fmt.Sprintf("instance %s: %v", id, err)
}
