#!/usr/bin/env bash

INPUT_FILE="all.txt"
OUTPUT_FILE="waybackurls.txt"
OUTPUT_GZ="waybackurls.txt.gz"
STATE_FILE="resume.cfg"

touch "$OUTPUT_FILE"

# Restore previous compressed output if raw txt does not exist or is empty
if [ ! -s "$OUTPUT_FILE" ] && [ -f "$OUTPUT_GZ" ]; then
    echo "[+] Restoring previous output from $OUTPUT_GZ"
    gzip -dc "$OUTPUT_GZ" > "$OUTPUT_FILE" || true
fi

clean_and_compress_output() {
    tmp_file="$(mktemp)"

    # Trim leading/trailing whitespace, remove blank lines, keep URLs intact, dedupe
    awk '
    {
        gsub(/\r/, "")
        sub(/^[[:space:]]+/, "")
        sub(/[[:space:]]+$/, "")
        if ($0 != "") print
    }
    ' "$OUTPUT_FILE" | LC_ALL=C sort -u > "$tmp_file"

    mv "$tmp_file" "$OUTPUT_FILE"

    # Compress using Linux gzip utility
    gzip -9 -c "$OUTPUT_FILE" > "$OUTPUT_GZ"

    echo "[+] Cleaned URLs: $(wc -l < "$OUTPUT_FILE")"
    echo "[+] Compressed output saved: $OUTPUT_GZ"
}

START_LINE=0
if [ -f "$STATE_FILE" ]; then
    EXTRACTED_INDEX="$(grep -E '^index=' "$STATE_FILE" | cut -d'=' -f2)"
    if [[ "$EXTRACTED_INDEX" =~ ^[0-9]+$ ]]; then
        START_LINE="$EXTRACTED_INDEX"
    fi
fi

echo "[+] Resuming scan from index line: $START_LINE"

START_TIME="$(date +%s)"
MAX_DURATION=19800

CURRENT_LINE=0

while IFS= read -r host || [ -n "$host" ]; do
    CURRENT_LINE=$((CURRENT_LINE + 1))

    if [ "$CURRENT_LINE" -le "$START_LINE" ]; then
        continue
    fi

    # Trim host line
    host="$(printf '%s' "$host" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

    if [ -n "$host" ]; then
        echo "[+] Processing [$CURRENT_LINE]: $host"
        echo "$host" | waybackurls >> "$OUTPUT_FILE"
    fi

    NOW="$(date +%s)"
    ELAPSED=$((NOW - START_TIME))

    if [ "$ELAPSED" -ge "$MAX_DURATION" ]; then
        echo "[!] Approaching 6-hour limit. Saving checkpoint..."

        echo -e "resume_from=$host\nindex=$CURRENT_LINE" > "$STATE_FILE"

        clean_and_compress_output

        exit 0
    fi

done < "$INPUT_FILE"

echo -e "resume_from=DONE\nindex=$CURRENT_LINE" > "$STATE_FILE"

clean_and_compress_output

echo "[+] Scan complete for all hosts!"
