const fs = require('fs');
const zlib = require('zlib');
const readline = require('readline');

const SKIP_EXTENSIONS = /\.(woff2?|ttf|otf|eot|mp3|mp4|png|jpe?g|gif|svg|css|ico|webp|zip|tar|gz|rar|7z|pdf|docx?|xlsx?|pptx?)(\?.*)?$/i;
const TIME_LIMIT_MS = 4.5 * 60 * 60 * 1000; // 4.5 hours
const STATE_FILE = 'scan_state.json';
const RESULTS_FILE = 'results.json';

async function generateResults() {
    if (!fs.existsSync('patterns.json')) {
        console.error("patterns.json not found.");
        return;
    }
    const patterns = JSON.parse(fs.readFileSync('patterns.json', 'utf8'));
    
    // Load existing results
    let allResults = [];
    if (fs.existsSync(RESULTS_FILE)) {
        try {
            allResults = JSON.parse(fs.readFileSync(RESULTS_FILE, 'utf8'));
            console.log(`Loaded ${allResults.length} existing results.`);
        } catch (e) {
            console.warn("Could not parse existing results.json. Starting fresh.");
        }
    }

    // Load state
    let startIndex = 0;
    let totalLines = 0;
    let isDone = false;
    
    if (fs.existsSync(STATE_FILE)) {
        const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
        startIndex = state.lastProcessedIndex || 0;
        totalLines = state.totalLines || 0;
        isDone = state.status === 'DONE';
    }

    if (isDone) {
        console.log("Scan already marked as DONE. Skipping.");
        return;
    }

    if (!fs.existsSync('waybackurls.txt.gz')) {
        console.error("waybackurls.txt.gz not found.");
        return;
    }

    // Count total lines first for progress tracking
    if (totalLines === 0) {
        totalLines = await countLines('waybackurls.txt.gz');
        console.log(`Total URLs to process: ${totalLines}`);
    }

    const fileStream = fs.createReadStream('waybackurls.txt.gz').pipe(zlib.createGunzip());
    const rl = readline.createInterface({ input: fileStream, crlfDelay: Infinity });

    const startTime = Date.now();
    let currentIndex = 0;
    let newMatches = 0;
    let processedThisRun = 0;

    console.log(`Resuming from index: ${startIndex}`);

    for await (const line of rl) {
        currentIndex++;

        // Skip already processed lines
        if (currentIndex <= startIndex) {
            continue;
        }

        // Check time limit
        if (Date.now() - startTime > TIME_LIMIT_MS) {
            console.log(`Time limit reached. Saving state at index ${currentIndex - 1}.`);
            saveState(currentIndex - 1, totalLines, false);
            saveResults(allResults);
            return;
        }

        const url = line.trim();
        
        if (!url || !url.startsWith('http') || SKIP_EXTENSIONS.test(url)) {
            continue;
        }
        
        try {
            const res = await fetch(url, { signal: AbortSignal.timeout(10000) });
            if (!res.ok) continue;
            
            const content = await res.text();
            const lines = content.split('\n');

            patterns.forEach(p => {
                const regex = new RegExp(p.pattern, p.flags || 'g');
                lines.forEach((l, index) => {
                    const matches = l.match(regex);
                    if (matches) {
                        matches.forEach(match => {
                            allResults.push({
                                id: allResults.length + 1,
                                url: url,
                                ragex: match.trim(),
                                line: index + 1,
                                patternName: p.name
                            });
                            newMatches++;
                        });
                    }
                });
            });
            processedThisRun++;
        } catch (e) {
            // Ignore fetch errors silently
        }
    }

    // Reached the end of the file
    console.log("Scan complete for all URLs.");
    saveState(currentIndex, totalLines, true);
    saveResults(allResults);
    
    // Output summary
    const remaining = totalLines - currentIndex;
    console.log(`=== SCAN SUMMARY ===`);
    console.log(`Processed this run: ${processedThisRun}`);
    console.log(`New matches found: ${newMatches}`);
    console.log(`Total results: ${allResults.length}`);
    console.log(`Remaining URLs: ${remaining}`);
}

async function countLines(filePath) {
    return new Promise((resolve, reject) => {
        let count = 0;
        fs.createReadStream(filePath)
            .pipe(zlib.createGunzip())
            .on('data', (chunk) => {
                for (let i = 0; i < chunk.length; ++i) {
                    if (chunk[i] === 10) count++;
                }
            })
            .on('end', () => resolve(count))
            .on('error', reject);
    });
}

function saveState(index, total, done) {
    const state = {
        lastProcessedIndex: index,
        totalLines: total,
        status: done ? 'DONE' : 'IN_PROGRESS',
        remaining: total - index
    };
    fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
    console.log(`State saved: ${JSON.stringify(state)}`);
    
    // Write to GitHub Step Summary
    const summary = `
### 📊 Scan Progress
- **Total URLs:** ${total}
- **Processed:** ${index}
- **Remaining:** ${state.remaining}
- **Status:** ${state.status}
`;
    if (process.env.GITHUB_STEP_SUMMARY) {
        fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary);
    }
}

function saveResults(results) {
    fs.writeFileSync(RESULTS_FILE, JSON.stringify(results, null, 2));
    console.log(`Results saved: ${results.length} total matches.`);
}

generateResults().catch(err => {
    console.error("Fatal error during scan:", err);
    // Attempt to save state even on fatal error
    try {
        const state = fs.existsSync(STATE_FILE) ? JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')) : {};
        saveState(state.lastProcessedIndex || 0, state.totalLines || 0, false);
    } catch (e) {}
});