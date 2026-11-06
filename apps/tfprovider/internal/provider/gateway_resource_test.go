package provider

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/tfsdk"
	"github.com/hashicorp/terraform-plugin-framework/types"
	"github.com/hashicorp/terraform-plugin-go/tftypes"
)

// newSchemadGateway builds the gateway resource with its schema.
func newSchemadGateway(ctx context.Context, t *testing.T) (*gatewayResource, schema.Schema) {
	t.Helper()
	r := NewGatewayResource().(*gatewayResource)
	schemaResp := &resource.SchemaResponse{}
	r.Schema(ctx, resource.SchemaRequest{}, schemaResp)
	if schemaResp.Diagnostics.HasError() {
		t.Fatalf("schema diagnostics: %+v", schemaResp.Diagnostics)
	}
	return r, schemaResp.Schema
}

func gatewayToRaw(ctx context.Context, t *testing.T, sch schema.Schema, data *gatewayModel) tftypes.Value {
	t.Helper()
	st := tfsdk.State{Schema: sch, Raw: tftypes.NewValue(sch.Type().TerraformType(ctx), nil)}
	if diags := st.Set(ctx, data); diags.HasError() {
		t.Fatalf("State.Set: %v", diags)
	}
	return st.Raw
}

func rawToGateway(ctx context.Context, t *testing.T, sch schema.Schema, raw tftypes.Value) gatewayModel {
	t.Helper()
	st := tfsdk.State{Schema: sch, Raw: raw}
	var data gatewayModel
	if diags := st.Get(ctx, &data); diags.HasError() {
		t.Fatalf("State.Get: %v", diags)
	}
	return data
}

// Create over the wrapper: the body grounds the route test's shape —
// tailnet_domain + auth_key (write-only) in attributes, the resolved
// org riding organization_id, and NO monthly_cents (a wire caller must
// not price their own gateway — the create pins the config figure).
func TestGatewayCreateBodyShapeAndState(t *testing.T) {
	ctx := context.Background()
	r, sch := newSchemadGateway(ctx, t)

	f := newFakeAPI(t)
	f.orgsDoc = `{"data": [{"id": "org-1", "type": "organization", "attributes": {"slug": "acme", "name": "Acme"}}]}`
	f.gatewayPostDoc = gatewayProvisioningDoc
	r.pd = f.testClient()

	planData := testGateway()
	req := resource.CreateRequest{
		Plan: tfsdk.Plan{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &planData)},
	}
	resp := &resource.CreateResponse{
		State: tfsdk.State{Schema: sch, Raw: tftypes.NewValue(sch.Type().TerraformType(ctx), nil)},
	}
	r.Create(ctx, req, resp)
	if resp.Diagnostics.HasError() {
		t.Fatalf("Create: %v", resp.Diagnostics)
	}

	post := findOne(t, f.all(), http.MethodPost, "/api/v1/access-gateways")
	attrs := attrsOf(t, post)
	if attrs["tailnet_domain"] != "example.ts.net" || attrs["auth_key"] != "tskey-test" {
		t.Errorf("create attributes = %v, want tailnet_domain + auth_key", attrs)
	}
	if attrs["organization_id"] != "org-1" {
		t.Errorf("organization_id = %v, want the sole org resolved", attrs["organization_id"])
	}
	if _, ok := attrs["monthly_cents"]; ok {
		t.Error("monthly_cents sent at create — the create pins the platform's config price")
	}

	got := rawToGateway(ctx, t, sch, resp.State.Raw)
	if got.ID.ValueString() != "gw-1" || got.State.ValueString() != "provisioning" {
		t.Errorf("id/state = %s/%s, want gw-1/provisioning", got.ID.ValueString(), got.State.ValueString())
	}
	if got.AuthKey.ValueString() != "tskey-test" {
		t.Errorf("auth_key in state = %q, want the configured value kept verbatim", got.AuthKey.ValueString())
	}
	if got.MonthlyCents.ValueInt64() != 500 {
		t.Errorf("monthly_cents = %d, want the wire's 500", got.MonthlyCents.ValueInt64())
	}
}

// Create with instances configured: the attach sequence waits the
// gateway to :active (create lands :provisioning; the observer is the
// only promoter) then POSTs one attachment per id.
func TestGatewayCreateAttachesAfterActive(t *testing.T) {
	ctx := context.Background()
	r, sch := newSchemadGateway(ctx, t)

	f := newFakeAPI(t)
	f.orgsDoc = `{"data": [{"id": "org-1", "type": "organization", "attributes": {"slug": "acme", "name": "Acme"}}]}`
	f.gatewayPostDoc = gatewayProvisioningDoc
	f.gatewayGets = []scriptedResponse{
		script(200, gatewayProvisioningDoc),
		script(200, gatewayActiveDoc),
	}
	r.pd = f.testClient()

	planData := testGateway(func(d *gatewayModel) {
		d.Instances = setInput(t, "inst-a", "inst-b")
	})
	req := resource.CreateRequest{
		Plan: tfsdk.Plan{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &planData)},
	}
	resp := &resource.CreateResponse{
		State: tfsdk.State{Schema: sch, Raw: tftypes.NewValue(sch.Type().TerraformType(ctx), nil)},
	}
	r.Create(ctx, req, resp)
	if resp.Diagnostics.HasError() {
		t.Fatalf("Create: %v", resp.Diagnostics)
	}

	reqs := f.all()

	// Order is the semantics: create → the active-wait GET(s) → the
	// attach POSTs. The first GET must see provisioning, not active —
	// the wait is real, not skipped.
	firstGet := -1
	firstAttach := -1
	for i, req := range reqs {
		if req.method == http.MethodGet && strings.HasSuffix(req.path, "/access-gateway") && firstGet < 0 {
			firstGet = i
		}
		if req.method == http.MethodPost && strings.HasSuffix(req.path, "/attachments") && firstAttach < 0 {
			firstAttach = i
		}
	}
	if firstGet < 0 || firstAttach < 0 || firstAttach < firstGet {
		t.Fatalf("sequence wrong: first GET %d, first attach %d over %+v", firstGet, firstAttach, reqs)
	}

	// Both attachments, data-level instance_id (the generic action's shape).
	var seen []string
	for _, req := range reqs {
		if req.method != http.MethodPost || !strings.HasSuffix(req.path, "/attachments") {
			continue
		}
		data, ok := req.body["data"].(map[string]any)
		if !ok {
			t.Fatalf("attach body has no data object: %+v", req.body)
		}
		seen = append(seen, data["instance_id"].(string))
	}
	if len(seen) != 2 || seen[0] != "inst-a" || seen[1] != "inst-b" {
		t.Errorf("attachments = %v, want inst-a then inst-b at the data level", seen)
	}
}

// The instances diff: one call per changed id — attach the addition,
// detach the removal, never touch the unchanged.
func TestGatewayUpdateAttachmentDiff(t *testing.T) {
	ctx := context.Background()
	r, sch := newSchemadGateway(ctx, t)

	f := newFakeAPI(t)
	f.orgsDoc = `{"data": [{"id": "org-1", "type": "organization", "attributes": {"slug": "acme", "name": "Acme"}}]}`
	f.gatewayGets = []scriptedResponse{script(200, gatewayActiveDoc)}
	r.pd = f.testClient()

	planData := testGateway(func(d *gatewayModel) {
		d.ID = types.StringValue("gw-1")
		d.Instances = setInput(t, "inst-a", "inst-c")
	})
	stateData := testGateway(func(d *gatewayModel) {
		d.ID = types.StringValue("gw-1")
		d.Instances = setInput(t, "inst-a", "inst-b")
	})
	req := resource.UpdateRequest{
		Plan:  tfsdk.Plan{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &planData)},
		State: tfsdk.State{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &stateData)},
	}
	resp := &resource.UpdateResponse{
		State: tfsdk.State{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &planData)},
	}
	r.Update(ctx, req, resp)
	if resp.Diagnostics.HasError() {
		t.Fatalf("Update: %v", resp.Diagnostics)
	}

	reqs := f.all()
	var attached, detached []string
	for _, req := range reqs {
		switch {
		case req.method == http.MethodPost && strings.HasSuffix(req.path, "/attachments"):
			attached = append(attached, req.body["data"].(map[string]any)["instance_id"].(string))
		case req.method == http.MethodDelete && strings.Contains(req.path, "/attachments/"):
			detached = append(detached, strings.TrimPrefix(req.path, "/api/v1/access-gateways/gw-1/attachments/"))
		}
	}
	if len(attached) != 1 || attached[0] != "inst-c" {
		t.Errorf("attached = %v, want exactly [inst-c]", attached)
	}
	if len(detached) != 1 || detached[0] != "inst-b" {
		t.Errorf("detached = %v, want exactly [inst-b]", detached)
	}
	for _, req := range reqs {
		if strings.Contains(req.path, "inst-a") {
			t.Error("inst-a is unchanged — the diff must not re-attach it")
		}
	}

	// State refreshes from the fresh read; the configured set survives.
	got := rawToGateway(ctx, t, sch, resp.State.Raw)
	if got.State.ValueString() != "active" {
		t.Errorf("state = %s, want the fresh read's active", got.State.ValueString())
	}
	if got.AuthKey.ValueString() != "tskey-test" || got.Instances.IsNull() {
		t.Errorf("auth_key/instances = %q/%v, want the configured values kept", got.AuthKey.ValueString(), got.Instances)
	}
}

// No instance change ⇒ no attach/detach calls (the fresh read still
// happens).
func TestGatewayUpdateNoDiffSendsNoAttachmentCalls(t *testing.T) {
	ctx := context.Background()
	r, sch := newSchemadGateway(ctx, t)

	f := newFakeAPI(t)
	f.orgsDoc = `{"data": [{"id": "org-1", "type": "organization", "attributes": {"slug": "acme", "name": "Acme"}}]}`
	f.gatewayGets = []scriptedResponse{script(200, gatewayActiveDoc)}
	r.pd = f.testClient()

	planData := testGateway(func(d *gatewayModel) {
		d.ID = types.StringValue("gw-1")
		d.Instances = setInput(t, "inst-a")
	})
	req := resource.UpdateRequest{
		Plan:  tfsdk.Plan{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &planData)},
		State: tfsdk.State{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &planData)},
	}
	resp := &resource.UpdateResponse{
		State: tfsdk.State{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &planData)},
	}
	r.Update(ctx, req, resp)
	if resp.Diagnostics.HasError() {
		t.Fatalf("Update: %v", resp.Diagnostics)
	}

	for _, req := range f.all() {
		if strings.Contains(req.path, "/attachments") {
			t.Errorf("unexpected %s %s with no set change", req.method, req.path)
		}
	}
}

// Read: the singleton GET resolved through the org (state org unset ⇒
// sole-org fallback), wire fields mapped, write-only/config-only
// values kept — even a hostile auth_key key can't leak.
func TestGatewayReadMapsRowAndKeepsConfig(t *testing.T) {
	ctx := context.Background()
	r, sch := newSchemadGateway(ctx, t)

	f := newFakeAPI(t)
	f.orgsDoc = `{"data": [{"id": "org-1", "type": "organization", "attributes": {"slug": "acme", "name": "Acme"}}]}`
	hostile := strings.ReplaceAll(gatewayActiveDoc, `"state": "active"`,
		`"state": "active", "auth_key": "hostile", "credential_secret_ref": "nope"`)
	f.gatewayGets = []scriptedResponse{script(200, hostile)}
	r.pd = f.testClient()

	stateData := testGateway(func(d *gatewayModel) {
		d.Instances = setInput(t, "inst-a")
	})
	req := resource.ReadRequest{
		State: tfsdk.State{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &stateData)},
	}
	resp := &resource.ReadResponse{
		State: tfsdk.State{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &stateData)},
	}
	r.Read(ctx, req, resp)
	if resp.Diagnostics.HasError() {
		t.Fatalf("Read: %v", resp.Diagnostics)
	}

	get := findOne(t, f.all(), http.MethodGet, "/api/v1/organizations/org-1/access-gateway")
	_ = get

	got := rawToGateway(ctx, t, sch, resp.State.Raw)
	if got.Hostname.ValueString() != "fv-0a1b2c3d" || got.State.ValueString() != "active" {
		t.Errorf("hostname/state = %s/%s, want the wire's", got.Hostname.ValueString(), got.State.ValueString())
	}
	if got.OrganizationID.ValueString() != "org-1" {
		t.Errorf("organization_id = %s, want the wire's echo", got.OrganizationID.ValueString())
	}
	if got.AuthKey.ValueString() != "tskey-test" {
		t.Errorf("auth_key in state = %q, want the configured value kept", got.AuthKey.ValueString())
	}
	if got.Instances.IsNull() {
		t.Error("instances lost from state — the configured set is config-authoritative")
	}
}

// A 404 on the singleton read means the org's gateway is gone.
func TestGatewayRead404Removes(t *testing.T) {
	ctx := context.Background()
	r, sch := newSchemadGateway(ctx, t)

	f := newFakeAPI(t)
	f.orgsDoc = `{"data": [{"id": "org-1", "type": "organization", "attributes": {"slug": "acme", "name": "Acme"}}]}`
	f.gatewayGets = []scriptedResponse{script(http.StatusNotFound, `{"errors": [{"status": "404"}]}`)}
	r.pd = f.testClient()

	stateData := testGateway()
	req := resource.ReadRequest{
		State: tfsdk.State{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &stateData)},
	}
	resp := &resource.ReadResponse{
		State: tfsdk.State{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &stateData)},
	}
	r.Read(ctx, req, resp)
	if resp.Diagnostics.HasError() {
		t.Fatalf("Read: %v", resp.Diagnostics)
	}
	if !resp.State.Raw.IsNull() {
		t.Errorf("state after 404 = %v, want null (removed)", resp.State.Raw)
	}
}

// The honest delete: no gateway-delete route exists on the wire —
// zero HTTP calls, a warning diagnostic, and the resource leaves state.
func TestGatewayDeleteHonesty(t *testing.T) {
	ctx := context.Background()
	r, sch := newSchemadGateway(ctx, t)

	f := newFakeAPI(t)
	r.pd = f.testClient()

	stateData := testGateway(func(d *gatewayModel) { d.ID = types.StringValue("gw-1") })
	req := resource.DeleteRequest{
		State: tfsdk.State{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &stateData)},
	}
	resp := &resource.DeleteResponse{
		State: tfsdk.State{Schema: sch, Raw: gatewayToRaw(ctx, t, sch, &stateData)},
	}
	r.Delete(ctx, req, resp)
	if resp.Diagnostics.HasError() {
		t.Fatalf("Delete errored: %v", resp.Diagnostics)
	}

	if len(f.all()) != 0 {
		t.Errorf("delete made HTTP calls: %+v — the API has no gateway-delete route", f.all())
	}
	found := false
	for _, w := range resp.Diagnostics.Warnings() {
		if strings.Contains(w.Summary(), "kept by the platform") {
			found = true
		}
	}
	if !found {
		t.Errorf("no warning diagnostic: %+v — the keep-on-platform reality must be stated", resp.Diagnostics)
	}
	if !resp.State.Raw.IsNull() {
		t.Errorf("state after delete = %v, want null (removed)", resp.State.Raw)
	}
}

// Import takes the ORG (the singleton read's path key).
func TestGatewayImportByOrg(t *testing.T) {
	ctx := context.Background()
	r, sch := newSchemadGateway(ctx, t)

	req := resource.ImportStateRequest{ID: "org-9"}
	resp := &resource.ImportStateResponse{
		State: tfsdk.State{Schema: sch, Raw: tftypes.NewValue(sch.Type().TerraformType(ctx), nil)},
	}
	r.ImportState(ctx, req, resp)
	if resp.Diagnostics.HasError() {
		t.Fatalf("ImportState: %v", resp.Diagnostics)
	}

	got := rawToGateway(ctx, t, sch, resp.State.Raw)
	if got.Organization.ValueString() != "org-9" {
		t.Errorf("organization = %s, want the import argument", got.Organization.ValueString())
	}
}

// The wait surfaces the observer's failure state with its message.
func TestGatewayWaitSurfacesNeedsAttention(t *testing.T) {
	f := newFakeAPI(t)
	needsAttention := strings.ReplaceAll(gatewayProvisioningDoc, `"state": "provisioning"`, `"state": "needs_attention"`)
	needsAttention = strings.ReplaceAll(needsAttention, `"status_message": null`, `"status_message": "Access setup failed"`)
	f.gatewayGets = []scriptedResponse{script(200, needsAttention)}

	pd := f.testClient()
	diags := &diag.Diagnostics{}
	waitGatewayActive(context.Background(), pd, "org-1", diags)
	assertError(t, diags, "did not become active", "needs_attention", "Access setup failed")
}

func TestGatewayWaitTimeout(t *testing.T) {
	f := newFakeAPI(t)
	f.gatewayGets = []scriptedResponse{script(200, gatewayProvisioningDoc)} // never activates

	pd := f.testClient()
	pd.pollTimeout = 20 * time.Millisecond
	diags := &diag.Diagnostics{}
	waitGatewayActive(context.Background(), pd, "org-1", diags)
	assertError(t, diags, "did not become active", "timed out", `"provisioning"`)
}

// The diff helper: deterministic order on both sides.
func TestInstanceSetDiff(t *testing.T) {
	added, removed := instanceSetDiff(
		[]string{"a", "b", "c"},
		[]string{"c", "d", "a"},
	)
	if strings.Join(added, ",") != "d" {
		t.Errorf("added = %v, want [d]", added)
	}
	if strings.Join(removed, ",") != "b" {
		t.Errorf("removed = %v, want [b]", removed)
	}

	added, removed = instanceSetDiff(nil, []string{"x"})
	if strings.Join(added, ",") != "x" || len(removed) != 0 {
		t.Errorf("from empty current: added = %v, removed = %v, want [x]/[]", added, removed)
	}

	added, removed = instanceSetDiff([]string{"x"}, nil)
	if len(added) != 0 || strings.Join(removed, ",") != "x" {
		t.Errorf("to empty configured: added = %v, removed = %v, want []/[x]", added, removed)
	}
}

// The schema contract: the identity trio replaces (create-only on the
// wire); instances updates live via the pairing verbs; auth_key is
// sensitive.
func TestGatewaySchemaContract(t *testing.T) {
	ctx := context.Background()
	r, sch := newSchemadGateway(ctx, t)

	want := []string{
		"organization", "tailnet_domain", "auth_key", "instances",
		"id", "organization_id", "hostname", "provider", "state",
		"status_message", "monthly_cents", "provisioned_at",
	}
	if len(sch.Attributes) != len(want) {
		t.Fatalf("schema attributes = %d, want exactly %d (%v)", len(sch.Attributes), len(want), want)
	}
	for _, name := range want {
		if _, ok := sch.Attributes[name]; !ok {
			t.Errorf("schema missing attribute %q", name)
		}
	}

	for _, name := range []string{"tailnet_domain", "auth_key"} {
		if !sch.Attributes[name].IsRequired() {
			t.Errorf("%s is not Required", name)
		}
	}
	for _, name := range []string{"organization", "tailnet_domain", "auth_key"} {
		if len(sch.Attributes[name].(schema.StringAttribute).PlanModifiers) == 0 {
			t.Errorf("%s has no plan modifiers (want RequiresReplace — create-only on the wire)", name)
		}
	}
	if len(sch.Attributes["instances"].(schema.SetAttribute).PlanModifiers) != 0 {
		t.Error("instances must update in place (the attach/detach verbs)")
	}
	if !sch.Attributes["auth_key"].IsSensitive() {
		t.Error("auth_key is not sensitive")
	}

	md := &resource.MetadataResponse{}
	r.Metadata(ctx, resource.MetadataRequest{ProviderTypeName: "fluxvale"}, md)
	if md.TypeName != "fluxvale_access_gateway" {
		t.Errorf("TypeName = %q, want fluxvale_access_gateway", md.TypeName)
	}
}
