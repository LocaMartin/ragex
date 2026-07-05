#!/bin/bash

INPUT_FILE="all.txt"
OUTPUT_FILE="waybackurls.txt"
STATE_FILE="resume.cfg"

touch "$OUTPUT_FILE"

# FIX 2: Handle key-value configuration files safely
START_LINE=0
if [ -f "$STATE_FILE" ]; then
    # Extract the number following "index=" if it exists
    EXTRACTED_INDEX=$(grep -E '^index=' "$STATE_FILE" | cut -d'=' -f2)
    if [[ "$EXTRACTED_INDEX" =~ ^[0-9]+$ ]]; then
        START_LINE="$EXTRACTED_INDEX"
    fi
fi

echo "Resuming scan from index line: $START_LINE"

# Track start time (5.5 hours safety boundary)
START_TIME=$(date +%s)
MAX_DURATION=19800 

CURRENT_LINE=0

while IFS= read -r host || [ -n "$host" ]; do
    CURRENT_LINE=$((CURRENT_LINE + 1))
    
    # Skip lines that were already processed in previous runs
    if [ "$CURRENT_LINE" -le "$START_LINE" ]; then
        continue
    fi

    if [ -n "$host" ]; then
        echo "Processing [$CURRENT_LINE]: $host"
        echo "$host" | waybackurls >> "$OUTPUT_FILE"
    fi

    # Periodically check if the time limit is approaching
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    
    if [ "$ELAPSED" -ge "$MAX_DURATION" ]; then
        echo "Approaching 6-hour limit ($ELAPSED seconds elapsed). Saving checkpoint and exiting..."
        # Maintain your custom format when rewriting the config
        echo -e "resume_from=$(tail -n 1 $INPUT_FILE)\nindex=$CURRENT_LINE" > "$STATE_FILE"
        exit 0
    fi

done < "$INPUT_FILE"

# Complete scan state preservation
echo -e "resume_from=DONE\nindex=$CURRENT_LINE" > "$STATE_FILE"
echo "Scan complete for all hosts!"
