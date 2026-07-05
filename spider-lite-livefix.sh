#!/usr/bin/env bash

# spider-lite.sh
# Input  : domains.txt / hosts file
# Output : allurls.txt + categorized files inside spider-out/
# Usage  : ./spider-lite.sh domains.txt [allurls.txt]
# Example: THREADS=20 OUT_DIR=spider-out ./spider-lite.sh domains.txt allurls.txt

set -u

if [[ -z "${1:-}" ]] || [[ ! -f "${1:-}" ]]; then
    echo "Usage: $0 <domains_file.txt> [output_allurls.txt]"
    echo "Example: THREADS=20 OUT_DIR=spider-out $0 domains.txt allurls.txt"
    exit 1
fi

INPUT_FILE="$1"
OUT_FILE="${2:-allurls.txt}"
OUT_DIR="${OUT_DIR:-spider-out}"
THREADS="${THREADS:-50}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-2}"
MAX_TIME="${MAX_TIME:-5}"
RETRIES="${RETRIES:-0}"
MAX_SITEMAPS="${MAX_SITEMAPS:-3}"
MAX_BYTES="${MAX_BYTES:-500000}"
UA="${UA:-Mozilla/5.0 (compatible; spider-lite/2.0; +https://example.com/security-research)}"

mkdir -p "$OUT_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spider-lite.XXXXXX")"
TARGETS_FILE="$OUT_DIR/normalized_targets.txt"
RESULTS_DIR="$WORK_DIR/results"
mkdir -p "$RESULTS_DIR"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

log() {
    printf '[+] %s\n' "$*" >&2
}

warn() {
    printf '[!] %s\n' "$*" >&2
}

add_origin() {
    local origin="$1"
    origin="${origin//$'\r'/}"
    origin="$(printf '%s' "$origin" | sed -E 's/[[:space:],;.)]+$//; s#/$##')"

    # keep only normal http/https origins, not paths
    if [[ "$origin" =~ ^https?://[A-Za-z0-9._-]+(:[0-9]+)?$ ]]; then
        printf '%s\n' "$origin"
    fi
}

normalize_targets() {
    local input="$1"
    : > "$TARGETS_FILE.tmp"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        # Skip CIDR ranges. Curling https://194.41.128.0 is not useful here.
        if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            continue
        fi

        # Extract real URLs embedded inside scope lines or httpx output.
        # Example: https://api.example.com or "any applications under https://www.example.com/latest"
        printf '%s\n' "$line" \
            | grep -aEoi 'https?://[^[:space:]<>"]+' 2>/dev/null \
            | sed -E 's#^(https?://[^/?#]+).*#\1#; s/[,;.)\]}>"'"'"']+$//' \
            | while IFS= read -r url_origin; do
                add_origin "$url_origin"
              done >> "$TARGETS_FILE.tmp"

        # Plain host or host/path entries from domains.txt.
        # Example: api.example.com or manager.example.com/v3/*
        if [[ "$line" != *" "* && "$line" != *"://"* && "$line" == *.* ]]; then
            local candidate="$line"
            candidate="${candidate%%/*}"
            candidate="$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')"
            candidate="${candidate#http://}"
            candidate="${candidate#https://}"
            candidate="${candidate%.}"

            # Skip wildcard/noisy/non-host values.
            [[ "$candidate" == *"*"* ]] && continue
            [[ "$candidate" == *"@"* ]] && continue
            [[ "$candidate" == *"%"* ]] && continue

            if [[ "$candidate" =~ ^[a-z0-9._-]+(:[0-9]+)?$ ]]; then
                add_origin "https://$candidate" >> "$TARGETS_FILE.tmp"
            fi
        fi
    done < "$input"

    sort -u "$TARGETS_FILE.tmp" > "$TARGETS_FILE"
    rm -f "$TARGETS_FILE.tmp"
}

fetch() {
    local url="$1"
    curl -kfsSL --compressed \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        --retry "$RETRIES" \
        -A "$UA" \
        "$url" 2>/dev/null \
        | head -c "$MAX_BYTES" \
        | LC_ALL=C tr -d '\000' || true
}

make_abs() {
    local base="$1"
    local raw="$2"
    local scheme="${base%%://*}"

    raw="${raw//$'\r'/}"
    raw="$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    raw="${raw%%#*}"
    raw="${raw%,}"
    raw="${raw%;}"
    raw="${raw%)}"
    raw="${raw%\]}"
    raw="${raw%\"}"
    raw="${raw%\'}"

    [[ -z "$raw" ]] && return 0
    [[ "$raw" == "#" ]] && return 0
    [[ "$raw" == *"*"* ]] && return 0
    [[ "$raw" == javascript:* ]] && return 0
    [[ "$raw" == mailto:* ]] && return 0
    [[ "$raw" == tel:* ]] && return 0
    [[ "$raw" == data:* ]] && return 0
    [[ "$raw" == blob:* ]] && return 0

    if [[ "$raw" =~ ^https?:// ]]; then
        printf '%s\n' "$raw"
    elif [[ "$raw" == //* ]]; then
        printf '%s:%s\n' "$scheme" "$raw"
    elif [[ "$raw" == /* ]]; then
        printf '%s%s\n' "$base" "$raw"
    elif [[ "$raw" == ./* ]]; then
        printf '%s/%s\n' "$base" "${raw#./}"
    elif [[ "$raw" == ../* ]]; then
        printf '%s/%s\n' "$base" "$raw"
    elif [[ "$raw" == *.* || "$raw" == api* || "$raw" == auth* ]]; then
        printf '%s/%s\n' "$base" "$raw"
    fi
}

emit() {
    local category="$1"
    local base="$2"
    local raw="$3"
    local url

    url="$(make_abs "$base" "$raw")"
    [[ -z "$url" ]] && return 0

    printf '%s\n' "$url" >> "$CURRENT_DIR/${category}.tmp"
    printf '%s\n' "$url" >> "$CURRENT_DIR/all.tmp"
}

extract_http_urls() {
    grep -aEoi 'https?://[^[:space:]<>"]+' 2>/dev/null \
        | sed -E 's/[,;.)\]}>"'"'"']+$//'
}

extract_html_attrs() {
    local base="$1"
    local category="$2"

    grep -Eoi "(href|src|action)[[:space:]]*=[[:space:]]*['\"][^'\"]+" 2>/dev/null \
        | sed -E "s/^[^=]+=[[:space:]]*['\"]//" \
        | while IFS= read -r item; do
            emit "$category" "$base" "$item"
          done
}

extract_json_urls() {
    local base="$1"
    local category="$2"

    grep -Eo '"(url|id|link|source_url|home_page_url|feed_url|start_url|src|scope)"[[:space:]]*:[[:space:]]*"[^"]+"' 2>/dev/null \
        | sed -E 's/^"[^"]+"[[:space:]]*:[[:space:]]*"//; s/"$//; s#\\/#/#g' \
        | while IFS= read -r item; do
            emit "$category" "$base" "$item"
          done
}

process_sitemaps() {
    local base="$1"
    local body loc
    local sitemap_queue="$CURRENT_DIR/sitemap_queue.tmp"
    : > "$sitemap_queue"

    for path in /sitemap.xml /sitemap_index.xml /wp-sitemap.xml /sitemap.txt; do
        body="$(fetch "$base$path")"
        [[ -z "$body" ]] && continue

        printf '%s\n' "$body" \
            | grep -Eoi '<loc>[^<]+' 2>/dev/null \
            | sed -E 's#<loc>##I' \
            | while IFS= read -r loc; do
                emit sitemap_urls "$base" "$loc"
                [[ "$loc" == *sitemap* ]] && printf '%s\n' "$loc" >> "$sitemap_queue"
              done

        printf '%s\n' "$body" \
            | extract_http_urls \
            | while IFS= read -r loc; do
                emit sitemap_urls "$base" "$loc"
                [[ "$loc" == *sitemap* ]] && printf '%s\n' "$loc" >> "$sitemap_queue"
              done
    done

    sort -u "$sitemap_queue" 2>/dev/null | head -n "$MAX_SITEMAPS" | while IFS= read -r child_sitemap; do
        body="$(fetch "$child_sitemap")"
        [[ -z "$body" ]] && continue

        printf '%s\n' "$body" \
            | grep -Eoi '<loc>[^<]+' 2>/dev/null \
            | sed -E 's#<loc>##I' \
            | while IFS= read -r loc; do
                emit sitemap_urls "$base" "$loc"
              done
    done
}

process_robots() {
    local base="$1"
    fetch "$base/robots.txt" \
        | awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*(Allow|Disallow|Sitemap):/ {sub(/^[^:]+:[[:space:]]*/, ""); print}' \
        | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
        | while IFS= read -r item; do
            emit robots_urls "$base" "$item"
          done
}

process_security_txt() {
    local base="$1"
    for path in /.well-known/security.txt /security.txt; do
        fetch "$base$path" \
            | awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*(Contact|Policy|Disclosure|Acknowledgments|Hiring|Canonical|Encryption):/ {sub(/^[^:]+:[[:space:]]*/, ""); print}' \
            | while IFS= read -r item; do
                emit security_urls "$base" "$item"
              done
    done
}

process_feeds() {
    local base="$1"
    local body

    for path in /feed /rss /rss.xml /atom.xml /feed.xml /feed.json; do
        body="$(fetch "$base$path")"
        [[ -z "$body" ]] && continue

        # RSS style: <link>https://example.com/post</link>
        printf '%s\n' "$body" \
            | grep -Eoi '<link[^>]*>[^<]+' 2>/dev/null \
            | sed -E 's#<link[^>]*>##I' \
            | while IFS= read -r item; do
                emit feed_urls "$base" "$item"
              done

        # Atom style: <link href="https://example.com/post" />
        printf '%s\n' "$body" \
            | grep -Eoi '<link[^>]+href=["'"'"'][^"'"'"']+' 2>/dev/null \
            | sed -E 's/^.*href=["'"'"']//I' \
            | while IFS= read -r item; do
                emit feed_urls "$base" "$item"
              done

        printf '%s\n' "$body" | extract_json_urls "$base" feed_urls
    done
}

process_wordpress() {
    local base="$1"
    local body

    for path in \
        '/wp-json/wp/v2/pages?per_page=100&_fields=link' \
        '/wp-json/wp/v2/posts?per_page=100&_fields=link' \
        '/wp-json/wp/v2/media?per_page=100&_fields=link,source_url'; do
        body="$(fetch "$base$path")"
        [[ -z "$body" ]] && continue
        printf '%s\n' "$body" | extract_json_urls "$base" wp_urls
    done
}

process_manifests() {
    local base="$1"
    local body

    for path in /manifest.json /manifest.webmanifest /site.webmanifest; do
        body="$(fetch "$base$path")"
        [[ -z "$body" ]] && continue
        printf '%s\n' "$body" | extract_json_urls "$base" manifest_urls
        printf '%s\n' "$body" | extract_http_urls | while IFS= read -r item; do
            emit manifest_urls "$base" "$item"
        done
    done
}

process_homepage() {
    local base="$1"
    local body manifest_path manifest_body
    body="$(fetch "$base/")"
    [[ -z "$body" ]] && return 0

    printf '%s\n' "$body" | extract_html_attrs "$base" home_urls

    # Next.js static assets and manifest discovery from the real homepage.
    printf '%s\n' "$body" \
        | grep -Eo "/_next/static/[^\"'<>[:space:]]+" 2>/dev/null \
        | while IFS= read -r item; do
            emit nextjs_urls "$base" "$item"
          done

    {
        printf '%s\n' "$body" \
            | grep -Eo "/_next/static/[^\"'<>[:space:]]+(_buildManifest|_ssgManifest)\.js" 2>/dev/null
        printf '%s\n' "/_next/static/development/_buildManifest.js"
    } | sort -u | while IFS= read -r manifest_path; do
        manifest_body="$(fetch "$base$manifest_path")"
        [[ -z "$manifest_body" ]] && continue
        emit nextjs_urls "$base" "$manifest_path"
        printf '%s\n' "$manifest_body" \
            | grep -Eo '"/[^"]+"' 2>/dev/null \
            | tr -d '"' \
            | while IFS= read -r route; do
                emit nextjs_urls "$base" "$route"
              done
    done
}

process_target() {
    local target="$1"
    local base="${target%/}"
    local safe

    safe="$(printf '%s' "$base" | sed -E 's#https?://##; s#[^A-Za-z0-9._-]#_#g')_$$"
    CURRENT_DIR="$RESULTS_DIR/$safe"
    mkdir -p "$CURRENT_DIR"

    printf '%s\n' "$base" >> "$CURRENT_DIR/targets_checked.tmp"

    process_sitemaps "$base"
    process_robots "$base"
    process_security_txt "$base"
    process_feeds "$base"
    process_wordpress "$base"
    process_manifests "$base"
    process_homepage "$base"
}

merge_results() {
    local category="$1"
    local dest="$OUT_DIR/${category}.txt"

    find "$RESULTS_DIR" -type f -name "${category}.tmp" -print0 2>/dev/null \
        | xargs -0 cat 2>/dev/null \
        | sed -E 's/[[:space:]]+$//' \
        | grep -E '^https?://' \
        | sort -u > "$dest.tmp" || true

    if [[ -s "$dest.tmp" ]]; then
        mv "$dest.tmp" "$dest"
        log "Saved $(wc -l < "$dest") items to $dest"
    else
        rm -f "$dest.tmp" "$dest"
    fi
}

normalize_targets "$INPUT_FILE"
TARGET_COUNT="$(wc -l < "$TARGETS_FILE" | tr -d ' ')"
log "Normalized $TARGET_COUNT targets from $INPUT_FILE -> $TARGETS_FILE"

if [[ "${NORMALIZE_ONLY:-0}" == "1" ]]; then
    cat "$TARGETS_FILE"
    exit 0
fi

if [[ "$TARGET_COUNT" -eq 0 ]]; then
    warn "No valid targets found in $INPUT_FILE"
    exit 1
fi

export CONNECT_TIMEOUT MAX_TIME RETRIES MAX_SITEMAPS MAX_BYTES UA RESULTS_DIR
export -f fetch make_abs emit extract_http_urls extract_html_attrs extract_json_urls
export -f process_sitemaps process_robots process_security_txt process_feeds process_wordpress process_manifests process_homepage process_target

log "Starting extraction with $THREADS parallel threads..."
tr '\n' '\0' < "$TARGETS_FILE" | xargs -0 -n1 -P "$THREADS" bash -c 'process_target "$1"' _

log "Merging and deduplicating results..."
for category in targets_checked sitemap_urls robots_urls security_urls feed_urls wp_urls manifest_urls home_urls nextjs_urls; do
    merge_results "$category"
done

find "$RESULTS_DIR" -type f -name 'all.tmp' -print0 2>/dev/null \
    | xargs -0 cat 2>/dev/null \
    | sed -E 's/[[:space:]]+$//' \
    | grep -E '^https?://' \
    | sort -u > "$OUT_FILE.tmp" || true

if [[ -s "$OUT_FILE.tmp" ]]; then
    mv "$OUT_FILE.tmp" "$OUT_FILE"
    log "Saved combined output: $(wc -l < "$OUT_FILE") unique URLs -> $OUT_FILE"
else
    rm -f "$OUT_FILE.tmp"
    : > "$OUT_FILE"
    warn "No URLs found. Created empty $OUT_FILE"
fi

log "Done. Categorized files are in $OUT_DIR/"
