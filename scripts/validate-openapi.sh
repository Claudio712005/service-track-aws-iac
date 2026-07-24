set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$REPO_ROOT/apis/service-track-api-ext/openApi.yaml"
CORS_CONFIG="$REPO_ROOT/apis/service-track-api-ext/api-configuration/cors/config-HML.yaml"
VENV="${TMPDIR:-/tmp}/service-track-openapi-venv"

[ -f "$SPEC" ] || { echo "spec nao encontrada: $SPEC" >&2; exit 1; }

if [ ! -x "$VENV/bin/python" ]; then
  echo "==> criando venv de validacao em $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install --upgrade pip
  "$VENV/bin/pip" -q install pyyaml openapi-spec-validator
fi

"$VENV/bin/python" - "$SPEC" "$CORS_CONFIG" <<'PY'
import json, re, sys
import yaml
from openapi_spec_validator import validate
from openapi_spec_validator.readers import read_from_filename  # noqa: F401

spec_path, cors_path = sys.argv[1], sys.argv[2]
raw = open(spec_path, encoding="utf-8").read()

cors = yaml.safe_load(open(cors_path, encoding="utf-8"))["cors"]

header = "method.response.header.Access-Control-Allow-"

cors_options = {
    "security": [],
    "responses": {
        "200": {
            "description": "CORS preflight",
            "headers": {
                "Access-Control-Allow-Origin": {"schema": {"type": "string"}},
                "Access-Control-Allow-Methods": {"schema": {"type": "string"}},
                "Access-Control-Allow-Headers": {"schema": {"type": "string"}},
                "Access-Control-Max-Age": {"schema": {"type": "string"}},
            },
        }
    },
    "x-amazon-apigateway-integration": {
        "type": "mock",
        "requestTemplates": {"application/json": '{"statusCode": 200}'},
        "passthroughBehavior": "when_no_match",
        "responses": {
            "default": {
                "statusCode": "200",
                "responseParameters": {
                    header + "Origin": "'%s'" % cors["allowOrigin"],
                    header + "Methods": "'%s'" % cors["allowMethods"],
                    header + "Headers": "'%s'" % cors["allowHeaders"],
                    "method.response.header.Access-Control-Max-Age": "'%s'" % cors["maxAge"],
                },
            }
        },
    },
}

bearer_auth_scheme = {
    "type": "apiKey",
    "name": "Authorization",
    "in": "header",
    "x-amazon-apigateway-authtype": "custom",
    "x-amazon-apigateway-authorizer": {
        "type": "token",
        "authorizerUri": "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:000000000000:function:fake-authorizer/invocations",
        "authorizerResultTtlInSeconds": 300,
        "identityValidationExpression": "^[Bb]earer [-_.A-Za-z0-9]+$",
    },
}

fake = {
    "auth_lambda_uri": "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:000000000000:function:fake/invocations",
    "app_backend_host": "fake-nlb.elb.us-east-1.amazonaws.com",
    "vpc_link_id": "abc123",
    "cors_options": json.dumps(cors_options),
    "bearer_auth_scheme": json.dumps(bearer_auth_scheme),
}

missing = set(re.findall(r"\$\{(\w+)\}", raw)) - set(fake)
if missing:
    sys.exit("placeholders sem valor de teste: %s" % ", ".join(sorted(missing)))

for key, value in fake.items():
    raw = raw.replace("${%s}" % key, value)

spec = yaml.safe_load(raw)
validate(spec)

ops = sum(
    1
    for item in spec["paths"].values()
    for method, op in item.items()
    if method in ("get", "post", "put", "patch", "delete") and isinstance(op, dict)
)
preflights = sum(1 for item in spec["paths"].values() if "options" in item)

print("OpenAPI valido")
print("  paths      : %d" % len(spec["paths"]))
print("  operacoes  : %d (+%d OPTIONS de preflight)" % (ops, preflights))
print("  schemas    : %d" % len(spec["components"]["schemas"]))

for path, item in spec["paths"].items():
    for method, op in item.items():
        if method in ("get", "post", "put", "patch", "delete", "options"):
            if "x-amazon-apigateway-integration" not in op:
                sys.exit("sem integracao: %s %s" % (method.upper(), path))
print("  integracoes: todas as operacoes possuem x-amazon-apigateway-integration")

for path, item in spec["paths"].items():
    params = set(re.findall(r"\{(\w+)\}", path))
    for method, op in item.items():
        if method not in ("get", "post", "put", "patch", "delete"):
            continue
        mapped = set()
        for k in op["x-amazon-apigateway-integration"].get("requestParameters", {}):
            mapped.add(k.rsplit(".", 1)[-1])
        if params - mapped:
            sys.exit(
                "path param sem requestParameters: %s %s -> %s"
                % (method.upper(), path, ", ".join(sorted(params - mapped)))
            )
print("  path params: todos mapeados em requestParameters")
PY
