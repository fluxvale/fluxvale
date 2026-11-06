package provider

import (
	"context"
	"strings"
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

func TestListAppsMapsTheWireFields(t *testing.T) {
	f := newFakeAPI(t)
	f.appsDoc = appsDoc

	diags := &diag.Diagnostics{}
	apps := listApps(context.Background(), f.testClient().client, diags)
	assertNoErrors(t, diags)

	if len(apps) != 2 {
		t.Fatalf("apps = %d rows, want 2", len(apps))
	}
	first := apps[0]
	if first.ID.ValueString() != "app-1" || first.Slug.ValueString() != "forgejo" ||
		first.Name.ValueString() != "Forgejo" {
		t.Errorf("apps[0] = %s/%s/%s, want app-1/forgejo/Forgejo",
			first.ID.ValueString(), first.Slug.ValueString(), first.Name.ValueString())
	}
	if first.Tagline.ValueString() != "Git forge" {
		t.Errorf("tagline = %s, want Git forge", first.Tagline.ValueString())
	}
	if first.FileAccess.ValueBool() {
		t.Errorf("file_access = true, want false")
	}
	// Absent optionals stay null — not empty strings.
	second := apps[1]
	if !second.Tagline.IsNull() || !second.Description.IsNull() {
		t.Errorf("sparse row tagline/description = %s/%s, want nulls",
			second.Tagline.ValueString(), second.Description.ValueString())
	}
	if !second.FileAccess.ValueBool() {
		t.Errorf("file_access = false, want true")
	}
}

func TestListAppVersionsSlugResolutionAndMapping(t *testing.T) {
	f := newFakeAPI(t)
	f.appDoc = appDoc
	f.versionsDoc = versionsDoc

	pd := f.testClient()
	diags := &diag.Diagnostics{}
	versions := listAppVersions(context.Background(), pd.client,
		types.StringValue("forgejo"), types.StringNull(), diags)
	assertNoErrors(t, diags)

	// The slug was resolved through the catalog, not guessed.
	if findOne(t, f.all(), "GET", "/api/v1/apps/forgejo").path == "" {
		t.Error("no GET /apps/forgejo — slug not resolved")
	}
	if findOne(t, f.all(), "GET", "/api/v1/apps/app-1/versions").path == "" {
		t.Error("no GET /apps/app-1/versions")
	}

	if len(versions) != 2 {
		t.Fatalf("versions = %d rows, want 2", len(versions))
	}
	first := versions[0]
	if first.ID.ValueString() != "ver-2" || first.AppID.ValueString() != "app-1" ||
		first.Version.ValueString() != "2.0" {
		t.Errorf("versions[0] = %s/%s/%s, want ver-2/app-1/2.0",
			first.ID.ValueString(), first.AppID.ValueString(), first.Version.ValueString())
	}
	// The decimal default arrives as a string on the wire and maps to a
	// float.
	if first.DefaultCPUCores.ValueFloat64() != 1.5 {
		t.Errorf("default_cpu_cores = %v, want 1.5", first.DefaultCPUCores.ValueFloat64())
	}
	if first.DefaultMemoryMB.ValueInt64() != 512 || first.DefaultStorageGB.ValueInt64() != 2 {
		t.Errorf("default mem/storage = %d/%d, want 512/2",
			first.DefaultMemoryMB.ValueInt64(), first.DefaultStorageGB.ValueInt64())
	}
	if got := envMapOf(t, first.DefaultEnvVars); got["FOO"] != "bar" {
		t.Errorf("default_env_vars = %v, want FOO=bar", got)
	}
	if first.ReleaseNotes.ValueString() != "new" || first.PublishedAt.ValueString() != "2026-02-01T00:00:00Z" {
		t.Errorf("release_notes/published_at = %s/%s, want the mapped values",
			first.ReleaseNotes.ValueString(), first.PublishedAt.ValueString())
	}

	second := versions[1]
	if second.ReleaseNotes.IsNull() || second.PublishedAt.IsNull() {
		// null on the wire stays null in the model
		if !second.ReleaseNotes.IsNull() || !second.PublishedAt.IsNull() {
			t.Errorf("nulls on the wire must stay null: %v/%v", second.ReleaseNotes, second.PublishedAt)
		}
	}
	if second.DefaultStorageGB.ValueInt64() != 0 {
		t.Errorf("default_storage_gb = %d, want 0", second.DefaultStorageGB.ValueInt64())
	}
}

func TestListAppVersionsByIDSkipsTheSlugLookup(t *testing.T) {
	f := newFakeAPI(t)
	f.versionsDoc = versionsDoc

	pd := f.testClient()
	diags := &diag.Diagnostics{}
	versions := listAppVersions(context.Background(), pd.client,
		types.StringNull(), types.StringValue("app-1"), diags)
	assertNoErrors(t, diags)

	if len(versions) != 2 {
		t.Fatalf("versions = %d rows, want 2", len(versions))
	}
	for _, r := range f.all() {
		if strings.HasSuffix(r.path, "/apps/app-1") {
			t.Errorf("unexpected GET %s — the id form needs no catalog lookup", r.path)
		}
	}
}

func TestListAppVersionsInputArity(t *testing.T) {
	f := newFakeAPI(t)
	pd := f.testClient()

	t.Run("both forms", func(t *testing.T) {
		diags := &diag.Diagnostics{}
		listAppVersions(context.Background(), pd.client,
			types.StringValue("forgejo"), types.StringValue("app-1"), diags)
		assertError(t, diags, "exactly one")
	})

	t.Run("neither form", func(t *testing.T) {
		diags := &diag.Diagnostics{}
		listAppVersions(context.Background(), pd.client,
			types.StringNull(), types.StringNull(), diags)
		assertError(t, diags, "Set app or app_id")
	})
}

func TestListAppVersionsUnknownSlugSurfacesServer404(t *testing.T) {
	f := newFakeAPI(t)
	f.appStatus = 404
	f.appDoc = `{"errors": [{"title": "Not Found", "detail": "unknown app"}]}`

	pd := f.testClient()
	diags := &diag.Diagnostics{}
	listAppVersions(context.Background(), pd.client,
		types.StringValue("nope"), types.StringNull(), diags)
	assertError(t, diags, "unknown app")
}
