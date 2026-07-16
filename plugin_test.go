package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/maximhq/bifrost/core/schemas"
)

func TestPreLLMHookRefreshesAndShapesCodexRequest(t *testing.T) {
	fixedNow := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	oldNow, oldURL, oldClient := now, oauthURL, httpClient
	now = func() time.Time { return fixedNow }
	t.Cleanup(func() { now, oauthURL, httpClient = oldNow, oldURL, oldClient })

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if len(body) != 3 || body["client_id"] != clientID || body["grant_type"] != "refresh_token" {
			t.Fatalf("unexpected refresh request: %#v", body)
		}
		if body["refresh_token"] != "old-refresh" {
			t.Fatalf("refresh_token = %q", body["refresh_token"])
		}
		_ = json.NewEncoder(w).Encode(map[string]string{
			"access_token":  testJWT(fixedNow.Add(time.Hour), "account-1"),
			"refresh_token": "new-refresh",
			"id_token":      testJWT(fixedNow.Add(time.Hour), "account-1"),
		})
	}))
	defer server.Close()
	oauthURL, httpClient = server.URL, server.Client()

	codexHome := t.TempDir()
	t.Setenv("CODEX_HOME", codexHome)
	writeTestAuth(t, codexHome, tokenSet{
		AccessToken:  testJWT(fixedNow.Add(-time.Minute), "account-1"),
		RefreshToken: "old-refresh",
		IDToken:      testJWT(fixedNow.Add(-time.Minute), "account-1"),
		AccountID:    "account-1",
	})

	maxTokens := 1024
	request := &schemas.BifrostRequest{
		RequestType: schemas.ResponsesStreamRequest,
		ResponsesRequest: &schemas.BifrostResponsesRequest{
			Provider: providerName,
			Model:    "gpt-5.4",
			Params:   &schemas.ResponsesParameters{MaxOutputTokens: &maxTokens},
		},
	}
	ctx := schemas.NewBifrostContext(context.Background(), schemas.NoDeadline)
	got, shortCircuit, err := PreLLMHook(ctx, request)
	if err != nil || shortCircuit != nil {
		t.Fatalf("PreLLMHook() error = %v, shortCircuit = %#v", err, shortCircuit)
	}
	if got.ResponsesRequest.Params.MaxOutputTokens != nil {
		t.Fatal("max_output_tokens was not removed")
	}
	headers := ctx.Value(schemas.BifrostContextKeyExtraHeaders).(map[string][]string)
	if headers["Authorization"][0] != "Bearer "+testJWT(fixedNow.Add(time.Hour), "account-1") {
		t.Fatal("authorization header did not use refreshed access token")
	}
	if headers["ChatGPT-Account-Id"][0] != "account-1" {
		t.Fatal("account header was not injected")
	}

	_, persisted, err := readAuth(filepath.Join(codexHome, "auth.json"))
	if err != nil {
		t.Fatal(err)
	}
	if persisted.RefreshToken != "new-refresh" {
		t.Fatalf("persisted refresh token = %q", persisted.RefreshToken)
	}
	info, err := os.Stat(filepath.Join(codexHome, "auth.json"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("auth file mode = %o", info.Mode().Perm())
	}
}

func TestCredentialsUsesConcurrentCodexRefresh(t *testing.T) {
	fixedNow := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	oldNow, oldURL, oldClient := now, oauthURL, httpClient
	now = func() time.Time { return fixedNow }
	t.Cleanup(func() { now, oauthURL, httpClient = oldNow, oldURL, oldClient })

	codexHome := t.TempDir()
	t.Setenv("CODEX_HOME", codexHome)
	writeTestAuth(t, codexHome, tokenSet{
		AccessToken:  testJWT(fixedNow.Add(-time.Minute), "account-1"),
		RefreshToken: "old-refresh",
		AccountID:    "account-1",
	})

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		writeTestAuth(t, codexHome, tokenSet{
			AccessToken:  testJWT(fixedNow.Add(time.Hour), "account-1"),
			RefreshToken: "codex-won-refresh",
			AccountID:    "account-1",
		})
		http.Error(w, "refresh token already used", http.StatusBadRequest)
	}))
	defer server.Close()
	oauthURL, httpClient = server.URL, server.Client()

	tokens, err := credentials(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if tokens.RefreshToken != "codex-won-refresh" {
		t.Fatalf("refresh token = %q", tokens.RefreshToken)
	}
}

func testJWT(expiry time.Time, accountID string) string {
	payload, _ := json.Marshal(map[string]any{
		"exp": expiry.Unix(),
		"https://api.openai.com/auth": map[string]string{
			"chatgpt_account_id": accountID,
		},
	})
	return "e30." + base64.RawURLEncoding.EncodeToString(payload) + ".signature"
}

func writeTestAuth(t *testing.T, dir string, tokens tokenSet) {
	t.Helper()
	data, err := json.Marshal(map[string]any{
		"auth_mode": "chatgpt",
		"tokens":    tokens,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "auth.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
}
