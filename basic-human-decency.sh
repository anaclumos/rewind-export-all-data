#!/bin/bash
#===============================================================================
# exodus.sh - Rewind.ai Complete Data Exodus v2.0
#===============================================================================
# Single source of truth backup for Rewind/MemoryVault data.
#
# Key improvements over v1:
#   - Uses DATABASE timestamps (millisecond precision) instead of folder names
#   - Decrypts SQLCipher database to plain SQLite (no password required)
#   - Includes app context (bundleID, windowName) in filenames
#   - Exports audio with precise startTime from database
#   - Generates comprehensive manifest
#
# Creates:
#   ./backup/
#   ├── rewind.sqlite3              # Decrypted database (NO PASSWORD)
#   ├── videos/                     # Video recordings with DB timestamps
#   │   └── YYYY-MM-DD/
#   │       └── HHMMSS.mmm_app_window.mp4
#   ├── audio/                      # Audio recordings with DB timestamps
#   │   └── YYYY-MM-DD/
#   │       └── HHMMSS.mmm_duration.m4a
#   └── manifest.json               # Complete export metadata
#
# Requirements: sqlcipher (brew install sqlcipher)
# Optional: jq (for pretty manifest)
#
# Usage: ./exodus.sh [--backup-dir PATH] [--skip-videos] [--skip-audio] [--help]
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
SOURCE_DIR="${HOME}/Library/Application Support/com.memoryvault.MemoryVault"
BACKUP_DIR="./backup"

# SQLCipher password (same for all Rewind installations - discovered via reverse engineering)
# Credit: @m1guelpf https://x.com/m1guelpf/status/1854959335161401492
DB_PASSWORD="soiZ58XZJhdka55hLUp18yOtTUTDXz7Diu7Z4JzuwhRwGG13N6Z9RTVU1fGiKkuF"

# Source files
SOURCE_DB="${SOURCE_DIR}/db-enc.sqlite3"
CHUNKS_DIR="${SOURCE_DIR}/chunks"
SNIPPETS_DIR="${SOURCE_DIR}/snippets"

# Options
SKIP_VIDEOS=false
SKIP_AUDIO=false
VERBOSE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --skip-videos)
            SKIP_VIDEOS=true
            shift
            ;;
        --skip-audio)
            SKIP_AUDIO=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "Usage: ./exodus.sh [OPTIONS]"
            echo ""
            echo "Export Rewind.ai data with precise timestamps from database."
            echo ""
            echo "Options:"
            echo "  --backup-dir PATH   Output directory (default: ./backup)"
            echo "  --skip-videos       Skip video file copying"
            echo "  --skip-audio        Skip audio file copying"
            echo "  --verbose, -v       Verbose output"
            echo "  --help, -h          Show this help"
            echo ""
            echo "Output:"
            echo "  rewind.sqlite3      Decrypted database (no password)"
            echo "  videos/             Videos with DB timestamps"
            echo "  audio/              Audio with DB timestamps"
            echo "  manifest.json       Export metadata"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Derived paths
DEST_DB="${BACKUP_DIR}/rewind.sqlite3"
DEST_VIDEOS="${BACKUP_DIR}/videos"
DEST_AUDIO="${BACKUP_DIR}/audio"
MANIFEST="${BACKUP_DIR}/manifest.json"

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"; }
log_debug()   { $VERBOSE && echo -e "${CYAN}[DEBUG]${NC} $1" || true; }

#-------------------------------------------------------------------------------
# Utilities
#-------------------------------------------------------------------------------
sanitize_filename() {
    # Remove/replace problematic characters, limit length
    echo "$1" | tr -cd '[:alnum:]._-' | cut -c1-80
}

ts_to_filename() {
    # 2023-08-09T04:29:09.827 -> 042909.827
    local ts="$1"
    echo "$ts" | sed -E 's/.*T([0-9]{2}):([0-9]{2}):([0-9]{2})\.?([0-9]*).*/\1\2\3.\4/' | sed 's/\.$//'
}

ts_to_date() {
    # 2023-08-09T04:29:09.827 -> 2023-08-09
    echo "$1" | cut -dT -f1
}

format_bytes() {
    local b=$1
    if (( b >= 1073741824 )); then
        printf "%.2f GB" "$(echo "scale=2; $b/1073741824" | bc)"
    elif (( b >= 1048576 )); then
        printf "%.2f MB" "$(echo "scale=2; $b/1048576" | bc)"
    elif (( b >= 1024 )); then
        printf "%.2f KB" "$(echo "scale=2; $b/1024" | bc)"
    else
        echo "$b B"
    fi
}

format_duration() {
    local s=$1
    printf "%02d:%02d:%02d" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

format_timespan() {
    # Calculate human-readable span between two ISO dates
    # Input: 2023-08-10 2025-12-18
    # Output: "2 years, 4 months"
    local start_date="$1"
    local end_date="$2"

    # Parse dates
    local sy=$(echo "$start_date" | cut -d'-' -f1)
    local sm=$(echo "$start_date" | cut -d'-' -f2 | sed 's/^0//')
    local sd=$(echo "$start_date" | cut -d'-' -f3 | sed 's/^0//')

    local ey=$(echo "$end_date" | cut -d'-' -f1)
    local em=$(echo "$end_date" | cut -d'-' -f2 | sed 's/^0//')
    local ed=$(echo "$end_date" | cut -d'-' -f3 | sed 's/^0//')

    # Calculate differences
    local years=$((ey - sy))
    local months=$((em - sm))
    local days=$((ed - sd))

    # Adjust for negative months/days
    if ((days < 0)); then
        ((months--))
        days=$((days + 30))
    fi
    if ((months < 0)); then
        ((years--))
        months=$((months + 12))
    fi

    # Build human-readable string
    local result=""
    if ((years > 0)); then
        if ((years == 1)); then
            result="1 year"
        else
            result="${years} years"
        fi
    fi

    if ((months > 0)); then
        if [[ -n "$result" ]]; then
            result="${result}, "
        fi
        if ((months == 1)); then
            result="${result}1 month"
        else
            result="${result}${months} months"
        fi
    fi

    # If less than a month, show days
    if [[ -z "$result" ]]; then
        if ((days == 1)); then
            result="1 day"
        else
            result="${days} days"
        fi
    fi

    echo "$result"
}

#-------------------------------------------------------------------------------
# Preflight Checks
#-------------------------------------------------------------------------------
preflight() {
    log_step "Preflight Checks"
    local errors=0

    # sqlcipher
    if ! command -v sqlcipher &>/dev/null; then
        log_error "sqlcipher not found. Install: brew install sqlcipher"
        ((errors++))
    else
        log_success "sqlcipher: $(which sqlcipher)"
    fi

    # sqlite3 (for post-decrypt queries)
    if ! command -v sqlite3 &>/dev/null; then
        log_error "sqlite3 not found"
        ((errors++))
    else
        log_success "sqlite3: $(which sqlite3)"
    fi

    # Source database
    if [[ ! -f "$SOURCE_DB" ]]; then
        log_error "Database not found: $SOURCE_DB"
        ((errors++))
    else
        local sz=$(stat -f%z "$SOURCE_DB" 2>/dev/null || stat -c%s "$SOURCE_DB")
        log_success "Database: $(format_bytes $sz)"
    fi

    # Chunks - count, size, and timespan
    if [[ -d "$CHUNKS_DIR" ]]; then
        local vc=$(find "$CHUNKS_DIR" -type f ! -name ".*" 2>/dev/null | wc -l | tr -d ' ')
        local video_bytes=$(find "$CHUNKS_DIR" -type f ! -name ".*" -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')
        log_success "Video chunks: $vc files, $(format_bytes $video_bytes)"

        # Query database for video timespan (requires sqlcipher)
        if command -v sqlcipher &>/dev/null && [[ -f "$SOURCE_DB" ]]; then
            local timespan=$(sqlcipher "$SOURCE_DB" <<EOF 2>/dev/null
PRAGMA key = '${DB_PASSWORD}';
PRAGMA cipher_compatibility = 4;
SELECT
    MIN(createdAt) || ' to ' || MAX(createdAt)
FROM frame;
EOF
)
            # Clean up the output (remove "ok" prefix from PRAGMA)
            timespan=$(echo "$timespan" | grep -v "^ok$" | tail -1)
            if [[ -n "$timespan" && "$timespan" != " to " ]]; then
                local start_date=$(echo "$timespan" | cut -d' ' -f1 | cut -dT -f1)
                local end_date=$(echo "$timespan" | cut -d' ' -f3 | cut -dT -f1)
                local human_span=$(format_timespan "$start_date" "$end_date")
                log_success "Video timespan: $start_date to $end_date ($human_span)"
            fi
        fi
    else
        log_warn "Chunks directory not found (videos will be skipped)"
    fi

    # Snippets - count, size, and total duration
    if [[ -d "$SNIPPETS_DIR" ]]; then
        local ac=$(find "$SNIPPETS_DIR" -name "*.m4a" 2>/dev/null | wc -l | tr -d ' ')
        local audio_bytes=$(find "$SNIPPETS_DIR" -name "*.m4a" -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')
        log_success "Audio snippets: $ac files, $(format_bytes $audio_bytes)"

        # Query database for total audio duration
        if command -v sqlcipher &>/dev/null && [[ -f "$SOURCE_DB" ]]; then
            local total_dur=$(sqlcipher "$SOURCE_DB" <<EOF 2>/dev/null
PRAGMA key = '${DB_PASSWORD}';
PRAGMA cipher_compatibility = 4;
SELECT COALESCE(SUM(duration), 0) FROM audio;
EOF
)
            total_dur=$(echo "$total_dur" | grep -v "^ok$" | tail -1)
            if [[ -n "$total_dur" && "$total_dur" != "0" ]]; then
                local hours=$(echo "scale=1; $total_dur / 3600" | bc 2>/dev/null || echo "0")
                log_success "Audio duration: ${hours} hours"
            fi
        fi
    else
        log_warn "Snippets directory not found (audio will be skipped)"
    fi

    # Destination
    if [[ -d "$BACKUP_DIR" ]] && [[ -f "$DEST_DB" ]]; then
        log_warn "Backup exists: $BACKUP_DIR"
        read -p "Overwrite? [y/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && { log_error "Aborted"; exit 1; }
        rm -rf "$BACKUP_DIR"
    fi

    ((errors > 0)) && { log_error "Preflight failed"; exit 1; }
    log_success "All checks passed"
}

#-------------------------------------------------------------------------------
# Database Decryption
#-------------------------------------------------------------------------------
decrypt_database() {
    log_step "Decrypting Database"

    mkdir -p "$BACKUP_DIR"
    rm -f "$DEST_DB"

    log_info "Exporting encrypted SQLCipher → plain SQLite..."
    log_info "This may take a few minutes for large databases..."

    local t0=$(date +%s)

    # SQLCipher export to plaintext database
    sqlcipher "$SOURCE_DB" <<EOF
PRAGMA key = '${DB_PASSWORD}';
PRAGMA cipher_compatibility = 4;
ATTACH DATABASE '${DEST_DB}' AS plaintext KEY '';
SELECT sqlcipher_export('plaintext');
DETACH DATABASE plaintext;
EOF

    local t1=$(date +%s)

    # Verify
    if [[ ! -f "$DEST_DB" ]]; then
        log_error "Export failed - no output file"
        exit 1
    fi

    local tables=$(sqlite3 "$DEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';")
    if [[ "$tables" -eq 0 ]]; then
        log_error "Export failed - no tables"
        exit 1
    fi

    local sz=$(stat -f%z "$DEST_DB" 2>/dev/null || stat -c%s "$DEST_DB")
    log_success "Database decrypted: $(format_bytes $sz), $tables tables"
    log_info "Duration: $(format_duration $((t1-t0)))"
}

#-------------------------------------------------------------------------------
# Copy Videos with Database Timestamps
#-------------------------------------------------------------------------------
copy_videos() {
    $SKIP_VIDEOS && { log_info "Skipping videos (--skip-videos)"; return; }
    [[ ! -d "$CHUNKS_DIR" ]] && { log_warn "No chunks directory"; return; }

    log_step "Copying Videos with Database Timestamps"
    mkdir -p "$DEST_VIDEOS"

    # Query: video path, first frame timestamp, app context
    local map_file="${BACKUP_DIR}/.video_map.tsv"

    log_info "Querying database for video timestamps..."

    sqlite3 -separator $'\t' "$DEST_DB" <<'SQL' > "$map_file"
SELECT
    v.id,
    v.path,
    COALESCE(v.fileSize, 0),
    COALESCE(MIN(f.createdAt), '') as start_ts,
    COALESCE(s.bundleID, '') as app,
    COALESCE(s.windowName, '') as win
FROM video v
LEFT JOIN frame f ON f.videoId = v.id
LEFT JOIN segment seg ON seg.id = f.segmentId
LEFT JOIN (
    SELECT f2.videoId, s2.bundleID, s2.windowName
    FROM frame f2
    JOIN segment s2 ON s2.id = f2.segmentId
    WHERE f2.videoFrameIndex = 0 OR f2.id = (
        SELECT MIN(f3.id) FROM frame f3 WHERE f3.videoId = f2.videoId
    )
    GROUP BY f2.videoId
) s ON s.videoId = v.id
GROUP BY v.id
ORDER BY start_ts;
SQL

    local total=$(wc -l < "$map_file" | tr -d ' ')
    local copied=0 skipped=0 failed=0
    local bytes=0

    log_info "Processing $total videos..."

    while IFS=$'\t' read -r vid vpath vsize start_ts app win; do
        [[ -z "$vpath" ]] && continue

        local src="${CHUNKS_DIR}/${vpath}"
        [[ ! -f "$src" ]] && { ((skipped++)); continue; }

        # Fallback timestamp from path if DB has none
        if [[ -z "$start_ts" ]]; then
            local ym=$(echo "$vpath" | cut -d'/' -f1)
            local dy=$(echo "$vpath" | cut -d'/' -f2)
            start_ts="${ym:0:4}-${ym:4:2}-${dy}T00:00:00.000"
        fi

        local date_part=$(ts_to_date "$start_ts")
        local time_part=$(ts_to_filename "$start_ts")

        # Sanitize app/window names
        local app_short=$(echo "$app" | rev | cut -d'.' -f1 | rev | cut -c1-20)
        local win_safe=$(sanitize_filename "${win:-unknown}")
        [[ -z "$win_safe" ]] && win_safe="unknown"
        win_safe=$(echo "$win_safe" | cut -c1-30)

        local dest_dir="${DEST_VIDEOS}/${date_part}"
        mkdir -p "$dest_dir"

        local fname="${time_part}_${app_short}_${win_safe}.mp4"
        local dest="${dest_dir}/${fname}"

        # Handle duplicates
        local c=1
        while [[ -f "$dest" ]]; do
            fname="${time_part}_${app_short}_${win_safe}_${c}.mp4"
            dest="${dest_dir}/${fname}"
            ((c++))
        done

        if cp "$src" "$dest" 2>/dev/null; then
            ((copied++))
            ((bytes += vsize))
            log_debug "Copied: ${date_part}/${fname}"
        else
            ((failed++))
        fi

        # Progress
        local done=$((copied + skipped + failed))
        if (( done % 500 == 0 )); then
            printf "\r  [%d/%d] copied=%d skipped=%d failed=%d" "$done" "$total" "$copied" "$skipped" "$failed"
        fi
    done < "$map_file"

    printf "\r  [%d/%d] copied=%d skipped=%d failed=%d\n" "$total" "$total" "$copied" "$skipped" "$failed"

    rm -f "$map_file"
    log_success "Videos: $copied copied, $skipped skipped, $failed failed"
    log_info "Size: $(format_bytes $bytes)"
}

#-------------------------------------------------------------------------------
# Copy Audio with Database Timestamps
#-------------------------------------------------------------------------------
copy_audio() {
    $SKIP_AUDIO && { log_info "Skipping audio (--skip-audio)"; return; }
    [[ ! -d "$SNIPPETS_DIR" ]] && { log_warn "No snippets directory"; return; }

    log_step "Copying Audio with Database Timestamps"
    mkdir -p "$DEST_AUDIO"

    local map_file="${BACKUP_DIR}/.audio_map.tsv"

    sqlite3 -separator $'\t' "$DEST_DB" <<'SQL' > "$map_file"
SELECT
    a.id,
    a.path,
    a.startTime,
    a.duration,
    COALESCE(s.bundleID, ''),
    COALESCE(s.windowName, '')
FROM audio a
LEFT JOIN segment s ON s.id = a.segmentId
ORDER BY a.startTime;
SQL

    local total=$(wc -l < "$map_file" | tr -d ' ')
    local copied=0 skipped=0
    local total_dur=0

    log_info "Processing $total audio files..."

    while IFS=$'\t' read -r aid apath start_ts dur app win; do
        [[ -z "$apath" ]] && continue

        # Try absolute path first, then relative
        local src="$apath"
        if [[ ! -f "$src" ]]; then
            # Extract folder name from path like ".../snippets/2023-08-28T22:58:57/snippet.m4a"
            local snippet_folder=$(dirname "$apath" | xargs basename)
            src="${SNIPPETS_DIR}/${snippet_folder}/snippet.m4a"
        fi
        [[ ! -f "$src" ]] && { ((skipped++)); continue; }

        local date_part=$(ts_to_date "$start_ts")
        local time_part=$(ts_to_filename "$start_ts")
        local dur_sec=$(printf "%.0f" "$dur" 2>/dev/null || echo "0")

        local dest_dir="${DEST_AUDIO}/${date_part}"
        mkdir -p "$dest_dir"

        local fname="${time_part}_${dur_sec}s.m4a"
        local dest="${dest_dir}/${fname}"

        local c=1
        while [[ -f "$dest" ]]; do
            fname="${time_part}_${dur_sec}s_${c}.m4a"
            dest="${dest_dir}/${fname}"
            ((c++))
        done

        if cp "$src" "$dest" 2>/dev/null; then
            ((copied++))
            total_dur=$(echo "$total_dur + $dur" | bc 2>/dev/null || echo "$total_dur")
        fi
    done < "$map_file"

    rm -f "$map_file"

    local hours=$(echo "scale=1; $total_dur / 3600" | bc 2>/dev/null || echo "0")
    log_success "Audio: $copied copied, $skipped skipped"
    log_info "Duration: ${hours} hours"
}

#-------------------------------------------------------------------------------
# Generate Manifest
#-------------------------------------------------------------------------------
generate_manifest() {
    log_step "Generating Manifest"

    # Database stats
    local stats=$(sqlite3 "$DEST_DB" <<'SQL'
SELECT
    (SELECT COUNT(*) FROM frame),
    (SELECT COUNT(*) FROM segment),
    (SELECT COUNT(*) FROM video),
    (SELECT COUNT(*) FROM audio),
    (SELECT COUNT(*) FROM transcript_word),
    (SELECT MIN(startDate) FROM segment),
    (SELECT MAX(endDate) FROM segment);
SQL
)
    IFS='|' read -r frames segments videos audios words earliest latest <<< "$stats"

    # File counts
    local vf=$(find "$DEST_VIDEOS" -name "*.mp4" 2>/dev/null | wc -l | tr -d ' ')
    local af=$(find "$DEST_AUDIO" -name "*.m4a" 2>/dev/null | wc -l | tr -d ' ')
    local dbsz=$(stat -f%z "$DEST_DB" 2>/dev/null || stat -c%s "$DEST_DB")
    local totalsz=$(du -sk "$BACKUP_DIR" 2>/dev/null | cut -f1)
    totalsz=$((totalsz * 1024))

    # Top apps
    local top_apps=$(sqlite3 "$DEST_DB" <<'SQL'
SELECT bundleID, COUNT(*) FROM segment
WHERE bundleID IS NOT NULL AND bundleID != ''
GROUP BY bundleID ORDER BY COUNT(*) DESC LIMIT 10;
SQL
)

    cat > "$MANIFEST" <<EOF
{
  "exodus": {
    "version": "2.0.0",
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "source": "${SOURCE_DIR}",
    "destination": "$(cd "$BACKUP_DIR" && pwd)"
  },
  "database": {
    "file": "rewind.sqlite3",
    "size_bytes": ${dbsz},
    "encrypted": false,
    "password": null,
    "original": "SQLCipher AES-256-CBC, PBKDF2-SHA512 256k iterations"
  },
  "statistics": {
    "frames": ${frames},
    "segments": ${segments},
    "videos_db": ${videos},
    "audio_db": ${audios},
    "transcript_words": ${words},
    "videos_exported": ${vf},
    "audio_exported": ${af}
  },
  "date_range": {
    "earliest": "${earliest}",
    "latest": "${latest}"
  },
  "storage": {
    "bytes": ${totalsz},
    "human": "$(format_bytes $totalsz)"
  },
  "top_apps": [
$(echo "$top_apps" | while IFS='|' read -r app cnt; do
    printf '    {"bundle": "%s", "segments": %s},\n' "$app" "$cnt"
done | sed '$ s/,$//')
  ],
  "schema": {
    "key_tables": ["frame", "segment", "video", "audio", "transcript_word", "node", "searchRanking", "doc_segment"],
    "timestamp_format": "ISO 8601 with milliseconds (YYYY-MM-DDTHH:MM:SS.mmm)",
    "notes": [
      "frame.createdAt - precise screenshot timestamp",
      "segment.startDate/endDate - app focus window",
      "audio.startTime - precise audio recording start",
      "video.path - relative path under chunks/",
      "searchRanking - FTS5 OCR text index"
    ]
  },
  "usage": {
    "query_example": "sqlite3 rewind.sqlite3 'SELECT * FROM segment LIMIT 5;'",
    "search_example": "sqlite3 rewind.sqlite3 \"SELECT text FROM searchRanking WHERE text MATCH 'keyword';\"",
    "activity_example": "sqlite3 rewind.sqlite3 \"SELECT bundleID, windowName FROM segment WHERE date(startDate)='2024-01-15';\""
  }
}
EOF

    # Pretty print with jq if available
    if command -v jq &>/dev/null; then
        jq '.' "$MANIFEST" > "${MANIFEST}.tmp" && mv "${MANIFEST}.tmp" "$MANIFEST"
    fi

    log_success "Manifest: $MANIFEST"
}

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
summary() {
    log_step "Export Complete"

    local sz=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)

    echo ""
    echo -e "${BOLD}Location:${NC} $(cd "$BACKUP_DIR" && pwd)"
    echo -e "${BOLD}Size:${NC} $sz"
    echo ""
    echo -e "${BOLD}Contents:${NC}"
    echo -e "  ${GREEN}✓${NC} rewind.sqlite3     Plain SQLite (no password)"
    local vc=$(find "$DEST_VIDEOS" -name "*.mp4" 2>/dev/null | wc -l | tr -d ' ')
    local ac=$(find "$DEST_AUDIO" -name "*.m4a" 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  ${GREEN}✓${NC} videos/            $vc files (DB timestamps)"
    echo -e "  ${GREEN}✓${NC} audio/             $ac files (DB timestamps)"
    echo -e "  ${GREEN}✓${NC} manifest.json      Export metadata"
    echo ""
    echo -e "${BOLD}Quick Start:${NC}"
    echo "  sqlite3 $BACKUP_DIR/rewind.sqlite3 '.tables'"
    echo "  sqlite3 $BACKUP_DIR/rewind.sqlite3 'SELECT bundleID, COUNT(*) FROM segment GROUP BY bundleID LIMIT 10;'"
    echo ""
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${RED}"
    echo '    ███████╗██╗  ██╗ ██████╗██╗  ██╗    ██╗   ██╗ ██████╗ ██╗   ██╗'
    echo '    ██╔════╝╚██╗██╔╝██╔════╝██║ ██╔╝    ╚██╗ ██╔╝██╔═══██╗██║   ██║'
    echo '    █████╗   ╚███╔╝ ██║     █████╔╝      ╚████╔╝ ██║   ██║██║   ██║'
    echo '    ██╔══╝   ██╔██╗ ██║     ██╔═██╗       ╚██╔╝  ██║   ██║██║   ██║'
    echo '    ██║     ██╔╝ ██╗╚██████╗██║  ██╗       ██║   ╚██████╔╝╚██████╔╝'
    echo '    ╚═╝     ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝       ╚═╝    ╚═════╝  ╚═════╝ '
    echo ""
    echo '    ██████╗ ███████╗██╗    ██╗██╗███╗   ██╗██████╗      █████╗ ██╗'
    echo '    ██╔══██╗██╔════╝██║    ██║██║████╗  ██║██╔══██╗    ██╔══██╗██║'
    echo '    ██████╔╝█████╗  ██║ █╗ ██║██║██╔██╗ ██║██║  ██║    ███████║██║'
    echo '    ██╔══██╗██╔══╝  ██║███╗██║██║██║╚██╗██║██║  ██║    ██╔══██║██║'
    echo '    ██║  ██║███████╗╚███╔███╔╝██║██║ ╚████║██████╔╝    ██║  ██║██║'
    echo '    ╚═╝  ╚═╝╚══════╝ ╚══╝╚══╝ ╚═╝╚═╝  ╚═══╝╚═════╝     ╚═╝  ╚═╝╚═╝'
    echo -e "${NC}"
    echo -e "    ${CYAN}The export tool Dan should have shipped. Basic human decency.${NC}"
    echo -e "    ${BLUE}https://github.com/anaclumos/rewind-export-all-data${NC}"
    echo ""

    local t0=$(date +%s)

    preflight
    decrypt_database
    copy_videos
    copy_audio
    generate_manifest

    local t1=$(date +%s)
    summary

    log_info "Total time: $(format_duration $((t1-t0)))"
    echo ""
}

main "$@"
