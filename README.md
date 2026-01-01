# dan siroker, if you're reading this: bro. cmon.

so i spent my jan 1st of 2026 doing what the team should have done in like 2 hours

## tl;dr

you use claude code?

```
Ultrathink and Clone https://github.com/anaclumos/rewind-export-all-data, read through the script, and run it to export my Rewind data. Do not modify or delete any original Rewind files.
```

## ok so what happened

[Rewind.ai](https://rewind.ai) was this mac app that recorded everything on your screen 24/7. years of your life, stored locally.

then Meta bought them (theyre called Limitless now i guess??) and announced theyre killing the app on **December 19, 2025**.

cool cool cool. heres the fun part

**THEY GAVE US NO WAY TO EXPORT OUR DATA**

like... what?? years of recordings, transcripts, memories, all of it sitting behind encrypted sqlite and they just said "lol good luck". i cannot stress enough how insane this is

## what this thing does

* open that encrypted database (sqlcipher to plain sqlite)
* grabs all your videos with actual timestamps from the db
* grabs audio too
* keeps all the metadata (what app, what window, URLs, etc)
* spits out a manifest so you can see wtf you even have

## shoutout

[@m1guelpf](https://x.com/m1guelpf/status/1854959335161401492) figured out the database password

turns out its hardcoded and **the same for literally everyone**. incredible security guys. but hey it works in our favor now so im not complaining

## before you start

you need this

```bash
brew install sqlcipher
```

optional but makes the json output pretty

```bash
brew install jq
```

## how to use it

```bash
git clone https://github.com/anaclumos/rewind-export-all-data.git
cd rewind-export-all-data
chmod +x basic-human-decency.sh
./basic-human-decency.sh
```

### flags n stuff

```
--backup-dir PATH   where to dump everything (default: ./backup)
--skip-videos       dont copy videos, just the database
--skip-audio        skip audio files
--verbose, -v       if you wanna watch it work
--help, -h          u know what this does
```

## what you get

```
./backup/
├── rewind.sqlite3              # the good stuff, NO PASSWORD anymore
├── videos/
│   └── YYYY-MM-DD/
│       └── HHMMSS.mmm_app_window.mp4
├── audio/
│   └── YYYY-MM-DD/
│       └── HHMMSS.mmm_duration.m4a
└── manifest.json               # index of everything
```

## now you can actually query your own data

your stuff is plain sqlite now. go nuts with claude

```bash
# see what tables exist
sqlite3 backup/rewind.sqlite3 '.tables'

# what apps did you use the most (prepare to be judged)
sqlite3 backup/rewind.sqlite3 '
  SELECT bundleID, COUNT(*) as segments
  FROM segment
  GROUP BY bundleID
  ORDER BY segments DESC
  LIMIT 10;
'

# search for... uh... passwords you may have had on screen
sqlite3 backup/rewind.sqlite3 "
  SELECT text FROM searchRanking
  WHERE text MATCH 'password'
  LIMIT 10;
"

# what were you doing on a specific day
sqlite3 backup/rewind.sqlite3 "
  SELECT datetime(startDate), bundleID, windowName
  FROM segment
  WHERE date(startDate) = '2024-06-15'
  ORDER BY startDate;
"

# dump all your transcripts
sqlite3 backup/rewind.sqlite3 "
  SELECT word FROM transcript_word
  ORDER BY segmentId, timeOffset;
" > all_transcripts.txt
```

## database nerd stuff

### tables

| Table | whats in it |
|-------|-------------|
| `frame` | screenshots with timestamps |
| `segment` | app focus stuff: bundle id, window name, url, times |
| `video` | video file paths |
| `audio` | audio recordings |
| `transcript_word` | speech to text, word by word |
| `node` | OCR positions on screenshots |
| `searchRanking` | full text search index (this is the good shit) |
| `doc_segment` | links search results to frames |

### schema if you care

```sql
CREATE TABLE frame (
  id INTEGER PRIMARY KEY,
  createdAt TEXT NOT NULL,           /* timestamp */
  imageFileName TEXT NOT NULL,
  segmentId INTEGER,
  videoId INTEGER,
  videoFrameIndex INTEGER
);

CREATE TABLE segment (
  id INTEGER PRIMARY KEY,
  bundleID TEXT,                      /* like com.google.Chrome */
  startDate TEXT NOT NULL,
  endDate TEXT NOT NULL,
  windowName TEXT,
  browserUrl TEXT
);

CREATE TABLE transcript_word (
  id INTEGER PRIMARY KEY,
  segmentId INTEGER NOT NULL,
  word TEXT NOT NULL,
  timeOffset INTEGER NOT NULL,        /* ms from segment start */
  duration INTEGER NOT NULL,
  speechSource TEXT                   /* "me" or "others" */
);
```

## for the security folks

the original encryption:
* SQLCipher 4
* AES256CBC
* PBKDF2 HMAC SHA512 with 256k iterations
* SHA512 HMAC
* 4096 byte pages

### where your data lives

```
~/Library/Application Support/com.memoryvault.MemoryVault/
├── db_enc.sqlite3          # encrypted db
├── chunks/                 # videos
│   └── YYYYMM/DD/id        # h264, ~5 min each
└── snippets/               # audio
    └── timestamp_folder/snippet.m4a
```

## will this break my stuff?

no. reads only. copies only. never touches originals.

* database: readonly export
* videos/audio: `cp` not `mv`
* everything goes into `./backup/`

## questions youre gonna ask

### is this legal??

its YOUR data on YOUR computer. rewind stored it locally for privacy reasons. yes you can export your own stuff.

### works after dec 19?

yep. its all local.

### how much disk space?

~2x your current rewind folder. check `~/Library/Application Support/com.memoryvault.MemoryVault/` first

### can i skip the videos?

ya. `--skip-videos --skip-audio` if you just want the searchable database

### why is it so slow??

256,000 PBKDF2 iterations. blame the encryption. videos take forever if you have a lot.

## related stuff

* [Kevin Chen's teardown](https://kevinchen.co/blog/rewind-ai-app-teardown/) ... how rewind actually works under the hood
* [RewindMCP](https://github.com/pedramamini/RewindMCP) ... python library for querying the db
* [@m1guelpf's tweet](https://x.com/m1guelpf/status/1854959335161401492) ... the hero who found the password

## license

[WTFPL](http://www.wtfpl.net/). its your data. do whatever.
