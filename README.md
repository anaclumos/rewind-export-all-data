# Dan Siroker, if you're reading this: bro. cmon.

So I spent my Jan 1st of 2026 doing what the team should have done in like 2 hours.

## tl;dr

You use Claude Code?

```
Ultrathink and Clone https://github.com/anaclumos/rewind-export-all-data, read through the script, and run it to export my Rewind data. Do not modify or delete any original Rewind files.
```

## Ok so what happened

[Rewind.ai](https://rewind.ai) was this Mac app that recorded everything on your screen 24/7. Years of your life, stored locally. Then Meta bought them and announced they're killing the app on December 19, 2025. Cool cool cool. Here's the fun part...

THEY GAVE US NO WAY TO EXPORT OUR DATA

Like... what? Years of recordings, transcripts, memories, all of it sitting behind encrypted SQLite and they just said "lol good luck." I cannot stress enough how insane this is.

## Questions you're gonna ask

### Is this legal??

It's YOUR data on YOUR computer. Rewind stored it locally for privacy reasons. Yes you can export your own stuff.

### Works after Dec 19?

Yep. It's all local.

### How much disk space?

~2x your current Rewind folder. Check `~/Library/Application Support/com.memoryvault.MemoryVault/` first.

### Can I skip the videos?

Ya. `--skip-videos --skip-audio` if you just want the searchable database.

### Why is it so slow??

256,000 PBKDF2 iterations. Blame the encryption. Videos take forever if you have a lot.

## What this thing does

* Opens that encrypted database (SQLCipher to plain SQLite)
* Grabs all your videos with actual timestamps from the db
* Grabs audio too
* Keeps all the metadata (what app, what window, URLs, etc.)
* Spits out a manifest so you can see wtf you even have

## Shoutout

[@m1guelpf](https://x.com/m1guelpf/status/1854959335161401492) figured out the database password.

Turns out it's hardcoded and **the same for literally everyone**. Incredible security guys. But hey it works in our favor now so I'm not complaining.

## Before you start

You need this:

```bash
brew install sqlcipher
```

Optional but makes the JSON output pretty:

```bash
brew install jq
```

## How to use it

```bash
git clone https://github.com/anaclumos/rewind-export-all-data.git
cd rewind-export-all-data
chmod +x basic-human-decency.sh
./basic-human-decency.sh
```

## Will this break my stuff?

No. Reads only. Copies only. Never touches originals.

* Database: readonly export
* Videos/audio: `cp` not `mv`
* Everything goes into `./backup/`

## Related stuff

* [Kevin Chen's teardown](https://kevinchen.co/blog/rewind-ai-app-teardown/) ... how Rewind actually works under the hood
* [RewindMCP](https://github.com/pedramamini/RewindMCP) ... Python library for querying the db
* [@m1guelpf's tweet](https://x.com/m1guelpf/status/1854959335161401492) ... the hero who found the password

## License

[WTFPL](http://www.wtfpl.net/). It's your data. Do whatever.
