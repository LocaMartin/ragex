#!/usr/bin/env bash

# Check for required input file
if [[ -z "$1" ]] || [[ ! -f "$1" ]]; then
    echo "Usage: $0 <domains_file.txt>"
    exit 1
fi

INPUT_FILE="$1"
THREADS=25  # Adjust this based on your bandwidth and machine capabilities

echo "[+] Verifying live hosts with httpx..."
# Get a clean list of live base URLs (e.g., https://example.com)
LIVE_HOSTS=$(cat "$INPUT_FILE" | httpx -silent)

if [[ -z "$LIVE_HOSTS" ]]; then
    echo "[-] No live hosts found by httpx."
    exit 1
fi

echo "[+] Starting data extraction across $THREADS parallel threads..."

# Export functions so xargs can access them in subshells
process_target() {
    local target="$1"
    
    # 1. Sitemap.xml Parsing
    curl -sL --max-time 10 "$target/sitemap.xml" | grep -oP '(?<=<loc>).*?(?=</loc>)' | grep '^http' >> sitemap_urls.txt 2>/dev/null

    # 2. robots.txt Parsing
    curl -sL --max-time 10 "$target/robots.txt" | grep -iE '(Disallow|Allow|Sitemap):' | awk '{print $2}' >> robots_urls.txt 2>/dev/null

    # 3. security.txt Parsing
    curl -sL --max-time 10 "$target/.well-known/security.txt" | grep -iE '(Contact|Policy|Disclosure):' | awk '{print $2}' >> security_urls.txt 2>/dev/null

    # 4. RSS Feeds Parsing
    curl -sL --max-time 10 "$target/feed" | grep -oP '(?<=<link>).*?(?=</link>)' | grep '^http' >> rss_urls.txt 2>/dev/null

    # 5. Atom Feeds Parsing
    curl -sL --max-time 10 "$target/atom.xml" | grep -oP '(?<=<link href=").*?(?=")' | grep '^http' >> atom_urls.txt 2>/dev/null

    # 6. JSON Feeds Parsing
    curl -sL --max-time 10 "$target/feed.json" | grep -oP '(?<="url": ").*?(?=")|(?<="id": ").*?(?=")' | grep '^http' >> jsonfeed_urls.txt 2>/dev/null

    # 7. WordPress REST API Mapping
    curl -sL --max-time 10 "$target/wp-json/wp/v2/pages?per_page=100" | grep -oP '(?<=[\",]link":").*?(?=")' | sed 's/\\//g' | grep '^http' >> wp_urls.txt 2>/dev/null

    # 8. Web App Manifests
    curl -sL --max-time 10 "$target/manifest.json" | grep -oP '(?<="start_url": ").*?(?=")|(?<="src": ").*?(?=")' >> manifest_assets.txt 2>/dev/null

    # 9. Next.js Build Manifests
    curl -sL --max-time 10 "$target/_next/static/development/_buildManifest.js" | grep -oP '(?<=").*?(?=":)' >> nextjs_routes.txt 2>/dev/null
}

export -f process_target

# Feed live hosts into xargs to process multiple domains concurrently
echo "$LIVE_HOSTS" | xargs -I {} -P "$THREADS" bash -c 'process_target "{}"'

echo "[+] Extraction complete! Cleaning up and sorting files..."

# Clean up empty files and sort results uniquely
for file in sitemap_urls.txt robots_urls.txt security_urls.txt rss_urls.txt atom_urls.txt jsonfeed_urls.txt wp_urls.txt manifest_assets.txt nextjs_routes.txt; do
    if [[ -f "$file" ]]; then
        if [[ -s "$file" ]]; then
            sort -u "$file" -o "$file"
            echo "    -> Saved $(wc -l < "$file") items to $file"
        else
            rm "$file"
        fi
    fi
done

echo "[+] Done."
