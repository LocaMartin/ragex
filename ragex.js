const fs = require('fs');
const readline = require('readline');

// ANSI Escape Codes for Terminal Colors
const colors = {
    reset: "\x1b[0m",
    bright: "\x1b[1m",
    dim: "\x1b[2m",
    blue: "\x1b[34m",
    green: "\x1b[32m",
    yellow: "\x1b[33m",
    red: "\x1b[31m",
    cyan: "\x1b[36m"
};

// Main function to scan a URL
async function scanRemoteJs(url, patternFilePath = './patterns.json') {
    try {
        if (!fs.existsSync(patternFilePath)) {
            console.error(`${colors.red}[!] Pattern file not found at: ${patternFilePath}${colors.reset}`);
            return;
        }
        const patternsData = JSON.parse(fs.readFileSync(patternFilePath, 'utf8'));

        console.log(`\n${colors.cyan}[*] Fetching:${colors.reset} ${colors.bright}${url}${colors.reset}...`);
        
        const response = await fetch(url);
        if (!response.ok) {
            console.error(`  ${colors.red}[!] Failed to fetch. Status: ${response.status}${colors.reset}`);
            return;
        }
        const jsCode = await response.text();

        console.log(`${colors.blue}--------------------------------------------------${colors.reset}`);
        console.log(`${colors.bright}${colors.blue}[#] Scan Results for:${colors.reset} ${colors.bright}${url}${colors.reset}`);
        console.log(`${colors.blue}--------------------------------------------------${colors.reset}`);

        let totalMatchesFound = 0;

        patternsData.forEach(item => {
            const dynamicRegex = new RegExp(item.pattern, item.flags || 'g');
            const matches = jsCode.match(dynamicRegex) || [];

            if (matches.length > 0) {
                totalMatchesFound += matches.length;
                // Highlight vulnerabilities vs standard regex configurations
                const isBountyTrap = item.name.toLowerCase().includes('bounty trap');
                const titleColor = isBountyTrap ? colors.red : colors.green;

                console.log(`\n${titleColor}[+] ${item.name} (${matches.length} found):${colors.reset}`);
                matches.forEach(match => {
                    console.log(`  -> ${colors.yellow}${match.trim()}${colors.reset}`);
                });
            }
        });

        if (totalMatchesFound === 0) {
            console.log(`\n  ${colors.dim}-> No relevant validation patterns detected in this file.${colors.reset}`);
        }

    } catch (error) {
        console.error(`  ${colors.red}[!] Error processing ${url}: ${error.message}${colors.reset}`);
    }
}

// Check if URLs are being piped via standard input (e.g., cat urls.txt | node ragex.js)
if (!process.stdin.isTTY) {
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
        terminal: false
    });

    rl.on('line', async (line) => {
        const trimmedUrl = line.trim();
        if (trimmedUrl && (trimmedUrl.startsWith('http://') || trimmedUrl.startsWith('https://'))) {
            // Pause stream briefly to avoid overlapping console outputs during async operations
            rl.pause();
            await scanRemoteJs(trimmedUrl);
            rl.resume();
        }
    });
} else {
    // Fallback error fallback warning if run incorrectly without inputs
    console.log(`${colors.yellow}[!] Usage: cat urls.txt | node ragex.js${colors.reset}`);
}