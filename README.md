# claude-token-influx

Emit Claude Code token usage as InfluxDB line protocol.

`claude-tokens.sh` walks the transcripts Claude Code leaves under
`~/.claude/projects`, dedupes turns, and prints one line per
**project × model × day** on stdout. It writes nothing anywhere — pointing the
output at a database is the caller's job.

```
claude_tokens,host=laptop,project=dotfiles,model=claude-opus-5 input=1234i,output=567i,cache_read=89012i,cache_write_5m=3456i,cache_write_1h=0i,thinking=234i,turns=12i 1756512000000000000
```

## Usage

```bash
claude-tokens.sh [projects_root] [src_root] [host_tag]
```

| Argument | Default | Meaning |
|---|---|---|
| `projects_root` | `$HOME/.claude/projects` | Where Claude Code keeps transcripts |
| `src_root` | `$HOME/src` | Parent dir of your checkouts, used to derive the `project` tag |
| `host_tag` | `hostname -s` | Value of the `host` tag |

Requires `bash`, `jq` and `find`. Works on macOS and Linux.

**Pass `host_tag` explicitly on anything portable.** A laptop's short hostname
changes with the network it joins, and since writes are idempotent on the tag
set, a drifting `host` tag fragments the series rather than merging it.

### Shipping it somewhere

Pipe it into the InfluxDB v2 write API:

```bash
claude-tokens.sh "$HOME/.claude/projects" "$HOME/src" laptop |
  curl -sS --fail-with-body \
    --connect-timeout 5 --max-time 60 \
    -H "Authorization: Token $INFLUX_TOKEN" \
    -H 'Content-Type: text/plain; charset=utf-8' \
    --data-binary @- \
    "$INFLUX_URL/api/v2/write?org=$INFLUX_ORG&bucket=$INFLUX_BUCKET&precision=ns"
```

Use `--fail-with-body` (or `-f`): plain `curl` **exits 0 on a 401**, so without
it a job with a revoked token reports success on every run while writing
nothing.

Or run it from Telegraf's `exec` input with `data_format = "influx"`.

## What it does and does not send

**Counts only.** The transcripts this reads contain every prompt, file path,
file content and tool result on the machine. What leaves the process is seven
integers and three tags — `host`, `project`, `model`. No prompt text, no paths,
no tool output. That is a deliberate property worth preserving: the obvious
"just add the session id" style change leaks transcript-derived strings into a
database that usually has no access control on the read side.

## Design notes

The interesting decisions are commented in the script itself; the two that
affect how you deploy it:

- **Full history on every run, no cursor and no state file.** A machine that was
  offline for a week is not "behind" — the next run sends the same complete
  history it would have sent anyway, so there is no catch-up path to get wrong.
  This requires the target bucket to have **infinite retention** (InfluxDB drops
  points older than retention *at write time*, so a finite retention silently
  discards most of every run) and to treat identical tag-set + timestamp writes
  as overwrites, which InfluxDB does.

- **Every run reads the whole corpus.** A few hundred megabytes of JSONL and a
  couple of seconds of CPU, growing linearly with your usage. That argues for an
  interval measured in hours rather than minutes, and for `nice`-ing it.

Also worth knowing: Claude Code deletes transcripts older than
`cleanupPeriodDays` (default 30). Any window that ages off disk before a
successful run is never captured, so a machine left off for over a month loses
whatever fell outside that window.

Empty output is a valid result — it's what a machine that has never run Claude
Code produces, and what you get with no `jq` installed or no projects directory.
Callers that expect data should decide for themselves whether zero lines is
success or an alarm.
