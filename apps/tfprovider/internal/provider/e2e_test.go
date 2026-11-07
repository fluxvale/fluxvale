package provider

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestRealTofuSmoke is the real-tofu gate: a REAL OpenTofu CLI driving
// the REAL compiled binary end to end against a scripted fake API —
// plan, apply, destroy, exit codes and wire calls asserted. It exists
// because the in-process model tests cannot catch the classes a real
// CLI rejects: the reserved-`provider` root attribute (it sat green in
// the pipeline for two slices until this gate's first run caught it)
// and the unknown-organization class — schema validation and provider
// configuration run on the RPC path, which only a real CLI exercises.
//
// Gated by TFPROVIDER_E2E=1 (set by ci.yml's tfprovider lane; skipped
// locally without it). Requires `tofu` on PATH — `mise install
// opentofu` (the mise.toml pin) — and works offline: no registry
// contact, the fluxvale provider comes from dev_overrides.
//
// NB: with dev_overrides there is deliberately NO `tofu init` — that
// is the documented dev-override workflow (OpenTofu warns that init is
// unnecessary there, and tofu 1.13's init actively errors querying the
// registry for a provider that isn't published).
func TestRealTofuSmoke(t *testing.T) {
	if os.Getenv("TFPROVIDER_E2E") == "" {
		t.Skip("TFPROVIDER_E2E not set — the real-tofu gate runs in CI and via TFPROVIDER_E2E=1 go test -run TestRealTofu")
	}

	tofu, err := exec.LookPath("tofu")
	if err != nil {
		t.Fatalf("tofu not on PATH — mise install opentofu (the mise.toml pin): %v", err)
	}

	// The binary under test, built from the module root (two dirs up
	// from this package) — never a stale checkout copy.
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("module root: %v", err)
	}
	binDir := t.TempDir()
	bin := filepath.Join(binDir, "terraform-provider-fluxvale")
	build := exec.Command("go", "build", "-o", bin, ".")
	build.Dir = root
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}

	fake := newSmokeFake(t)
	work := t.TempDir()

	// dev_overrides: the CLI config lives outside the module; the
	// override dir is the one holding the binary.
	clipath := filepath.Join(work, "tofurc")
	cfg := fmt.Sprintf(`provider_installation {
  dev_overrides {
    "registry.terraform.io/fluxvale/fluxvale" = %q
  }
  direct {}
}
`, binDir)
	if err := os.WriteFile(clipath, []byte(cfg), 0o600); err != nil {
		t.Fatalf("write CLI config: %v", err)
	}

	module := fmt.Sprintf(`
terraform {
  required_providers {
    fluxvale = {
      source = "registry.terraform.io/fluxvale/fluxvale"
    }
  }
}

provider "fluxvale" {
  api_url = %q
  token   = "fvpat_e2e"
}

# The catalog, by slug — the data path a real config rides.
data "fluxvale_app_versions" "test" {
  app = "forgejo"
}

resource "fluxvale_instance" "a" {
  name        = "smoke-a"
  app         = "forgejo"
  app_version = data.fluxvale_app_versions.test.app_versions[0].version
  cpu_cores   = 0.5
  memory_mb   = 256
  storage_gb  = 1
}

# Different size, private, with env vars and a backups row.
resource "fluxvale_instance" "b" {
  name        = "smoke-b"
  app         = "forgejo"
  app_version = data.fluxvale_app_versions.test.app_versions[0].version
  cpu_cores   = 1.0
  memory_mb   = 512
  storage_gb  = 2
  exposure    = "private"
  env_vars    = { SMOKE = "1" }
}

resource "fluxvale_instance_backups" "b" {
  instance_id       = fluxvale_instance.b.id
  endpoint          = "https://acct123.r2.cloudflarestorage.com"
  bucket            = "smoke-bucket"
  access_key_id     = "AKIAIOSFODNN7EXAMPLE"
  secret_access_key = "smoke-secret"
  prefix            = "fluxvale/smoke"
}

resource "fluxvale_access_gateway" "g" {
  tailnet_domain = "smoke.ts.net"
  auth_key       = "tskey-smoke"
  instances      = [fluxvale_instance.b.id]
}
`, fake.URL)
	if err := os.WriteFile(filepath.Join(work, "main.tf"), []byte(module), 0o600); err != nil {
		t.Fatalf("write module: %v", err)
	}

	runTofu := func(args ...string) string {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(ctx, tofu, args...)
		cmd.Dir = work
		cmd.Env = append(os.Environ(), "TF_CLI_CONFIG_FILE="+clipath, "TF_INPUT=0")
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("tofu %s: %v\n%s", strings.Join(args, " "), err, out)
		}
		return string(out)
	}

	plan := runTofu("plan", "-out=tfplan")
	if !strings.Contains(plan, "4 to add") {
		t.Fatalf("plan did not add the four resources:\n%s", plan)
	}
	runTofu("apply", "tfplan")
	runTofu("destroy", "-auto-approve")

	// The wire story: create → posture PATCHes → deploy → backup row →
	// gateway + attach; destroy: forget-only gateway, row DELETE, both
	// instances DELETEd to a polled 404.
	fake.wantCounts(t,
		countExact("POST", "/api/v1/instances", 2),
		countSuffix("PATCH", "/exposure", 1),
		countSuffix("PATCH", "/deploy", 2),
		countSuffix("POST", "/backup-setting", 1),
		countExact("POST", "/api/v1/access-gateways", 1),
		countSuffix("POST", "/attachments", 1),
		countPrefix("DELETE", "/api/v1/instances/", 2),
		countPrefix("DELETE", "/api/v1/backup-settings/", 1),
		countSuffix("DELETE", "/attachments/", 0), // destroy is a state-only forget
	)

	// Both instances' create bodies rode the plan's allocations and the
	// write-only env vars (cpu_cores ships as the wire's decimal
	// string). By NAME, not index: tofu plans independent instances
	// concurrently, so the POSTs arrive in race order.
	fake.wantCreateAttrs(t, "smoke-a", "cpu_cores", "0.5", "memory_mb", "256", "storage_gb", "1")
	fake.wantCreateAttrs(t, "smoke-b", "cpu_cores", "1", "memory_mb", "512", "storage_gb", "2")
	envVars := fattrs(t, fake.createNamed(t, "smoke-b"))["env_vars"]
	if m, ok := envVars.(map[string]any); !ok || m["SMOKE"] != "1" {
		t.Fatalf("instance b create env_vars = %#v, want SMOKE=1", envVars)
	}

	// The version wiring, end to end: the binary's User-Agent carries
	// the const (internal/provider/version.go) — the release workflow's
	// -version proof and this are the same source.
	ua := fake.nthReq(t, "GET", "/api/v1/me").userAgent
	if !strings.HasPrefix(ua, "terraform-provider-fluxvale/"+Version) {
		t.Fatalf("User-Agent = %q, want the terraform-provider-fluxvale/%s prefix", ua, Version)
	}
}

// --- the smoke fake ---------------------------------------------------
// A scripted FluxVale API in the same discipline as fake_test.go, but
// deliberately self-contained: this file must not share its fixtures or
// mutate them (fake_test.go carries in-flight changes on other slices).

type smokeFake struct {
	*httptest.Server

	mu   sync.Mutex
	reqs []smokeReq

	// per-script GET queues — instance ids (seeded per create) and the
	// org-gateway singleton; the last entry repeats, the poll loops'
	// steady state
	gets map[string][]smokeResp
}

type smokeReq struct {
	method, path, auth, userAgent string
	body                          map[string]any
}

type smokeResp struct {
	status int
	body   string
}

type smokeCount struct {
	// how to match: exact path, prefix, or suffix (verb actions ride
	// /instances/{id}/{action}, so suffix is how you count them)
	mode, method, path string
	n                  int
}

func countExact(method, path string, n int) smokeCount {
	return smokeCount{"exact", method, path, n}
}

func countPrefix(method, path string, n int) smokeCount {
	return smokeCount{"prefix", method, path, n}
}

func countSuffix(method, path string, n int) smokeCount {
	return smokeCount{"suffix", method, path, n}
}

func newSmokeFake(t *testing.T) *smokeFake {
	f := &smokeFake{
		gets: map[string][]smokeResp{
			// The org-gateway script: create lands :provisioning; the
			// attach waits the observer's promotion to :active, then the
			// final read + destroy refresh ride the repeating active.
			"org-gateway": {r200(smokeGatewayDoc("provisioning")), r200(smokeGatewayDoc("active"))},
			// The backups row: create POSTs it; destroy's refresh READS
			// it by instance (reads go by instance_id) before the DELETE.
			"inst-2/backup-setting": {r200(smokeBackupDoc())},
		},
		// Instance GET scripts are seeded per create (see the POST
		// handler): apply's wait + final read, then destroy's refresh +
		// the polled 404 — the last entry repeats for safety.
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/api/v1/me", func(w http.ResponseWriter, r *http.Request) {
		f.record(r, nil)
		f.json(w, http.StatusOK, `{"data": {"id": "user-1", "type": "user", "attributes": {"email": "owner@example.com"}}}`)
	})
	mux.HandleFunc("/api/v1/organizations", func(w http.ResponseWriter, r *http.Request) {
		f.record(r, nil)
		f.json(w, http.StatusOK, `{"data": [{"id": "org-1", "type": "organization", "attributes": {"slug": "acme", "name": "Acme"}}]}`)
	})
	mux.HandleFunc("/api/v1/apps", func(w http.ResponseWriter, r *http.Request) {
		f.record(r, nil)
		f.json(w, http.StatusOK, `{"data": [{"id": "app-1", "type": "app", "attributes": {"name": "Forgejo", "slug": "forgejo", "file_access": false}}]}`)
	})
	mux.HandleFunc("/api/v1/apps/", func(w http.ResponseWriter, r *http.Request) {
		f.record(r, nil)
		if strings.HasSuffix(r.URL.Path, "/versions") {
			f.json(w, http.StatusOK, `{"data": [{"id": "ver-1", "type": "app_version", "attributes": {
				"app_id": "app-1", "version": "1.0", "image": "reg/app:1.0", "port": 3000,
				"healthcheck_path": "/", "storage_mount_path": "/data",
				"default_cpu_cores": "0.5", "default_memory_mb": 256, "default_storage_gb": 1,
				"default_env_vars": {}, "published_at": null}}]}`)
			return
		}
		f.json(w, http.StatusOK, `{"data": {"id": "app-1", "type": "app", "attributes": {"name": "Forgejo", "slug": "forgejo", "file_access": false}}}`)
	})

	// Instance create: the response ECHOES the request — the real API
	// returns the row it created, and tofu plans independent instances
	// concurrently, so a response queue would pop in race order (the
	// first run of this gate caught exactly that swap).
	mux.HandleFunc("POST /api/v1/instances", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.record(r, body)
		attrs, _ := body["data"].(map[string]any)["attributes"].(map[string]any)
		id := smokeInstanceID(t, fmt.Sprint(attrs["name"]))
		f.mu.Lock()
		defer f.mu.Unlock()
		f.gets[id] = []smokeResp{
			r200(smokeInstanceDoc(id, "running")), r200(smokeInstanceDoc(id, "running")), r200(smokeInstanceDoc(id, "running")),
			{http.StatusNotFound, `{"errors": [{"title": "Not Found"}]}`},
		}
		f.json(w, http.StatusCreated, smokeCreateDoc(id, attrs))
	})

	// Instance detail: per-id script for GETs; the posture/deploy/stop
	// PATCH verbs answer a full parseable doc (the create path discards
	// them but the client still parses).
	mux.HandleFunc("/api/v1/instances/", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if r.Body != nil {
			_ = json.NewDecoder(r.Body).Decode(&body)
		}
		f.record(r, body)
		id := strings.TrimPrefix(r.URL.Path, "/api/v1/instances/")
		switch r.Method {
		case http.MethodGet:
			f.scripted(w, id)
		case http.MethodDelete:
			f.json(w, http.StatusOK, smokeInstanceDoc(id, "pending"))
		case http.MethodPatch:
			f.json(w, http.StatusOK, smokeInstanceDoc(id, "running"))
		default:
			f.json(w, http.StatusMethodNotAllowed, `{"errors": [{"title": "Method Not Allowed"}]}`)
		}
	})

	// Backups: the routed settings family — create + delete cover the
	// smoke's path (reads are update/import-only).
	mux.HandleFunc("POST /api/v1/instances/{id}/backup-setting", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.record(r, body)
		f.json(w, http.StatusCreated, smokeBackupDoc())
	})
	mux.HandleFunc("/api/v1/backup-settings/", func(w http.ResponseWriter, r *http.Request) {
		f.record(r, nil)
		if r.Method == http.MethodDelete {
			f.json(w, http.StatusOK, `{"meta": {"message": "deleted"}}`)
			return
		}
		f.json(w, http.StatusMethodNotAllowed, `{"errors": [{"title": "Method Not Allowed"}]}`)
	})

	// Gateway: singleton read (scripted), create, pairing verbs.
	mux.HandleFunc("GET /api/v1/organizations/{org}/access-gateway", func(w http.ResponseWriter, r *http.Request) {
		f.record(r, nil)
		f.scripted(w, "org-gateway")
	})
	mux.HandleFunc("POST /api/v1/access-gateways", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.record(r, body)
		f.json(w, http.StatusCreated, smokeGatewayDoc("provisioning"))
	})
	mux.HandleFunc("POST /api/v1/access-gateways/{id}/attachments", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.record(r, body)
		instanceID, _ := body["data"].(map[string]any)["instance_id"].(string)
		f.json(w, http.StatusCreated, fmt.Sprintf(`{"gateway_id": "gw-1", "instance_id": %q, "route_key": "8443"}`, instanceID))
	})
	mux.HandleFunc("DELETE /api/v1/access-gateways/{id}/attachments/{iid}", func(w http.ResponseWriter, r *http.Request) {
		f.record(r, nil)
		f.json(w, http.StatusOK, `{"success": true}`)
	})

	f.Server = httptest.NewServer(mux)
	t.Cleanup(f.Close)
	return f
}

func r200(body string) smokeResp { return smokeResp{http.StatusOK, body} }

func (f *smokeFake) record(r *http.Request, body map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reqs = append(f.reqs, smokeReq{
		method: r.Method, path: r.URL.Path,
		auth: r.Header.Get("Authorization"), userAgent: r.Header.Get("User-Agent"),
		body: body,
	})
}

// scripted pops the script's next response; the last entry repeats so
// poll loops and refresh reads hit a steady state.
func (f *smokeFake) scripted(w http.ResponseWriter, id string) {
	f.mu.Lock()
	script := f.gets[id]
	if len(script) == 0 {
		f.mu.Unlock()
		f.json(w, http.StatusInternalServerError, fmt.Sprintf(`{"errors": [{"title": "no GET script for %s"}]}`, id))
		return
	}
	resp := script[0]
	if len(script) > 1 {
		f.gets[id] = script[1:]
	}
	f.mu.Unlock()
	f.json(w, resp.status, resp.body)
}

func (f *smokeFake) json(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/vnd.api+json")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(body))
}

func (f *smokeFake) all() []smokeReq {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]smokeReq(nil), f.reqs...)
}

// wantCounts asserts every count spec; a miss dumps the full traffic
// list (triage data, not a bare number).
func (f *smokeFake) wantCounts(t *testing.T, want ...smokeCount) {
	t.Helper()
	for _, w := range want {
		got := 0
		for _, r := range f.all() {
			if r.method != w.method {
				continue
			}
			switch w.mode {
			case "exact":
				if r.path == w.path {
					got++
				}
			case "prefix":
				if strings.HasPrefix(r.path, w.path) {
					got++
				}
			case "suffix":
				if strings.HasSuffix(r.path, w.path) {
					got++
				}
			}
		}
		if got != w.n {
			t.Errorf("%s ~%q (%s): %d calls, want %d\nfull traffic:\n%s", w.method, w.path, w.mode, got, w.n, f.trafficDump())
		}
	}
}

func (f *smokeFake) trafficDump() string {
	var b strings.Builder
	for _, r := range f.all() {
		fmt.Fprintf(&b, "%s %s\n", r.method, r.path)
	}
	return b.String()
}

// createNamed returns the instance create whose body carries the
// name — order-independent (independent creates apply concurrently).
func (f *smokeFake) createNamed(t *testing.T, name string) smokeReq {
	t.Helper()
	for _, r := range f.all() {
		if r.method != "POST" || r.path != "/api/v1/instances" {
			continue
		}
		if attrs, ok := fattrs(t, r)["name"].(string); ok && attrs == name {
			return r
		}
	}
	t.Fatalf("no instance create named %q among the recorded traffic", name)
	return smokeReq{}
}

func (f *smokeFake) nthReq(t *testing.T, method, path string, nth ...int) smokeReq {
	t.Helper()
	want := 0
	if len(nth) > 0 {
		want = nth[0]
	}
	seen := 0
	for _, r := range f.all() {
		if r.method == method && r.path == path {
			if seen == want {
				return r
			}
			seen++
		}
	}
	t.Fatalf("no %s %s #%d among the recorded traffic", method, path, want)
	return smokeReq{}
}

// fattrs digs the attributes object out of a recorded JSON:API body.
func fattrs(t *testing.T, r smokeReq) map[string]any {
	t.Helper()
	data, ok := r.body["data"].(map[string]any)
	if !ok {
		t.Fatalf("%s %s: body has no data object: %#v", r.method, r.path, r.body)
	}
	attrs, _ := data["attributes"].(map[string]any)
	return attrs
}

// wantCreateAttrs asserts attribute values on the named instance's
// create body, string-compared through fmt.Sprint (numbers and decimal
// strings print the same way for the fixtures used here).
func (f *smokeFake) wantCreateAttrs(t *testing.T, name string, pairs ...string) {
	t.Helper()
	attrs := fattrs(t, f.createNamed(t, name))
	for i := 0; i+1 < len(pairs); i += 2 {
		key, want := pairs[i], pairs[i+1]
		if got := fmt.Sprint(attrs[key]); got != want {
			t.Errorf("create %q %s = %#v, want %s", name, key, attrs[key], want)
		}
	}
}

// smokeInstanceID maps a create body's name to the fake's row id —
// stable per instance, so the per-id GET scripts match.
func smokeInstanceID(t *testing.T, name string) string {
	t.Helper()
	switch name {
	case "smoke-a":
		return "inst-1"
	case "smoke-b":
		return "inst-2"
	}
	t.Fatalf("unexpected instance name %q — the smoke module's names are the fake's contract", name)
	return ""
}

// smokeCreateDoc echoes a create request's attributes back as the
// pending row (the real API's create response): the client maps it
// into state immediately, then the final read refines it.
func smokeCreateDoc(id string, attrs map[string]any) string {
	envVars := "null"
	if m, ok := attrs["env_vars"].(map[string]any); ok && len(m) > 0 {
		b, _ := json.Marshal(m)
		envVars = string(b)
	}
	return fmt.Sprintf(`{"data": {"id": %q, "type": "instance", "attributes": {
		"name": %q, "slug": "velvety-otter-%s", "namespace": null,
		"status": "pending", "exposure": "public", "always_on": false,
		"image": "reg/app:1.0", "port": 3000, "healthcheck_path": "/",
		"storage_mount_path": "/data", "file_access": false,
		"cpu_cores": %#v, "memory_mb": %#v, "storage_gb": %#v, "deployed_at": null,
		"organization_id": "org-1", "app_version_id": %q, "env_vars": %s}}}`,
		id, attrs["name"], strings.TrimPrefix(id, "inst-"),
		attrs["cpu_cores"], attrs["memory_mb"], attrs["storage_gb"],
		attrs["app_version_id"], envVars)
}

// smokeInstanceDoc renders the detail surface the client parses —
// INCLUDING the FK ids the real API echoes on reads via the sparse
// fieldset (organization_id, app_version_id): they fill the computed
// app_version_id, whose plan value is unknown for the slug form. A doc
// without them is an API the provider legitimately fails on.
//
// Name, exposure, and allocation echo per id — the real API echoes
// what the create actually made, and tofu's apply consistency check
// holds state to the plan's values (a canned one-shape doc would fail
// it, which is exactly the drift this gate is built to surface).
func smokeInstanceDoc(id, status string) string {
	name, exposure, cpu, mem, storage := "smoke-a", "public", "0.5", 256, 1
	if id == "inst-2" {
		name, exposure, cpu, mem, storage = "smoke-b", "private", "1", 512, 2
	}
	return fmt.Sprintf(`{"data": {"id": %q, "type": "instance", "attributes": {
		"name": %q, "slug": "velvety-otter-%s", "namespace": null,
		"status": %q, "exposure": %q, "always_on": false,
		"image": "reg/app:1.0", "port": 3000, "healthcheck_path": "/",
		"storage_mount_path": "/data", "file_access": false,
		"cpu_cores": %q, "memory_mb": %d, "storage_gb": %d, "deployed_at": null,
		"organization_id": "org-1", "app_version_id": "ver-1"}}}`,
		id, name, strings.TrimPrefix(id, "inst-"), status, exposure, cpu, mem, storage)
}

func smokeBackupDoc() string {
	return `{"data": {"id": "bs-1", "type": "backup_setting", "attributes": {
		"instance_id": "inst-2", "endpoint": "https://acct123.r2.cloudflarestorage.com",
		"bucket": "smoke-bucket", "prefix": "fluxvale/smoke",
		"access_key_id": "AKIAIOSFODNN7EXAMPLE", "retention_keep": 7, "enabled": true}}}`
}

func smokeGatewayDoc(state string) string {
	doc := fmt.Sprintf(`{"data": {"id": "gw-1", "type": "access_gateway", "attributes": {
		"organization_id": "org-1", "hostname": "fv-0a1b2c3d", "tailnet_domain": "smoke.ts.net",
		"provider": "tailscale", "state": %q, "status_message": null,
		"monthly_cents": 500`, state)
	if state == "active" {
		doc += `, "provisioned_at": "2026-11-07T10:00:00Z"`
	}
	return doc + `}}}`
}
