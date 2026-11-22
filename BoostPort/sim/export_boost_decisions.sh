#!/usr/bin/env bash
#
# export_boost_decisions.sh — export the Boost golden-master replay fixture.
#
# Pulls real AndroidAPS Boost cycles (user `tim`) from the local TimescaleDB into an
# NDJSON fixture consumed by the BoostV5Core replay suite (DynIsfReplayTests etc.).
# Each line is one cycle as a JSON object (row_to_json), so console_error newlines are
# JSON-escaped (\n) and every record stays on a single line.
#
# Only rows carrying the DynISF console line are exported — those are the ones whose
# inputs/outputs are fully recoverable. v1-silent (shadow) rows are excluded.
#
# The fixture is real glucose/insulin data and is gitignored. Re-run this whenever you
# want to refresh it. The replay tests XCTSkip cleanly if the fixture is absent.
#
# Exports ALL boost users by default. Set REPLAY_USER to restrict to one user.
#
# Usage:  bash BoostPort/sim/export_boost_decisions.sh
#         REPLAY_USER=tim bash BoostPort/sim/export_boost_decisions.sh   # single user
# Env:    PGHOST (default 127.0.0.1) PGPORT (5432) PGDATABASE (oref) REPLAY_USER (unset = all)

set -euo pipefail

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-oref}"
REPLAY_USER="${REPLAY_USER:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../BoostV5Core/Tests/BoostV5CoreTests/Fixtures"
OUT_FILE="$OUT_DIR/boost_decisions.ndjson"

mkdir -p "$OUT_DIR"

if [ -n "$REPLAY_USER" ]; then
  USER_FILTER="user_id = '$REPLAY_USER' AND"
  echo "Exporting boost_decisions for user '$REPLAY_USER' from $PGDATABASE@$PGHOST:$PGPORT …"
else
  USER_FILTER=""
  echo "Exporting boost_decisions for ALL users from $PGDATABASE@$PGHOST:$PGPORT …"
fi

# COPY ... TO STDOUT streams one JSON object per row. We select the whole row (*) so the
# fixture stays robust to column additions; the Swift model decodes only what it needs.
psql -h "$PGHOST" -p "$PGPORT" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -tAc "
COPY (
  SELECT row_to_json(t)
  FROM (
    SELECT *
    FROM public.boost_decisions
    WHERE $USER_FILTER console_error LIKE '%normalTarget=%'
    ORDER BY user_id, ts_utc
  ) t
) TO STDOUT
" > "$OUT_FILE"

ROWS=$(wc -l < "$OUT_FILE" | tr -d ' ')
BYTES=$(wc -c < "$OUT_FILE" | tr -d ' ')
echo "Wrote $ROWS rows ($BYTES bytes) -> $OUT_FILE"
echo "Run the replay with:  cd BoostPort/BoostV5Core && swift test --filter Replay"
