package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-lambda-go/events"
)

const issuer = "https://servicetrack.com.br/auth"

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func spkiPEM(t *testing.T, pub *rsa.PublicKey) string {
	t.Helper()
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		t.Fatalf("marshal SPKI: %v", err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
}

func pkcs1PEM(pub *rsa.PublicKey) string {
	der := x509.MarshalPKCS1PublicKey(pub)
	return string(pem.EncodeToMemory(&pem.Block{Type: "RSA PUBLIC KEY", Bytes: der}))
}

func makeToken(t *testing.T, key *rsa.PrivateKey, overrides map[string]interface{}, alg string, sign bool) string {
	t.Helper()

	header := map[string]string{"alg": alg, "typ": "JWT"}
	headerJSON, _ := json.Marshal(header)

	payload := map[string]interface{}{
		"sub":    "550e8400-e29b-41d4-a716-446655440000",
		"iss":    issuer,
		"exp":    time.Now().Add(time.Hour).Unix(),
		"email":  "claudio@email.com",
		"groups": []string{"CLIENTE"},
	}
	for k, v := range overrides {
		if v == nil {
			delete(payload, k)
		} else {
			payload[k] = v
		}
	}
	payloadJSON, _ := json.Marshal(payload)

	signingInput := b64url(headerJSON) + "." + b64url(payloadJSON)

	var sig []byte
	if sign {
		digest := sha256.Sum256([]byte(signingInput))
		var err error
		sig, err = rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
		if err != nil {
			t.Fatalf("assinar: %v", err)
		}
	} else {
		sig = make([]byte, 256)
	}
	return signingInput + "." + b64url(sig)
}

func cfgFor(t *testing.T, pemStr string) config {
	t.Helper()
	pub, err := parseRSAPublicKey(pemStr)
	if err != nil {
		t.Fatalf("parse chave: %v", err)
	}
	return config{publicKey: pub, issuer: issuer, leeway: 60 * time.Second}
}

func TestAuthorizer(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("gerar chave: %v", err)
	}
	other, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("gerar outra chave: %v", err)
	}

	spki := spkiPEM(t, &key.PublicKey)
	cfg := cfgFor(t, spki)
	now := time.Now()

	t.Run("token valido (SPKI)", func(t *testing.T) {
		c, err := decodeAndVerify(makeToken(t, key, nil, "RS256", true), cfg, now)
		if err != nil {
			t.Fatalf("esperava sucesso, veio %v", err)
		}
		if !strings.HasPrefix(c.Sub, "550e8400") {
			t.Fatalf("sub inesperado: %s", c.Sub)
		}
	})

	t.Run("token valido (PKCS#1)", func(t *testing.T) {
		if _, err := decodeAndVerify(makeToken(t, key, nil, "RS256", true), cfgFor(t, pkcs1PEM(&key.PublicKey)), now); err != nil {
			t.Fatalf("esperava sucesso, veio %v", err)
		}
	})

	cases := []struct {
		name   string
		token  func() string
		errSub string
	}{
		{"assinatura invalida", func() string { return makeToken(t, key, nil, "RS256", false) }, "assinatura invalida"},
		{"assinado por outra chave", func() string { return makeToken(t, other, nil, "RS256", true) }, "assinatura invalida"},
		{"payload adulterado", func() string { return tamper(t, makeToken(t, key, nil, "RS256", true)) }, "assinatura invalida"},
		{"alg none", func() string { return makeToken(t, key, nil, "none", true) }, "algoritmo nao suportado"},
		{"troca para HS256", func() string { return makeToken(t, key, nil, "HS256", true) }, "algoritmo nao suportado"},
		{"expirado", func() string {
			return makeToken(t, key, map[string]interface{}{"exp": time.Now().Add(-2 * time.Hour).Unix()}, "RS256", true)
		}, "token expirado"},
		{"sem exp", func() string { return makeToken(t, key, map[string]interface{}{"exp": nil}, "RS256", true) }, "token expirado"},
		{"emissor divergente", func() string {
			return makeToken(t, key, map[string]interface{}{"iss": "https://invasor.example"}, "RS256", true)
		}, "emissor invalido"},
		{"malformado", func() string { return "nao-e-jwt" }, "token malformado"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := decodeAndVerify(tc.token(), cfg, now)
			if err == nil {
				t.Fatal("esperava erro, veio nil")
			}
			if !strings.Contains(err.Error(), tc.errSub) {
				t.Fatalf("esperava %q, veio %q", tc.errSub, err.Error())
			}
		})
	}

	t.Run("recurso usa wildcard", func(t *testing.T) {
		got := wildcardResource("arn:aws:execute-api:us-east-1:123456789012:abc123/prd/GET/clientes/x")
		want := "arn:aws:execute-api:us-east-1:123456789012:abc123/prd/*/*"
		if got != want {
			t.Fatalf("veio %s", got)
		}
	})

	t.Run("handler devolve Allow e contexto", func(t *testing.T) {
		h := makeHandler(cfg)
		resp, err := h(nil, events.APIGatewayCustomAuthorizerRequest{
			Type:               "TOKEN",
			AuthorizationToken: "Bearer " + makeToken(t, key, nil, "RS256", true),
			MethodArn:          "arn:aws:execute-api:us-east-1:1:abc/prd/GET/clientes/x",
		})
		if err != nil {
			t.Fatalf("esperava sucesso, veio %v", err)
		}
		stmt := resp.PolicyDocument.Statement[0]
		if stmt.Effect != "Allow" {
			t.Fatalf("effect %s", stmt.Effect)
		}
		if !strings.HasSuffix(stmt.Resource[0], "/prd/*/*") {
			t.Fatalf("resource %s", stmt.Resource[0])
		}
		if resp.Context["roles"] != "CLIENTE" {
			t.Fatalf("roles %v", resp.Context["roles"])
		}
		if resp.Context["email"] != "claudio@email.com" {
			t.Fatalf("email %v", resp.Context["email"])
		}
	})

	t.Run("handler rejeita header sem token", func(t *testing.T) {
		h := makeHandler(cfg)
		_, err := h(nil, events.APIGatewayCustomAuthorizerRequest{AuthorizationToken: "Bearer ", MethodArn: "x"})
		if err != errUnauthorized {
			t.Fatalf("esperava Unauthorized, veio %v", err)
		}
	})
}

func tamper(t *testing.T, token string) string {
	t.Helper()
	parts := strings.Split(token, ".")
	payloadBytes, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var m map[string]interface{}
	json.Unmarshal(payloadBytes, &m)
	m["sub"] = "00000000-0000-0000-0000-000000000000"
	tampered, _ := json.Marshal(m)
	return parts[0] + "." + b64url(tampered) + "." + parts[2]
}
