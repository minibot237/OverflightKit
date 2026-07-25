#!/bin/sh
# Backfill historical ship traffic from NOAA MarineCadastre daily AIS files
# straight into the Parquet archive (bypasses the SQLite hot tier entirely).
#
#   scripts/ais-backfill.sh 2025-01-01 [2025-01-02 ...]
#
# 2025+ files are zstd csv (lowercase columns, lon before lat); 2024 and
# earlier are zip (Capitalized columns, LAT before LON). Both eras verified
# against the official data dictionary 2026-07-25. ~220-320MB per day.
#
#   ARCHIVE_DIR  default ~/.overflight/archive
set -eu

ARCHIVE_DIR="${ARCHIVE_DIR:-$HOME/.overflight/archive}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

command -v duckdb >/dev/null || { echo "duckdb CLI not found (brew install duckdb)" >&2; exit 1; }
[ $# -ge 1 ] || { echo "usage: $0 YYYY-MM-DD [YYYY-MM-DD ...]" >&2; exit 1; }
mkdir -p "$ARCHIVE_DIR"

# 2-char geohash bucket (10 bits: 5 from lon, 5 from lat, interleaved lon
# first) as a DuckDB macro — matches Geohash.encode(...).prefix(2) in core.
GH2_MACRO="
CREATE MACRO gh2(lat, lon) AS (
	WITH bits AS (
		SELECT CAST(floor((lon + 180) / 360 * 32) AS INTEGER) AS li,
		       CAST(floor((lat + 90) / 180 * 32) AS INTEGER) AS la
	)
	SELECT substr('0123456789bcdefghjkmnpqrstuvwxyz',
			1 + (((li >> 4) & 1) * 16 + ((la >> 4) & 1) * 8 + ((li >> 3) & 1) * 4 + ((la >> 3) & 1) * 2 + ((li >> 2) & 1)), 1)
		|| substr('0123456789bcdefghjkmnpqrstuvwxyz',
			1 + (((la >> 2) & 1) * 16 + ((li >> 1) & 1) * 8 + ((la >> 1) & 1) * 4 + ((li >> 0) & 1) * 2 + ((la >> 0) & 1)), 1)
	FROM bits
);"

for DAY in "$@"; do
	YEAR="${DAY%%-*}"
	OUT="$ARCHIVE_DIR/date=$DAY"
	if [ -d "$OUT" ] && find "$OUT" -name "*.parquet" | grep -q .; then
		echo "$DAY: archive partition already exists, skipping (rm it to redo)" >&2
		continue
	fi

	if [ "$YEAR" -ge 2025 ]; then
		URL="https://coast.noaa.gov/htdata/CMSP/AISDataHandler/$YEAR/ais-$DAY.csv.zst"
		FILE="$STAGE/ais-$DAY.csv.zst"
		echo "$DAY: downloading $URL"
		curl -sf -o "$FILE" "$URL" || { echo "$DAY: download failed" >&2; continue; }
		READ="read_csv('$FILE')"
		COLS="mmsi AS vid, epoch(base_date_time) AS ts, latitude AS lat, longitude AS lon,
			sog AS speed_kt, heading, vessel_name AS callsign"
	else
		URL="https://coast.noaa.gov/htdata/CMSP/AISDataHandler/$YEAR/AIS_$(echo "$DAY" | tr - _).zip"
		FILE="$STAGE/ais-$DAY.zip"
		echo "$DAY: downloading $URL"
		curl -sf -o "$FILE" "$URL" || { echo "$DAY: download failed" >&2; continue; }
		unzip -q -o "$FILE" -d "$STAGE/$DAY"
		READ="read_csv('$STAGE/$DAY/*.csv')"
		COLS="MMSI AS vid, epoch(BaseDateTime) AS ts, LAT AS lat, LON AS lon,
			SOG AS speed_kt, Heading AS heading, VesselName AS callsign"
	fi

	echo "$DAY: converting to parquet"
	duckdb -c "
		$GH2_MACRO
		COPY (
			SELECT 'vessel' AS kind, CAST(vid AS VARCHAR) AS vid, ts, lat, lon,
				NULL::DOUBLE AS alt_ft, NULL::VARCHAR AS alt_src,
				speed_kt, CAST(heading AS DOUBLE) AS heading,
				nullif(trim(CAST(callsign AS VARCHAR)), '') AS callsign,
				'marinecadastre' AS source, gh2(lat, lon) AS geohash, gh2(lat, lon) AS geo
			FROM (SELECT $COLS FROM $READ)
			WHERE lat BETWEEN -90 AND 90 AND lon BETWEEN -180 AND 180
		) TO '$OUT' (FORMAT PARQUET, COMPRESSION ZSTD, PARTITION_BY (geo));
	"
	N="$(duckdb -noheader -list -c "SELECT COUNT(*) FROM read_parquet('$OUT/*/*.parquet');")"
	echo "$DAY: $N vessel observations archived"
	rm -f "$FILE"
done
echo "backfill done"
