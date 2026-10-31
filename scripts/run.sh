#!/usr/bin/env bash
# Spustí Automatka s klíči z .env.
# Použití:  ./scripts/run.sh [další argumenty pro flutter run]
#   ./scripts/run.sh                  # vybere zařízení interaktivně
#   ./scripts/run.sh -d <device-id>   # konkrétní zařízení
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$root/.env" ]]; then
  echo "Chybí .env — zkopíruj .env.example na .env a doplň klíče ze Supabase dashboardu." >&2
  exit 1
fi

set -a; source "$root/.env"; set +a

: "${SUPABASE_URL:?Chybí SUPABASE_URL v .env}"
: "${SUPABASE_PUBLISHABLE_KEY:?Chybí SUPABASE_PUBLISHABLE_KEY v .env}"

if [[ "$SUPABASE_URL" == *xxxxxxxxxxxx* || "$SUPABASE_PUBLISHABLE_KEY" == *... ]]; then
  echo "SUPABASE_URL nebo SUPABASE_PUBLISHABLE_KEY je pořád placeholder z .env.example — doplň skutečnou hodnotu." >&2
  exit 1
fi

cd "$root/app"
exec flutter run \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_PUBLISHABLE_KEY="$SUPABASE_PUBLISHABLE_KEY" \
  "$@"
