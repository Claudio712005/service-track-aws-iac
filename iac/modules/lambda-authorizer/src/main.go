package main

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
)

var errUnauthorized = errors.New("Unauthorized")

type config struct {
	publicKey *rsa.PublicKey
	issuer    string
	leeway    time.Duration
}

type rawRoles []string

func (r *rawRoles) UnmarshalJSON(data []byte) error {
	var one string
	if err := json.Unmarshal(data, &one); err == nil {
		*r = []string{one}
		return nil
	}
	var many []string
	if err := json.Unmarshal(data, &many); err == nil {
		*r = many
		return nil
	}
	return nil
}

type claims struct {
	Sub    string   `json:"sub"`
	Iss    string   `json:"iss"`
	Email  string   `json:"email"`
	Upn    string   `json:"upn"`
	Exp    *float64 `json:"exp"`
	Nbf    *float64 `json:"nbf"`
	Groups rawRoles `json:"groups"`
	Roles  rawRoles `json:"roles"`
}

type jwtHeader struct {
	Alg string `json:"alg"`
}

func loadConfig() (config, error) {
	pemStr := os.Getenv("JWT_PUBLIC_KEY")
	pub, err := parseRSAPublicKey(pemStr)
	if err != nil {
		return config{}, err
	}

	leeway := 60
	if v := os.Getenv("JWT_LEEWAY_SECONDS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			leeway = n
		}
	}

	return config{
		publicKey: pub,
		issuer:    os.Getenv("JWT_ISSUER"),
		leeway:    time.Duration(leeway) * time.Second,
	}, nil
}

func parseRSAPublicKey(pemStr string) (*rsa.PublicKey, error) {
	block, _ := pem.Decode([]byte(strings.TrimSpace(pemStr)))
	if block == nil {
		return nil, errors.New("chave publica JWT ausente ou nao e PEM valido")
	}

	// SPKI (BEGIN PUBLIC KEY) e o formato usual; PKCS#1 (BEGIN RSA PUBLIC KEY)
	// e o fallback.
	if key, err := x509.ParsePKIXPublicKey(block.Bytes); err == nil {
		if rsaKey, ok := key.(*rsa.PublicKey); ok {
			return rsaKey, nil
		}
		return nil, errors.New("chave publica JWT nao e RSA")
	}
	if rsaKey, err := x509.ParsePKCS1PublicKey(block.Bytes); err == nil {
		return rsaKey, nil
	}
	return nil, errors.New("formato de chave publica JWT nao suportado")
}

func b64urlDecode(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(s)
}

// decodeAndVerify valida assinatura, algoritmo, exp/nbf e emissor.
func decodeAndVerify(token string, cfg config, now time.Time) (claims, error) {
	var c claims

	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return c, fmt.Errorf("token malformado")
	}

	headerBytes, err := b64urlDecode(parts[0])
	if err != nil {
		return c, fmt.Errorf("token malformado: header")
	}
	var h jwtHeader
	if err := json.Unmarshal(headerBytes, &h); err != nil {
		return c, fmt.Errorf("token malformado: header")
	}

	// Trava o algoritmo antes de qualquer verificacao. Aceitar o alg do proprio
	// token permitiria "none" ou troca para HS256 usando a chave publica como
	// segredo HMAC.
	if h.Alg != "RS256" {
		return c, fmt.Errorf("algoritmo nao suportado: %s", h.Alg)
	}

	payloadBytes, err := b64urlDecode(parts[1])
	if err != nil {
		return c, fmt.Errorf("token malformado: payload")
	}
	if err := json.Unmarshal(payloadBytes, &c); err != nil {
		return c, fmt.Errorf("token malformado: payload")
	}

	signature, err := b64urlDecode(parts[2])
	if err != nil {
		return c, fmt.Errorf("token malformado: assinatura")
	}

	signingInput := parts[0] + "." + parts[1]
	digest := sha256.Sum256([]byte(signingInput))
	if err := rsa.VerifyPKCS1v15(cfg.publicKey, crypto.SHA256, digest[:], signature); err != nil {
		return c, fmt.Errorf("assinatura invalida")
	}

	leeway := cfg.leeway
	if c.Exp == nil || now.After(time.Unix(int64(*c.Exp), 0).Add(leeway)) {
		return c, fmt.Errorf("token expirado")
	}
	if c.Nbf != nil && now.Before(time.Unix(int64(*c.Nbf), 0).Add(-leeway)) {
		return c, fmt.Errorf("token ainda nao valido")
	}
	if cfg.issuer != "" && c.Iss != cfg.issuer {
		return c, fmt.Errorf("emissor invalido")
	}

	return c, nil
}

// wildcardResource: arn:...:apiId/stage/GET/clientes/x -> arn:...:apiId/stage/*/*
//
// O resultado do authorizer e cacheado por token; restringir ao metodo exato
// faria o cache errar em toda chamada a outra rota.
func wildcardResource(methodArn string) string {
	parts := strings.SplitN(methodArn, ":", 6)
	if len(parts) < 6 {
		return methodArn
	}
	segments := strings.Split(parts[5], "/")
	if len(segments) < 2 {
		return methodArn
	}
	parts[5] = strings.Join([]string{segments[0], segments[1], "*", "*"}, "/")
	return strings.Join(parts, ":")
}

func extractToken(raw string) string {
	raw = strings.TrimSpace(raw)
	fields := strings.Fields(raw)
	if len(fields) >= 2 && strings.EqualFold(fields[0], "bearer") {
		return strings.TrimSpace(strings.TrimSpace(raw)[len(fields[0]):])
	}
	if len(fields) == 1 && strings.EqualFold(fields[0], "bearer") {
		return ""
	}
	return raw
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func buildResponse(c claims, methodArn string) events.APIGatewayCustomAuthorizerResponse {
	roles := c.Groups
	if len(roles) == 0 {
		roles = c.Roles
	}

	return events.APIGatewayCustomAuthorizerResponse{
		PrincipalID: firstNonEmpty(c.Sub, c.Upn, "desconhecido"),
		PolicyDocument: events.APIGatewayCustomAuthorizerPolicy{
			Version: "2012-10-17",
			Statement: []events.IAMPolicyStatement{
				{
					Action:   []string{"execute-api:Invoke"},
					Effect:   "Allow",
					Resource: []string{wildcardResource(methodArn)},
				},
			},
		},
		Context: map[string]interface{}{
			"sub":   c.Sub,
			"email": firstNonEmpty(c.Email, c.Upn),
			"roles": strings.Join(roles, ","),
		},
	}
}

func makeHandler(cfg config) func(context.Context, events.APIGatewayCustomAuthorizerRequest) (events.APIGatewayCustomAuthorizerResponse, error) {
	return func(_ context.Context, event events.APIGatewayCustomAuthorizerRequest) (events.APIGatewayCustomAuthorizerResponse, error) {
		token := extractToken(event.AuthorizationToken)
		if token == "" {
			log.Print("token ausente")
			return events.APIGatewayCustomAuthorizerResponse{}, errUnauthorized
		}

		c, err := decodeAndVerify(token, cfg, time.Now())
		if err != nil {
			// Motivo detalhado so no log; o cliente recebe 401 generico.
			log.Printf("token rejeitado: %v", err)
			return events.APIGatewayCustomAuthorizerResponse{}, errUnauthorized
		}

		return buildResponse(c, event.MethodArn), nil
	}
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		// Falha de configuracao (chave ausente/invalida) derruba a funcao no
		// cold start, em vez de rejeitar silenciosamente todo request.
		log.Fatalf("configuracao invalida: %v", err)
	}
	lambda.Start(makeHandler(cfg))
}
