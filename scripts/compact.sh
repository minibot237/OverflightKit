#!/bin/sh
# Nightly compaction: move observation rows older than the hot window out of
# the SQLite ingest tier into zstd Parquet under the archive dir, partitioned
# by Pacific date and 2-char geohash bucket. DuckDB queries the files in
# place; nothing is deleted from SQLite until the Parquet row count for that
# day has been verified.
#
#   DB_PATH      default ~/.overflight/unified.db
#   ARCHIVE_DIR  default ~/.overflight/archive   (move to spinning disk later)
#   HOT_DAYS     default 30 — complete Pacific days younger than this stay hot
set -eu

DB_PATH="${DB_PATH:-$HOME/.overflight/unified.db}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$HOME/.overflight/archive}"
HOT_DAYS="${HOT_DAYS:-30}"
TZ_NAME="America/Los_Angeles"

command -v duckdb >/dev/null || { echo "duckdb CLI not found (brew install duckdb)" >&2; exit 1; }
[ -f "$DB_PATH" ] || { echo "no database at $DB_PATH" >&2; exit 1; }
mkdir -p "$ARCHIVE_DIR"

log() { echo "$(TZ=$TZ_NAME date '+%Y-%m-%d %H:%M:%S %Z') $*"; }

# Every complete Pacific day in the DB older than the hot window.
CUTOFF_DAY="$(TZ=$TZ_NAME date -v-"${HOT_DAYS}"d '+%Y-%m-%d')"
DAYS="$(sqlite3 "$DB_PATH" "
	SELECT DISTINCT date(ts, 'unixepoch', 'localtime') FROM observation
	WHERE date(ts, 'unixepoch', 'localtime') < '$CUTOFF_DAY'
	ORDER BY 1;" 2>/dev/null || true)"

[ -n "$DAYS" ] || { log "nothing older than $CUTOFF_DAY to compact"; exit 0; }

for DAY in $DAYS; do
	# Pacific-midnight epoch bounds for the day.
	T0="$(TZ=$TZ_NAME date -j -f '%Y-%m-%d %H:%M:%S' "$DAY 00:00:00" '+%s')"
	T1=$((T0 + 86400))
	OUT="$ARCHIVE_DIR/date=$DAY"
	SRC_COUNT="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM observation WHERE ts >= $T0 AND ts < $T1;")"
	[ "$SRC_COUNT" -gt 0 ] || continue

	log "compacting $DAY: $SRC_COUNT rows -> $OUT"
	rm -rf "$OUT"
	duckdb -c "
		INSTALL sqlite; LOAD sqlite;
		ATTACH '$DB_PATH' AS ingest (TYPE sqlite, READ_ONLY);
		COPY (
			SELECT kind, vid, ts, lat, lon, alt_ft, alt_src, speed_kt, heading,
				callsign, source, geohash, substr(geohash, 1, 2) AS geo
			FROM ingest.observation
			WHERE ts >= $T0 AND ts < $T1
		) TO '$OUT' (FORMAT PARQUET, COMPRESSION ZSTD, PARTITION_BY (geo));
	"
	PARQUET_COUNT="$(duckdb -noheader -list -c "SELECT COUNT(*) FROM read_parquet('$OUT/*/*.parquet');")"
	if [ "$PARQUET_COUNT" != "$SRC_COUNT" ]; then
		log "VERIFY FAILED for $DAY: sqlite=$SRC_COUNT parquet=$PARQUET_COUNT — keeping SQLite rows"
		exit 1
	fi
	sqlite3 "$DB_PATH" "
		DELETE FROM observation WHERE ts >= $T0 AND ts < $T1;
		DELETE FROM poll WHERE ts >= $T0 AND ts < $T1
			AND id NOT IN (SELECT DISTINCT poll_id FROM observation);"
	log "$DAY done: $PARQUET_COUNT rows archived, hot rows pruned"
done

sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
log "compaction complete"
