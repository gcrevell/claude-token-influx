#!/usr/bin/env bash
#
# claude-tokens.sh -- emit per-project, per-model, per-day Claude Code token
# usage as InfluxDB line protocol on stdout.
#
#   claude-tokens.sh [projects_root] [src_root] [host_tag]
#
# This script WRITES NOTHING ANYWHERE. It reads transcripts and prints lines.
# Getting that output into a database -- piping it to `curl` against
# /api/v2/write, or running it from Telegraf's exec input -- is the caller's
# job, deliberately, so that no URL, token or hostname ever has to live in here.
#
# COUNTS ONLY. The transcripts this walks contain every prompt, file path, file
# content and tool result on the machine. Nothing but integers and the three tags
# (host, project, model) is ever written to stdout. Keep it that way: any future
# field carrying a string off a transcript record is a data leak into a database
# with no access control on the read side.
#
# The FULL history is re-emitted on every run -- no window, no cursor. A complete
# walk takes under two seconds, and there is then no catch-up path to get wrong.
# That leans on two properties of the target bucket, and BOTH have to hold:
#   - retention is 0 (infinite). InfluxDB drops points older than retention AT
#     WRITE TIME, so a finite retention would silently discard most of every run.
#   - writes are idempotent -- identical measurement + tag set + field +
#     timestamp overwrites rather than duplicating.

set -uo pipefail

# Arguments rather than hardcoded paths, because one copy of this script is
# meant to run on several machines whose layouts disagree. The defaults suit
# running it by hand on the machine you are sitting at.
projects_root="${1:-$HOME/.claude/projects}"
src_root="${2:-$HOME/src}"
# The host tag is NOT optional: without it two machines write identical keys and
# the idempotent-overwrite property above makes them clobber each other instead
# of summing. Callers pass an explicit stable name, because a Mac's hostname
# changes with the network it joins and would fragment the series.
host="${3:-$(hostname -s)}"

# A machine that has never run Claude Code, or has no jq, is "nothing to report".
command -v jq >/dev/null 2>&1 || exit 0
[ -d "$projects_root" ] || exit 0

# Not `| xargs cat`: with zero matches GNU xargs still runs `cat` once with no
# arguments, which blocks on stdin forever. BSD xargs does not, and this has to
# be correct on both.
#
# The walk is RECURSIVE: subagent transcripts sit two levels deeper, at
# <project>/<session>/subagents/agent-*.jsonl, and are over half the files.
find "$projects_root" -type f -name '*.jsonl' -exec cat {} + 2>/dev/null |

# Pass 1, streaming: reduce the corpus to one small object per billable turn.
# Splitting this from the aggregation below is what keeps memory flat.
jq -c --arg src "$src_root" '
  # One truncated transcript should not cost every other file its data.
  select(type == "object")
  | select(.type == "assistant")
  | select(.message.usage | type == "object")

  # <synthetic> is Claude Code fabricating a turn locally. It never hit the API.
  | (.message.model // "") as $model
  | select($model != "" and $model != "<synthetic>")

  # An unrecognised model is still emitted: rates live in Dashhund, and an
  # unpriced model showing up there is the point.

  | (.message.usage) as $u
  | (.cwd // "") as $cwd

  # Project tag, from the real cwd -- never from the transcript directory name,
  # whose /->- flattening is lossy and ambiguous. Worktrees and subdirectories
  # roll UP into the parent project rather than fragmenting.
  #
  # Settle this rule before the first write and leave it alone: InfluxDB will not
  # retro-update tags, so changing it orphans all existing history.
  | ($cwd | sub("/\\.claude/worktrees/[^/]+"; "")) as $p
  | (
      if $p == $src then ($p | split("/") | last)
      elif $p | startswith($src + "/") then ($p[($src | length) + 1:] | split("/")[0])
      else ($p | split("/") | last)
      end
    ) as $project
  | select($project != null and $project != "")

  # Turns are duplicated ACROSS transcripts -- resuming or branching a session
  # replays earlier turns into the new file -- so summing without deduping
  # roughly doubles every number, by a fraction that moves each time.
  | {
      k: ((.message.id // "") + "|" + (.requestId // "")),

      # UTC midnight, computed in jq: this same file runs on macOS, whose BSD
      # date has no -d.
      d: (.timestamp | sub("T.*"; "") + "T00:00:00Z"
                     | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime),
      p: $project,
      m: $model,

      i:  ($u.input_tokens // 0),
      o:  ($u.output_tokens // 0),
      cr: ($u.cache_read_input_tokens // 0),
      # Kept apart because 5m and 1h cache writes are priced differently. Their
      # sum is cache_creation_input_tokens, so no total field is stored.
      c5: ($u.cache_creation.ephemeral_5m_input_tokens // 0),
      c1: ($u.cache_creation.ephemeral_1h_input_tokens // 0),
      # A subset of output_tokens, not an addition to it.
      th: ($u.output_tokens_details.thinking_tokens // 0)
    }
  | select(.d != null)
' 2>/dev/null |

# Pass 2: dedupe, aggregate, format. Slurps only what pass 1 emitted.
jq -rs --arg host "$host" '
  def esc: tostring | gsub("\\\\"; "\\\\") | gsub(","; "\\,")
                    | gsub(" "; "\\ ") | gsub("="; "\\=");

  unique_by(.k)
  | group_by([.d, .p, .m])
  | map({
      d: .[0].d, p: .[0].p, m: .[0].m,
      i:  (map(.i)  | add), o:  (map(.o)  | add),
      cr: (map(.cr) | add), c5: (map(.c5) | add),
      c1: (map(.c1) | add), th: (map(.th) | add),
      turns: length
    })
  | .[]
  # Nanoseconds, and backdated to the day itself -- stamping at collection time
  # would pile every day of history onto today on every run.
  | "claude_tokens,host=\($host|esc),project=\(.p|esc),model=\(.m|esc) " +
    "input=\(.i)i,output=\(.o)i,cache_read=\(.cr)i," +
    "cache_write_5m=\(.c5)i,cache_write_1h=\(.c1)i," +
    "thinking=\(.th)i,turns=\(.turns)i " +
    "\(.d)000000000"
' 2>/dev/null
