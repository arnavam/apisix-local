# Source this file before running ADC or the gateway-config generators:
#
#   source /Users/arnav/Code/apisix-local/adc-env.sh
#
# It sets (1) how ADC reaches this local APISIX and (2) the local values the generators
# (oan_*/apisix/generate_apisix_config_from_spec.py) write into adc.yaml. Unset or change
# them for another environment; the generators fall back to development defaults.

# --- ADC connection -------------------------------------------------------------------
export ADC_BACKEND=apisix
export ADC_SERVER=http://localhost:9180
# The admin key is not stored here. Read it from the running container, else from .env.
if [ -z "${ADC_TOKEN:-}" ]; then
  ADC_TOKEN="$(docker exec apisix printenv APISIX_ADMIN_KEY 2>/dev/null)"
  if [ -z "$ADC_TOKEN" ] && [ -f "$(dirname "${BASH_SOURCE[0]:-$0}")/.env" ]; then
    ADC_TOKEN="$(sed -n 's/^APISIX_ADMIN_KEY=//p' "$(dirname "${BASH_SOURCE[0]:-$0}")/.env" | head -1 | tr -d "\"'")"
  fi
  export ADC_TOKEN
fi

# --- Values written into adc.yaml by the generators ------------------------------------
# Frappe bench on the host; APISIX runs in Docker, so it reaches the host by this name.
export OAN_GRIEVANCE_UPSTREAM_HOST=host.docker.internal
export OAN_GRIEVANCE_UPSTREAM_PORT=8000
# `bench socketio` (realtime for the grievance app).
export OAN_GRIEVANCE_SOCKET_UPSTREAM_HOST=host.docker.internal
export OAN_GRIEVANCE_SOCKET_UPSTREAM_PORT=9000
# oan_a2c on the same bench.
export OAN_A2C_UPSTREAM_HOST=host.docker.internal
export OAN_A2C_UPSTREAM_PORT=8000
# Frappe selects the site from the Host header, so the gateway sends this site name.
export FRAPPE_SITE_NAME=mysite.localhost
# limit-count counters: the `redis` service in docker-compose.yml.
export APISIX_REDIS_HOST=redis
export APISIX_REDIS_PORT=6379
# Browser origins allowed by CORS (regex). Local frontends on any port:
export CORS_ORIGINS_REGEX='https?://localhost(:[0-9]+)?'
