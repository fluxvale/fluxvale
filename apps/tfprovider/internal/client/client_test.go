package client

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// meDocument is the /api/v1/me shape the platform renders (id at
// data.id, email in data.attributes — me_route_test.exs).
const meDocument = `{"data": {"id": "u-1", "type": "user", "attributes": {"email": "me@fluxvale.com", "platform_role": "user", "username": "me"}}}`

func testServer(t *testing.T, status int, body string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		fmt.Fprint(w, body)
	}))
}

func TestMeSendsAuthHeaderAndUserAgent(t *testing.T) {
	var gotAuth, gotAccept, gotUA string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotAccept = r.Header.Get("Accept")
		gotUA = r.Header.Get("User-Agent")
		fmt.Fprint(w, meDocument)
	}))
	defer srv.Close()

	c := New(srv.URL, "fvpat_test", "0.1.0-test", srv.Client())
	me, err := c.Me(context.Background())
	if err != nil {
		t.Fatalf("Me: %v", err)
	}

	if gotAuth != "Bearer fvpat_test" {
		t.Errorf("Authorization = %q, want bearer token", gotAuth)
	}
	if gotAccept != "application/vnd.api+json" {
		t.Errorf("Accept = %q, want JSON:API content type", gotAccept)
	}
	wantUA := "terraform-provider-fluxvale/0.1.0-test (+https://github.com/fluxvale/fluxvale)"
	if gotUA != wantUA {
		t.Errorf("User-Agent = %q, want %q", gotUA, wantUA)
	}
	if me.ID != "u-1" || me.Email != "me@fluxvale.com" {
		t.Errorf("Me = %+v, want id u-1 + email me@fluxvale.com", me)
	}
}

func TestUnauthorizedDecodesIntoTypedError(t *testing.T) {
	doc := `{"errors": [{"title": "Unauthorized", "detail": "invalid or expired token"}]}`
	srv := testServer(t, http.StatusUnauthorized, doc)
	defer srv.Close()

	c := New(srv.URL, "fvpat_bad", "test", srv.Client())
	_, err := c.Me(context.Background())

	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("err = %v, want *APIError", err)
	}
	if apiErr.Status != http.StatusUnauthorized {
		t.Errorf("Status = %d, want 401", apiErr.Status)
	}
	if len(apiErr.Errors) != 1 || apiErr.Errors[0].Title != "Unauthorized" {
		t.Errorf("Errors = %+v, want the server's errors array", apiErr.Errors)
	}
	if !strings.Contains(err.Error(), "invalid or expired token") {
		t.Errorf("Error() = %q, want the server's wording", err.Error())
	}
}

func TestMalformedBodyIsAnError(t *testing.T) {
	srv := testServer(t, http.StatusOK, "<html>not json</html>")
	defer srv.Close()

	c := New(srv.URL, "fvpat_test", "test", srv.Client())
	if _, err := c.Me(context.Background()); err == nil {
		t.Fatal("Me over a malformed body: err = nil, want a decode error")
	}
}

func TestNonJSONErrorBodyStillTyped(t *testing.T) {
	srv := testServer(t, http.StatusBadGateway, "Bad Gateway")
	defer srv.Close()

	c := New(srv.URL, "fvpat_test", "test", srv.Client())
	_, err := c.Me(context.Background())

	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("err = %v, want *APIError", err)
	}
	if apiErr.Status != http.StatusBadGateway {
		t.Errorf("Status = %d, want 502", apiErr.Status)
	}
}
