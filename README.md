# basic-human-decency.sh

> The export tool Dan Siroker should have shipped.

```
███████╗██╗  ██╗ ██████╗██╗  ██╗    ██╗   ██╗ ██████╗ ██╗   ██╗
██╔════╝╚██╗██╔╝██╔════╝██║ ██╔╝    ╚██╗ ██╔╝██╔═══██╗██║   ██║
█████╗   ╚███╔╝ ██║     █████╔╝      ╚████╔╝ ██║   ██║██║   ██║
██╔══╝   ██╔██╗ ██║     ██╔═██╗       ╚██╔╝  ██║   ██║██║   ██║
██║     ██╔╝ ██╗╚██████╗██║  ██╗       ██║   ╚██████╔╝╚██████╔╝
╚═╝     ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝       ╚═╝    ╚═════╝  ╚═════╝

██████╗ ███████╗██╗    ██╗██╗███╗   ██╗██████╗      █████╗ ██╗
██╔══██╗██╔════╝██║    ██║██║████╗  ██║██╔══██╗    ██╔══██╗██║
██████╔╝█████╗  ██║ █╗ ██║██║██╔██╗ ██║██║  ██║    ███████║██║
██╔══██╗██╔══╝  ██║███╗██║██║██║╚██╗██║██║  ██║    ██╔══██║██║
██║  ██║███████╗╚███╔███╔╝██║██║ ╚████║██████╔╝    ██║  ██║██║
╚═╝  ╚═╝╚══════╝ ╚══╝╚══╝ ╚═╝╚═╝  ╚═══╝╚═════╝     ╚═╝  ╚═╝╚═╝
```

## What Happened

[Rewind.ai](https://rewind.ai) was a macOS app that recorded your screen and audio 24/7, letting you search through everything you've ever seen or heard on your computer. It stored years of your personal data locally.

In December 2025, Meta acquired the company (now called Limitless). The Rewind app is shutting down on **December 19, 2025**.

**They provided no official way to export your data.**

Your years of recordings, transcripts, and memories—locked behind an encrypted database with no key provided.

This script is what Dan Siroker (CEO) should have shipped. Basic human decency.

## What This Script Does

- **Decrypts** your SQLCipher database to plain SQLite (no password needed after export)
- **Exports videos** with precise timestamps from the database (not folder names)
- **Exports audio** recordings with accurate timing
- **Preserves** all metadata: which app, which window, browser URLs
- **Generates** a manifest with your complete usage history

## Credits

Database password discovered by [@m1guelpf](https://x.com/m1guelpf/status/1854959335161401492).

The password is hardcoded and **identical for all Rewind installations**—a security oversight that now benefits users trying to access their own data.

## Requirements

```bash
brew install sqlcipher
```

Optional (for pretty JSON manifest):
```bash
brew install jq
```

## Usage

```bash
# Clone and run
git clone https://github.com/anaclumos/rewind-export-all-data.git
cd rewind-export-all-data
chmod +x basic-human-decency.sh
./basic-human-decency.sh
```

### Options

```
--backup-dir PATH   Output directory (default: ./backup)
--skip-videos       Skip video file copying (just export database)
--skip-audio        Skip audio file copying
--verbose, -v       Show detailed progress
--help, -h          Show help
```

### Examples

```bash
# Full export
./basic-human-decency.sh

# Export to external drive
./basic-human-decency.sh --backup-dir /Volumes/Backup/rewind

# Database only (fastest, ~35GB → ~35GB)
./basic-human-decency.sh --skip-videos --skip-audio

# See everything happening
./basic-human-decency.sh --verbose
```

## Output

```
./backup/
├── rewind.sqlite3              # Decrypted database (NO PASSWORD)
├── videos/
│   └── YYYY-MM-DD/
│       └── HHMMSS.mmm_app_window.mp4
├── audio/
│   └── YYYY-MM-DD/
│       └── HHMMSS.mmm_duration.m4a
└── manifest.json               # Export metadata
```

## After Export

Your data is now in plain SQLite. Query it however you want:

```bash
# List all tables
sqlite3 backup/rewind.sqlite3 '.tables'

# See your most-used apps
sqlite3 backup/rewind.sqlite3 '
  SELECT bundleID, COUNT(*) as segments
  FROM segment
  GROUP BY bundleID
  ORDER BY segments DESC
  LIMIT 10;
'

# Search OCR text (everything you've ever seen on screen)
sqlite3 backup/rewind.sqlite3 "
  SELECT text FROM searchRanking
  WHERE text MATCH 'password'
  LIMIT 10;
"

# Get activity for a specific date
sqlite3 backup/rewind.sqlite3 "
  SELECT datetime(startDate), bundleID, windowName
  FROM segment
  WHERE date(startDate) = '2024-06-15'
  ORDER BY startDate;
"

# Export transcripts to text
sqlite3 backup/rewind.sqlite3 "
  SELECT word FROM transcript_word
  ORDER BY segmentId, timeOffset;
" > all_transcripts.txt
```

## Database Schema

### Core Tables

| Table | Description |
|-------|-------------|
| `frame` | Screenshots with precise timestamps (`createdAt`) |
| `segment` | App focus windows: bundleID, windowName, browserUrl, startDate, endDate |
| `video` | Video file paths and metadata |
| `audio` | Audio recordings with startTime and duration |
| `transcript_word` | Speech-to-text with word-level timing |
| `node` | OCR text positions mapped to frames |
| `searchRanking` | FTS5 full-text search index of all OCR text |
| `doc_segment` | Links search results to frames and segments |

### Key Fields

```sql
-- frame: precise screenshot timing
CREATE TABLE frame (
  id INTEGER PRIMARY KEY,
  createdAt TEXT NOT NULL,           -- ISO 8601 with milliseconds
  imageFileName TEXT NOT NULL,
  segmentId INTEGER,
  videoId INTEGER,
  videoFrameIndex INTEGER
);

-- segment: what app/window was active
CREATE TABLE segment (
  id INTEGER PRIMARY KEY,
  bundleID TEXT,                      -- com.google.Chrome, etc.
  startDate TEXT NOT NULL,
  endDate TEXT NOT NULL,
  windowName TEXT,                    -- Window title
  browserUrl TEXT                     -- URL if browser
);

-- transcript_word: speech with timing
CREATE TABLE transcript_word (
  id INTEGER PRIMARY KEY,
  segmentId INTEGER NOT NULL,
  word TEXT NOT NULL,
  timeOffset INTEGER NOT NULL,        -- Milliseconds from segment start
  duration INTEGER NOT NULL,
  speechSource TEXT                   -- "me" or "others"
);
```

## Technical Details

### Original Encryption

- **Format**: SQLCipher 4
- **Cipher**: AES-256-CBC (per page)
- **KDF**: PBKDF2-HMAC-SHA512, 256,000 iterations
- **HMAC**: SHA-512 for integrity
- **Page size**: 4096 bytes

### Data Location

```
~/Library/Application Support/com.memoryvault.MemoryVault/
├── db-enc.sqlite3          # Encrypted database
├── chunks/                 # Video files
│   └── YYYYMM/DD/id        # H.264 MP4, ~5 min each, 0.5 fps
└── snippets/               # Audio files
    └── YYYY-MM-DDTHH:MM:SS/snippet.m4a
```

## Safety

This script **only reads** from your Rewind data. It never modifies or deletes originals:

- Database: read-only SQLCipher export
- Videos/audio: `cp` (copy), not `mv` (move)
- All writes go to `./backup/` only

## FAQ

**Q: Is this legal?**
A: You're accessing your own data on your own computer. Rewind stored it locally specifically for privacy. You have every right to export it.

**Q: Will this work after December 19?**
A: Yes. The data is stored locally. The script doesn't need Rewind servers.

**Q: How much space do I need?**
A: Roughly 2x your current Rewind data. Check `~/Library/Application Support/com.memoryvault.MemoryVault/` size first.

**Q: Can I just export the database without videos?**
A: Yes. Use `--skip-videos --skip-audio` for just the searchable database with all metadata.

**Q: The script is slow. Is that normal?**
A: Yes. SQLCipher uses 256,000 PBKDF2 iterations for key derivation. Larger databases take longer. Videos are the slowest part if you have many.

## See Also

- [Kevin Chen's Rewind Teardown](https://kevinchen.co/blog/rewind-ai-app-teardown/) — Technical analysis of Rewind's architecture
- [RewindMCP](https://github.com/pedramamini/RewindMCP) — Python library for querying Rewind's database
- [@m1guelpf's discovery](https://x.com/m1guelpf/status/1854959335161401492) — Original password finding

## License

[WTFPL](http://www.wtfpl.net/). Do what the fuck you want with your own data.
