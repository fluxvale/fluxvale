package provider

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/fluxvale/fluxvale/apps/tfprovider/internal/client"
	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

// fakeAPI is a scripted FluxVale API: it records every request and
// serves canned JSON per route. GET /api/v1/instances/:id walks a
// scripted status sequence (last entry repeats — the poll loop's
// steady state), so create-wait and delete-poll tests script the
// transition they need.
type fakeAPI struct {
	*httptest.Server

	mu       sync.Mutex
	requests []recordedRequest

	// routes
	orgsDoc      string
	appsDoc      string
	appDoc       string // GET /apps/:slug
	appStatus    int
	versionsDoc  string
	postResponse string // POST /instances (201)
	instanceGets []scriptedResponse
	deleteStatus int
	// failPatch/failPatchStatus: when a PATCH path carries this suffix,
	// the fake answers with this status and an errors body — the
	// PATCH-failure arm.
	failPatch       string
	failPatchStatus int

	t *testing.T
}

type recordedRequest struct {
	method, path, auth string
	body               map[string]any
}

type scriptedResponse struct {
	status int
	body   string
}

func newFakeAPI(t *testing.T) *fakeAPI {
	t.Helper()
	f := &fakeAPI{t: t, deleteStatus: http.StatusOK}
	mux := http.NewServeMux()

	mux.HandleFunc("/api/v1/organizations", func(w http.ResponseWriter, r *http.Request) {
		f.record(r, nil)
		f.json(w, http.StatusOK, f.orgsDoc)
	})
	mux.HandleFunc("/api/v1/apps", func(w http.ResponseWriter, r *http.Request) {
		f.record(r, nil)
		f.json(w, http.StatusOK, f.appsDoc)
	})
	mux.HandleFunc("/api/v1/apps/", func(w http.ResponseWriter, r *http.Request) {
		f.record(r, nil)
		// /apps/<slug> vs /apps/<id>/versions — the version suffix wins.
		if strings.HasSuffix(r.URL.Path, "/versions") {
			f.json(w, http.StatusOK, f.versionsDoc)
			return
		}
		status := f.appStatus
		if status == 0 {
			status = http.StatusOK
		}
		f.json(w, status, f.appDoc)
	})
	mux.HandleFunc("/api/v1/instances", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			f.json(w, http.StatusMethodNotAllowed, `{"errors": [{"title": "Method Not Allowed"}]}`)
			return
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.record(r, body)
		f.json(w, http.StatusCreated, f.postResponse)
	})
	mux.HandleFunc("/api/v1/instances/", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if r.Body != nil {
			_ = json.NewDecoder(r.Body).Decode(&body)
		}
		f.record(r, body)
		switch r.Method {
		case http.MethodGet:
			f.mu.Lock()
			defer f.mu.Unlock()
			if len(f.instanceGets) == 0 {
				f.t.Errorf("GET %s: no scripted response left", r.URL.Path)
				f.json(w, http.StatusInternalServerError, `{"errors": [{"title": "script ran dry"}]}`)
				return
			}
			resp := f.instanceGets[0]
			if len(f.instanceGets) > 1 {
				f.instanceGets = f.instanceGets[1:]
			}
			f.json(w, resp.status, resp.body)
		case http.MethodDelete:
			f.json(w, f.deleteStatus, `{"id": "inst-1", "status": "pending"}`)
		case http.MethodPatch:
			if f.failPatch != "" && strings.HasSuffix(r.URL.Path, f.failPatch) {
				f.json(w, f.failPatchStatus, `{"errors": [{"title": "Forbidden", "detail": "token is missing the required scope"}]}`)
				return
			}
			f.json(w, http.StatusOK, patchResponse)
		default:
			f.json(w, http.StatusMethodNotAllowed, `{"errors": [{"title": "Method Not Allowed"}]}`)
		}
	})

	f.Server = httptest.NewServer(mux)
	t.Cleanup(f.Close)
	return f
}

func (f *fakeAPI) json(w http.ResponseWriter, status int, body string) {
	w.WriteHeader(status)
	_, _ = w.Write([]byte(body))
}

// handle wraps a mux handler with recording.
func (f *fakeAPI) record(r *http.Request, body map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.requests = append(f.requests, recordedRequest{
		method: r.Method, path: r.URL.Path, auth: r.Header.Get("Authorization"), body: body,
	})
}

func (f *fakeAPI) all() []recordedRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]recordedRequest(nil), f.requests...)
}

// testClient returns a providerData wired to the fake with fast poll
// pacing.
func (f *fakeAPI) testClient() *providerData {
	return &providerData{
		client:       client.New(f.URL, "fvpat_test", "test", f.Client()),
		pollInterval: time.Millisecond,
		pollTimeout:  100 * time.Millisecond,
	}
}

// --- fixtures --------------------------------------------------------

// Wire docs, shaped from the platform's own route tests + open_api.json.
const (
	orgsDoc = `{"data": [
		{"id": "org-1", "type": "organization", "attributes": {"slug": "acme", "name": "Acme"}},
		{"id": "org-2", "type": "organization", "attributes": {"slug": "b-co", "name": "B Co"}}
	]}`

	appDoc = `{"data": {"id": "app-1", "type": "app", "attributes": {"name": "Forgejo", "slug": "forgejo",
		"tagline": "Git forge", "description": "Self-hosted forge", "icon_url": null,
		"source_url": null, "docs_url": null, "file_access": false}}}`

	appsDoc = `{"data": [
		{"id": "app-1", "type": "app", "attributes": {"name": "Forgejo", "slug": "forgejo",
			"tagline": "Git forge", "description": "Self-hosted forge", "icon_url": null,
			"source_url": null, "docs_url": null, "file_access": false}},
		{"id": "app-2", "type": "app", "attributes": {"name": "Memos", "slug": "memos", "file_access": true}}
	]}`

	versionsDoc = `{"data": [
		{"id": "ver-2", "type": "app_version", "attributes": {"app_id": "app-1", "version": "2.0",
			"image": "reg/app:2.0", "port": 3000, "healthcheck_path": "/", "storage_mount_path": "/data",
			"default_cpu_cores": "1.5", "default_memory_mb": 512, "default_storage_gb": 2,
			"default_env_vars": {"FOO": "bar"}, "release_notes": "new", "published_at": "2026-02-01T00:00:00Z"}},
		{"id": "ver-1", "type": "app_version", "attributes": {"app_id": "app-1", "version": "1.0",
			"image": "reg/app:1.0", "port": 3000, "healthcheck_path": "/", "storage_mount_path": "/data",
			"default_cpu_cores": "0.5", "default_memory_mb": 256, "default_storage_gb": 0,
			"default_env_vars": {}, "release_notes": null, "published_at": null}}
	]}`

	// The create response: status pending, namespace/deployed_at null,
	// image/port derived server-side.
	createResponse = `{"data": {"id": "inst-1", "type": "instance", "attributes": {
		"name": "Blog", "slug": "velvety-otter-1234", "namespace": null,
		"status": "pending", "exposure": "public", "always_on": false,
		"image": "reg/app:1.0", "port": 3000, "healthcheck_path": "/",
		"storage_mount_path": "/data", "file_access": false,
		"cpu_cores": "0.5", "memory_mb": 256, "storage_gb": 1, "deployed_at": null}}}`

	runningDoc = `{"data": {"id": "inst-1", "type": "instance", "attributes": {
		"name": "Blog", "slug": "velvety-otter-1234", "namespace": "fluxvale-app-inst-1",
		"status": "running", "exposure": "public", "always_on": false,
		"image": "reg/app:1.0", "port": 3000, "healthcheck_path": "/",
		"storage_mount_path": "/data", "file_access": false,
		"cpu_cores": "0.5", "memory_mb": 256, "storage_gb": 1,
		"deployed_at": "2026-11-06T10:00:00Z",
		"organization_id": "org-1", "app_version_id": "ver-1"}}}`

	stoppedDoc = `{"data": {"id": "inst-1", "type": "instance", "attributes": {
		"name": "Blog", "slug": "velvety-otter-1234", "namespace": "fluxvale-app-inst-1",
		"status": "stopped", "exposure": "public", "always_on": false,
		"image": "reg/app:1.0", "port": 3000, "healthcheck_path": "/",
		"storage_mount_path": "/data", "file_access": false,
		"cpu_cores": "0.5", "memory_mb": 256, "storage_gb": 1,
		"deployed_at": "2026-11-06T10:00:00Z",
		"organization_id": "org-1", "app_version_id": "ver-1"}}}`

	errorDoc = `{"data": {"id": "inst-1", "type": "instance", "attributes": {
		"name": "Blog", "slug": "velvety-otter-1234", "namespace": "fluxvale-app-inst-1",
		"status": "error", "exposure": "public", "always_on": false,
		"image": "reg/app:1.0", "port": 3000, "healthcheck_path": "/",
		"storage_mount_path": "/data", "file_access": false,
		"cpu_cores": "0.5", "memory_mb": 256, "storage_gb": 1,
		"deployed_at": "2026-11-06T10:00:00Z",
		"organization_id": "org-1", "app_version_id": "ver-1"}}}`

	patchResponse = runningDoc
)

// statusDoc renders the running fixture with a different status — the
// precondition/wait scripts' building block.
func statusDoc(status string) string {
	return strings.ReplaceAll(runningDoc, `"running"`, `"`+status+`"`)
}

// fake doc builders for scripted GET sequences.
func script(status int, doc string) scriptedResponse {
	return scriptedResponse{status: status, body: doc}
}

// --- model helpers ---------------------------------------------------

// testInstance builds an instanceModel with the required fields set;
// mutators adjust the rest.
func testInstance(mutators ...func(*instanceModel)) instanceModel {
	data := instanceModel{
		Organization: types.StringNull(),
		Name:         types.StringValue("Blog"),
		AppVersionID: types.StringValue("ver-1"),
		App:          types.StringNull(),
		AppVersion:   types.StringNull(),
		CPUCores:     types.Float64Value(0.5),
		MemoryMB:     types.Int64Value(256),
		StorageGB:    types.Int64Value(1),
		EnvVars:      types.MapNull(types.StringType),
		Running:      types.BoolNull(),
		AlwaysOn:     types.BoolNull(),
		Exposure:     types.StringNull(),
		ID:           types.StringNull(),
		Slug:         types.StringNull(),
		Namespace:    types.StringNull(),
		Status:       types.StringNull(),
		Port:         types.Int64Null(),
		Image:        types.StringNull(),
		DeployedAt:   types.StringNull(),
	}
	for _, m := range mutators {
		m(&data)
	}
	return data
}

// envVarInput wraps a plain map into the schema's env_vars types.Map.
func envVarInput(t *testing.T, m map[string]string) types.Map {
	t.Helper()
	v, diags := types.MapValueFrom(context.Background(), types.StringType, m)
	if diags.HasError() {
		t.Fatalf("MapValueFrom: %v", diags)
	}
	return v
}

// assertNoErrors fails the test when the diagnostics carry errors.
func assertNoErrors(t *testing.T, diags *diag.Diagnostics) {
	t.Helper()
	if diags.HasError() {
		t.Fatalf("unexpected error diagnostics: %v", diags)
	}
}

// assertError fails the test unless the diagnostics carry an error
// whose summary+detail contain every needle.
func assertError(t *testing.T, diags *diag.Diagnostics, needles ...string) {
	t.Helper()
	if !diags.HasError() {
		t.Fatalf("expected error diagnostics containing %v, got none", needles)
	}
	joined := ""
	for _, d := range diags.Errors() {
		joined += d.Summary() + " | " + d.Detail() + "\n"
	}
	for _, needle := range needles {
		if !strings.Contains(joined, needle) {
			t.Fatalf("diagnostics = %q, want something containing %q", joined, needle)
		}
	}
}

// findOne returns the first recorded request matching method+suffix.
func findOne(t *testing.T, reqs []recordedRequest, method, pathSuffix string) recordedRequest {
	t.Helper()
	for _, r := range reqs {
		if r.method == method && strings.HasSuffix(r.path, pathSuffix) {
			return r
		}
	}
	t.Fatalf("no %s %s among %+v", method, pathSuffix, reqs)
	return recordedRequest{}
}

// attrsOf digs the attributes object out of a recorded JSON:API body.
func attrsOf(t *testing.T, r recordedRequest) map[string]any {
	t.Helper()
	data, ok := r.body["data"].(map[string]any)
	if !ok {
		t.Fatalf("%s %s: body has no data object: %+v", r.method, r.path, r.body)
	}
	attrs, _ := data["attributes"].(map[string]any)
	return attrs
}

// envMapOf reads a types.Map back into a plain map for assertions.
func envMapOf(t *testing.T, m types.Map) map[string]string {
	t.Helper()
	if m.IsNull() {
		return nil
	}
	var elems map[string]types.String
	diags := m.ElementsAs(context.Background(), &elems, false)
	if diags.HasError() {
		t.Fatalf("ElementsAs: %v", diags)
	}
	out := make(map[string]string, len(elems))
	for k, v := range elems {
		out[k] = v.ValueString()
	}
	return out
}
