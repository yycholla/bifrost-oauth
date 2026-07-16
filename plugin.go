package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/maximhq/bifrost/core/schemas"
)

const (
	providerName = schemas.ModelProvider("codex-subscription")
	tokenURL     = "https://auth.openai.com/oauth/token"
	clientID     = "app_EMoamEEZ73f0CkXaXp7hrann"
)

var (
	authMu     sync.Mutex
	httpClient = &http.Client{Timeout: 15 * time.Second}
	now        = time.Now
	oauthURL   = tokenURL
)

type tokenSet struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	IDToken      string `json:"id_token"`
	AccountID    string `json:"account_id"`
}

type jwtClaims struct {
	ExpiresAt int64 `json:"exp"`
	Auth      struct {
		AccountID string `json:"chatgpt_account_id"`
	} `json:"https://api.openai.com/auth"`
}

type refreshResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	IDToken      string `json:"id_token"`
}

func GetName() string { return "Codex subscription OAuth" }

func Cleanup() error { return nil }

func PreLLMHook(ctx *schemas.BifrostContext, req *schemas.BifrostRequest) (*schemas.BifrostRequest, *schemas.LLMPluginShortCircuit, error) {
	provider, _, _ := req.GetRequestFields()
	if provider != providerName {
		return req, nil, nil
	}
	if req.ResponsesRequest == nil {
		return req, authFailure(errors.New("codex-subscription only supports Responses requests")), nil
	}

	tokens, err := credentials(ctx)
	if err != nil {
		return req, authFailure(err), nil
	}

	headers := map[string][]string{}
	if current, ok := ctx.Value(schemas.BifrostContextKeyExtraHeaders).(map[string][]string); ok {
		for key, values := range current {
			if isCodexHeader(key) {
				continue
			}
			headers[key] = append([]string(nil), values...)
		}
	}
	headers["Authorization"] = []string{"Bearer " + tokens.AccessToken}
	headers["ChatGPT-Account-Id"] = []string{tokens.AccountID}
	headers["Originator"] = []string{"codex_cli_rs"}
	headers["User-Agent"] = []string{"codex-cli"}
	ctx.SetValue(schemas.BifrostContextKeyExtraHeaders, headers)

	if req.ResponsesRequest.Params != nil {
		req.ResponsesRequest.Params.MaxOutputTokens = nil
	}
	for i := range req.ResponsesRequest.Input {
		if role := req.ResponsesRequest.Input[i].Role; role != nil && *role == schemas.ResponsesInputMessageRoleSystem {
			req.ResponsesRequest.Input[i].Role = schemas.Ptr(schemas.ResponsesInputMessageRoleDeveloper)
		}
	}
	return req, nil, nil
}

func isCodexHeader(key string) bool {
	for _, owned := range []string{"Authorization", "ChatGPT-Account-Id", "Originator", "User-Agent"} {
		if strings.EqualFold(key, owned) {
			return true
		}
	}
	return false
}

func credentials(ctx context.Context) (tokenSet, error) {
	authMu.Lock()
	defer authMu.Unlock()

	path, err := codexAuthPath()
	if err != nil {
		return tokenSet{}, err
	}
	document, tokens, err := readAuth(path)
	if err != nil {
		return tokenSet{}, err
	}
	if !expiresSoon(tokens.AccessToken) {
		return withAccountID(tokens)
	}
	if tokens.RefreshToken == "" {
		return tokenSet{}, errors.New("Codex login has no refresh token; run `codex login`")
	}

	refreshed, err := refresh(ctx, tokens.RefreshToken)
	if err != nil {
		// Another Codex process may have won the single-use refresh-token race.
		time.Sleep(100 * time.Millisecond)
		_, latest, readErr := readAuth(path)
		if readErr == nil && latest.AccessToken != tokens.AccessToken && !expiresSoon(latest.AccessToken) {
			return withAccountID(latest)
		}
		return tokenSet{}, err
	}
	tokens.AccessToken = refreshed.AccessToken
	if refreshed.RefreshToken != "" {
		tokens.RefreshToken = refreshed.RefreshToken
	}
	if refreshed.IDToken != "" {
		tokens.IDToken = refreshed.IDToken
	}
	if tokens.AccountID == "" {
		tokens.AccountID = accountID(tokens)
	}
	if err := writeAuth(path, document, tokens); err != nil {
		return tokenSet{}, fmt.Errorf("persist refreshed Codex login: %w", err)
	}
	return withAccountID(tokens)
}

func codexAuthPath() (string, error) {
	if home := os.Getenv("CODEX_HOME"); home != "" {
		return filepath.Join(home, "auth.json"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find home directory: %w", err)
	}
	return filepath.Join(home, ".codex", "auth.json"), nil
}

func readAuth(path string) (map[string]json.RawMessage, tokenSet, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, tokenSet{}, fmt.Errorf("read Codex login %s: %w", path, err)
	}
	var document map[string]json.RawMessage
	if err := json.Unmarshal(data, &document); err != nil {
		return nil, tokenSet{}, fmt.Errorf("parse Codex login: %w", err)
	}
	var tokens tokenSet
	if err := json.Unmarshal(document["tokens"], &tokens); err != nil {
		return nil, tokenSet{}, fmt.Errorf("parse Codex tokens: %w", err)
	}
	if tokens.AccessToken == "" {
		return nil, tokenSet{}, errors.New("Codex login has no access token; run `codex login`")
	}
	return document, tokens, nil
}

func expiresSoon(token string) bool {
	claims, err := decodeClaims(token)
	return err != nil || now().Add(5*time.Minute).Unix() >= claims.ExpiresAt
}

func decodeClaims(token string) (jwtClaims, error) {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return jwtClaims{}, errors.New("invalid JWT")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return jwtClaims{}, err
	}
	var claims jwtClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return jwtClaims{}, err
	}
	if claims.ExpiresAt == 0 {
		return jwtClaims{}, errors.New("JWT has no expiry")
	}
	return claims, nil
}

func withAccountID(tokens tokenSet) (tokenSet, error) {
	if tokens.AccountID == "" {
		tokens.AccountID = accountID(tokens)
	}
	if tokens.AccountID == "" {
		return tokenSet{}, errors.New("Codex login has no ChatGPT account ID; run `codex login`")
	}
	return tokens, nil
}

func accountID(tokens tokenSet) string {
	for _, token := range []string{tokens.IDToken, tokens.AccessToken} {
		if claims, err := decodeClaims(token); err == nil && claims.Auth.AccountID != "" {
			return claims.Auth.AccountID
		}
	}
	return ""
}

func refresh(ctx context.Context, refreshToken string) (refreshResponse, error) {
	body, err := json.Marshal(map[string]string{
		"client_id":     clientID,
		"grant_type":    "refresh_token",
		"refresh_token": refreshToken,
	})
	if err != nil {
		return refreshResponse{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, oauthURL, strings.NewReader(string(body)))
	if err != nil {
		return refreshResponse{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return refreshResponse{}, fmt.Errorf("refresh Codex login: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return refreshResponse{}, fmt.Errorf("refresh Codex login: OAuth server returned %s", resp.Status)
	}
	var result refreshResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&result); err != nil {
		return refreshResponse{}, fmt.Errorf("parse refreshed Codex login: %w", err)
	}
	if result.AccessToken == "" {
		return refreshResponse{}, errors.New("refresh Codex login: OAuth response has no access token")
	}
	return result, nil
}

func writeAuth(path string, document map[string]json.RawMessage, tokens tokenSet) error {
	encodedTokens, err := json.Marshal(tokens)
	if err != nil {
		return err
	}
	refreshedAt, err := json.Marshal(now().UTC().Format(time.RFC3339Nano))
	if err != nil {
		return err
	}
	document["tokens"] = encodedTokens
	document["last_refresh"] = refreshedAt
	data, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return err
	}

	tmp, err := os.CreateTemp(filepath.Dir(path), ".auth.json-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func authFailure(err error) *schemas.LLMPluginShortCircuit {
	status := http.StatusUnauthorized
	allowFallbacks := false
	return &schemas.LLMPluginShortCircuit{Error: &schemas.BifrostError{
		StatusCode:     &status,
		AllowFallbacks: &allowFallbacks,
		Error: &schemas.ErrorField{
			Message: "Codex subscription authentication failed: " + err.Error(),
			Error:   err,
		},
	}}
}
