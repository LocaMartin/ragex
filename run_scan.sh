#!/bin/bash

INPUT_FILE="all.txt"
OUTPUT_FILE="waybackurls.txt"
STATE_FILE="resume.cfg"

# Ensure required files exist
touch "$OUTPUT_FILE"
if [ ! -f "$STATE_FILE" ]; then
    echo "0" > "$STATE_FILE"
fi

# Track start time and set max execution time (e.g., 5.5 hours / 19800 seconds to be safe)
START_TIME=$(date +%s)
MAX_DURATION=19800 

# Read the last processed line number
START_LINE=$(cat "$STATE_FILE")
echo "Resuming scan from line: $START_LINE"

CURRENT_LINE=0

while IFS= read -r host || [ -n "$host" ]; do
    CURRENT_LINE=$((CURRENT_LINE + 1))
    
    # Skip lines that were already processed in previous runs
    if [ "$CURRENT_LINE" -le "$START_LINE" ]; then
        continue
    fi

    # Process the host (using tool of choice, e.g., waybackurls)
    if [ -n "$host" ]; then
        echo "Processing [$CURRENT_LINE]: $host"
        echo "$host" | waybackurls >> "$OUTPUT_FILE"
    fi

    # Periodically check if the time limit is approaching
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    
    if [ "$ELAPSED" -ge "$MAX_DURATION" ]; then
        echo "Approaching 6-hour limit ($ELAPSED seconds elapsed). Saving checkpoint and exiting gracefully..."
        echo "$CURRENT_LINE" > "$STATE_FILE"
        exit 0
    fi

done < "$INPUT_FILE"

# If the loop finishes completely, set state to the total line count
echo "$CURRENT_LINE" > "$STATE_FILE"
echo "Scan complete for all hosts!"
