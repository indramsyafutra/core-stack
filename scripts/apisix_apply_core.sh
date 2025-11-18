#!/usr/bin/env bash
set -Eeuo pipefail

# init-apisix.sh
# Usage:
#   cd /path/to/core-stack
#   set -a; source .env; set +a
#   export AK="$APISIX_ADMIN_API_KEY"
#   ./apisix/init-apisix.sh

APISIX_ADMIN_URL="${APISIX_ADMIN_URL:-http://127.0.0.1:9180}"
AK="${AK:-${APISIX_ADMIN_API_KEY:-}}"
SSO_HOST="${SSO_HOST:-sso.uin-suska.com}"
OPS_HOST="${OPS_HOST:-ops.uin-suska.com}"
SSL_CERT_PATH="${SSL_CERT_PATH:-/etc/ssl/uinsuska/fullchain.crt}"
SSL_CERT_KEY="${SSL_CERT_KEY:-/etc/ssl/uinsuska/private.key}"
DASH_HOST="${DASH_HOST:-dash.uin-suska.ac.id}"
DASH_UPSTREAM_NODE="${DASH_UPSTREAM_NODE:-apisix-dashboard:9000}"

# colors
C_RST="\033[0m"
C_INF="\033[1;34m"
C_OK="\033[1;32m"
C_ERR="\033[1;31m"
C_WRN="\033[1;33m"

info(){ printf "${C_INF}[INFO]${C_RST} %s\n" "$*"; }
ok(){ printf "${C_OK}[OK]${C_RST} %s\n" "$*"; }
err(){ printf "${C_ERR}[ERROR]${C_RST} %s\n" "$*" >&2; }
warn(){ printf "${C_WRN}[WARN]${C_RST} %s\n" "$*"; }

require_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "need '$1' (install it)"; exit 1; } }

# checks
require_cmd curl
require_cmd jq

if [ -z "$AK" ]; then
  err "APISIX admin API key not set. Export AK or set APISIX_ADMIN_API_KEY in .env"
  exit 1
fi

info "APISIX_ADMIN_URL=$APISIX_ADMIN_URL"
info "Using AK=${AK:0:6}...[hidden]"
info "SSO_HOST=$SSO_HOST OPS_HOST=$OPS_HOST"
info "SSL_CERT_PATH=$SSL_CERT_PATH"
info "SSL_CERT_KEY=$SSL_CERT_KEY"

# basic APISIX admin API check
info "Checking APISIX Admin API..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "X-API-KEY: $AK" "$APISIX_ADMIN_URL/apisix/admin/routes")
if [ "$HTTP_CODE" -ne 200 ]; then
  err "APISIX admin API unreachable or unauthorized (HTTP $HTTP_CODE). Check AK and APISIX admin bind/ACL."
  curl -s -D - -H "X-API-KEY: $AK" "$APISIX_ADMIN_URL/apisix/admin/routes" || true
  exit 1
fi
ok "APISIX Admin API reachable."

# helper to apply json via PUT and check response
apply_put(){
  local url="$1" ; shift
  local datafile="$1" ; shift
  info "PUT $url (from $datafile)..."
  resp=$(curl -sS -w "\n__HTTP_CODE__:%{http_code}" -X PUT "$url" -H "X-API-KEY: $AK" -H "Content-Type: application/json" --data-binary @"$datafile")
  code=$(printf "%s" "$resp" | awk -F'__HTTP_CODE__:' 'END{print $2}')
  body=$(printf "%s" "$resp" | sed -E 's/__HTTP_CODE__:[0-9]{3}$//')
  if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
    ok "Applied OK ($code) -> $url"
    printf "%s\n" "$body" | jq -C . || true
    return 0
  else
    err "Failed apply ($code) -> $url"
    printf "%s\n" "$body" || true
    return 1
  fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# 1) Upstream - keycloak
cat > "$TMPDIR/upstream_keycloak.json" <<EOF
{
  "id": "up_sso",
  "type": "roundrobin",
  "scheme": "http",
  "nodes": {
    "keycloak:8080": 1
  },
  "pass_host": "pass"
}
EOF
apply_put "$APISIX_ADMIN_URL/apisix/admin/upstreams/up_sso" "$TMPDIR/upstream_keycloak.json" || { err "upstream up_sso failed"; exit 1; }

# 2) Upstream - portainer (optional)
cat > "$TMPDIR/upstream_portainer.json" <<EOF
{
  "id": "up_portainer",
  "type": "roundrobin",
  "scheme": "http",
  "nodes": {
    "portainer:9000": 1
  }
}
EOF
apply_put "$APISIX_ADMIN_URL/apisix/admin/upstreams/up_portainer" "$TMPDIR/upstream_portainer.json" || warn "upstream up_portainer may have failed"

cat > "$TMPDIR/upstream_dashboard.json" <<EOF
# upstream up_dashboard
{
  "id": "up_dashboard",
  "type": "roundrobin",
  "scheme": "http",
  "nodes": {
    "apisix-dashboard:9000": 1
  },
  "pass_host": "pass"
}
EOF
apply_put "$APISIX_ADMIN_URL/apisix/admin/upstreams/up_dashboard" "$TMPDIR/upstream_dashboard.json" || warn "upstream up_dashboard may have failed"


# 3) Route SSO -> up_sso
cat > "$TMPDIR/route_sso.json" <<EOF
{
  "id": "route_sso",
  "uri": "/*",
  "hosts": ["$SSO_HOST"],
  "priority": 10,
  "upstream_id": "up_sso",
  "plugins": {
    "proxy-rewrite": {
      "headers": {
        "X-Forwarded-Proto": "https",
        "X-Forwarded-Host": "$SSO_HOST",
        "X-Forwarded-Port": "443"
      }
    },
    "response-rewrite": {
      "headers": {
        "Strict-Transport-Security": "max-age=31536000; includeSubDomains; preload",
        "X-Frame-Options": "SAMEORIGIN",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer-when-downgrade"
      }
    }
  }
}
EOF
apply_put "$APISIX_ADMIN_URL/apisix/admin/routes/route_sso" "$TMPDIR/route_sso.json" || { err "route_sso failed"; exit 1; }

# 4) Route OPS -> up_portainer
cat > "$TMPDIR/route_ops.json" <<EOF
{
  "id": "route_ops",
  "uri": "/*",
  "hosts": ["$OPS_HOST"],
  "priority": 10,
  "upstream_id": "up_portainer",
  "plugins": {
    "proxy-rewrite": {
      "headers": {
        "X-Forwarded-Proto": "https",
        "X-Forwarded-Host": "$OPS_HOST",
        "X-Forwarded-Port": "443"
      }
    },
    "response-rewrite": {
      "headers": {
        "Strict-Transport-Security": "max-age=31536000; includeSubDomains; preload",
        "X-Frame-Options": "SAMEORIGIN",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer-when-downgrade"
      }
    }
  }
}
EOF
apply_put "$APISIX_ADMIN_URL/apisix/admin/routes/route_ops" "$TMPDIR/route_ops.json" || warn "route_ops may have failed"

cat > "$TMPDIR/route_dashboard.json" <<EOF
{
  "id": "route_dashboard",
  "uri": "/*",
  "hosts": ["dash.uin-suska.ac.id"],
  "priority": 10,
  "upstream_id": "up_dashboard",
  "plugins": {
    "ip-restriction": {
      "whitelist": [
        "10.0.0.0/16",
        "192.168.0.0/16"
      ]
    },
    "proxy-rewrite": {
      "headers": {
        "X-Forwarded-Proto": "https",
        "X-Forwarded-Host": "dash.uin-suska.ac.id",
        "X-Forwarded-Port": "443"
      }
    },
    "response-rewrite": {
      "headers": {
        "Strict-Transport-Security": "max-age=31536000; includeSubDomains; preload",
        "X-Frame-Options": "SAMEORIGIN",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer-when-downgrade"
      }
    }
  }
}
EOF
apply_put "$APISIX_ADMIN_URL/apisix/admin/routes/route_dashboard" "$TMPDIR/route_dashboard.json" || warn "route_dashboard may have failed"

# 5) SSL object
if [ ! -f "$SSL_CERT_PATH" ] || [ ! -f "$SSL_CERT_KEY" ]; then
  warn "SSL cert or key not found at $SSL_CERT_PATH / $SSL_CERT_KEY. Skipping SSL create."
else
  jq -n \
    --rawfile crt "$SSL_CERT_PATH" \
    --rawfile key "$SSL_CERT_KEY" \
    --arg sso "$SSO_HOST" \
    --arg ops "$OPS_HOST" \
    '{
      id: "ssl_injected",
      cert: $crt,
      key: $key,
      snis: [$sso, $ops]
    }' > "$TMPDIR/ssl_injected.json"

  apply_put "$APISIX_ADMIN_URL/apisix/admin/ssls/ssl_injected" "$TMPDIR/ssl_injected.json" || { err "ssl injection failed"; exit 1; }
fi

# 6) quick verify: list routes and upstreams
info "Verifying objects..."
curl -sS -H "X-API-KEY: $AK" "$APISIX_ADMIN_URL/apisix/admin/routes" | jq '.list[] | {id:.value.id, hosts:.value.hosts, upstream_id:.value.upstream_id}' || true
curl -sS -H "X-API-KEY: $AK" "$APISIX_ADMIN_URL/apisix/admin/upstreams" | jq '.list[] | {id:.value.id, nodes:.value.nodes}' || true
if [ -f "$TMPDIR/ssl_injected.json" ]; then
  curl -sS -H "X-API-KEY: $AK" "$APISIX_ADMIN_URL/apisix/admin/ssls/ssl_injected" | jq '.value | {id: .id, snis: .snis}' || true
fi

ok "init-apisix done."
