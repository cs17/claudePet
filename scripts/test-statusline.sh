#!/usr/bin/env bash
# test-statusline.sh — smoke tests for the status line.
#
# The bash side has no jest coverage, and the two bugs worth remembering both
# lived here, so these assertions are deliberately about behaviour the status
# line must keep: the metrics bar always prints, and a broken or missing pet
# data file must not take it down with it.
#
# Run: bash scripts/test-statusline.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so the suite can be pointed at another build of the script
SL="${PET_STATUSLINE:-$ROOT/scripts/pet-statusline.sh}"
DATA="$ROOT/src/data"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PET_DIR="$TMP/.claude/claude-pet"
mkdir -p "$PET_DIR"
cp "$DATA/sprites.json" "$DATA/creatures.json" "$PET_DIR/"

STATE_GOOD='{"currentLineId":"invader","currentStageIndex":2,"xp":450,"totalPromptsScored":9,"streakDays":3,"lastActiveDate":"2026-10-11","milestonesCompleted":[],"evolutionHistory":[]}'
STATE_BAD='{"currentLineId":"no-such-family","currentStageIndex":0,"xp":10,"totalPromptsScored":1,"streakDays":1,"lastActiveDate":"2026-10-11","milestonesCompleted":[],"evolutionHistory":[]}'
PAYLOAD='{"model":{"display_name":"Sonnet","id":"claude-sonnet-5-5"},"session_id":"s1","workspace":{"current_dir":"/home/ada/projects/claudePet"},"context_window":{"used_percentage":21.7,"context_window_size":200000,"total_input_tokens":42100,"total_output_tokens":1234,"current_usage":{"input_tokens":120,"cache_creation_input_tokens":800,"cache_read_input_tokens":41180,"output_tokens":1234}},"cost":{"total_cost_usd":0.01234,"total_duration_ms":192000,"total_lines_added":12,"total_lines_removed":3}}'

# render [state-json|""] [config-json|""]
render() {
  rm -f "$PET_DIR/state.json" "$PET_DIR/config.json"
  [[ -n "${1:-}" ]] && printf '%s' "$1" > "$PET_DIR/state.json"
  [[ -n "${2:-}" ]] && printf '%s' "$2" > "$PET_DIR/config.json"
  HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=0 \
    bash "$SL" <<< "$PAYLOAD" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { # label, haystack, needle
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "expected to contain: $3"; fi
}
nocheck() { # label, haystack, needle
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "expected NOT to contain: $3"; fi
}

echo "── status line smoke tests ──"

# ── interpreter and env, resolved once for the whole suite ────────────────────
# Two traps, both of which made this suite fail for reasons that had nothing to
# do with what it asserts.
#
# python3 is not necessarily python. On Windows the Microsoft Store ships a
# python3.exe that is not an interpreter: it prints "Python was not found" and
# exits non-zero, so every test that shelled out to python3 reported a failure
# of the thing under test. The status line itself already probes for a real
# interpreter — reuse that answer instead of assuming a name.
PET_PY_TEST=""
for c in python3 python; do
  if "$c" -c 'import sys;sys.stdout.write("PETPY")' 2>/dev/null | grep -q PETPY; then
    PET_PY_TEST="$c"; break
  fi
done
py() { "$PET_PY_TEST" "$@"; }
[[ -n "$PET_PY_TEST" ]] || { echo "  FAIL no working python interpreter found" >&2; exit 1; }

# COLUMNS must start unset. The status line now fits the bar to the terminal, so
# a value inherited from the shell running the tests would wrap assertions that
# expect one line — and whether it leaks depends on how the suite was launched,
# which is the kind of thing that makes a test pass on one machine only. The
# fitting cases below set it explicitly.
unset COLUMNS

# `env` is not necessarily env either. ~/.local/bin/env can be a PATH-fixing
# shim (uv installs one) whose whole body is an `export PATH=...`: it ignores
# its arguments, runs nothing, and exits 0. So `env X=1 bash …` silently ran no
# render at all, and every "must NOT contain" assertion passed for the wrong
# reason while every "must contain" one failed. Assigning inside a subshell
# keeps the override and needs no external binary.
with_env() { # $1 = "VAR=VALUE ..." (may be empty), rest = command
  local assigns="$1"; shift
  ( for kv in $assigns; do export "$kv"; done; "$@" )
}

out="$(render "$STATE_GOOD" '{"display":true}')"
check "renders the model name"        "$out" "⬡ Sonnet"
check "renders the context bar"       "$out" "[##--------] 21%"
check "renders token counters"        "$out" "42.1k/200.0k"
check "renders the cache hit rate"    "$out" "cache 97%"
check "renders duration and lines"    "$out" "+12/-3"
check "renders the creature"          "$out" "Pet: ◆ Drone"
check "creature reports next level"   "$out" "♥ 450/1600 XP"

out="$(render "$STATE_GOOD" '{"display":false}')"
check "pet off keeps the metrics bar" "$out" "⬡ Sonnet"
nocheck "pet off hides the creature"  "$out" "Pet: ◆"

out="$(render "$STATE_GOOD" '')"
check "missing config defaults to on" "$out" "Pet: ◆"

out="$(render "" '{"display":true}')"
check "missing state.json keeps bar"  "$out" "⬡ Sonnet"

out="$(render "$STATE_BAD" '{"display":true}')"
check "unknown family keeps the bar"  "$out" "⬡ Sonnet"

# Malformed stdin must still leave a usable bar rather than nothing at all
out="$(HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=0 \
  bash "$SL" <<< 'not json' 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
check "malformed stdin falls back to defaults" "$out" "⬡ Claude"

# ── cost tiering ─────────────────────────────────────────────────────────────
# render() above sets PET_PRICING_COST=0, so none of those assertions touch the
# cost python at all. These do, with a pinned clock (PET_NOW_UTC) and a config
# carrying a DeepSeek peak/off-peak card.
CARD_CONFIG='{"display":true,"currency":{"code":"USD","usd_rate":1},"pricing":{
  "tier_mode":"auto","peak_days":[1,2,3,4,5],
  "peak_windows":[["01:00","04:00"],["06:00","10:00"]],
  "off_peak_dates":["2026-10-01"],
  "models":{
    "deepseek-flash":{"source":"deepseek-builtin",
      "off_peak":{"input_per_mtok":0.15,"output_per_mtok":0.60,"cache_read_per_mtok":0.003},
      "peak":{"input_per_mtok":0.30,"output_per_mtok":1.20,"cache_read_per_mtok":0.006}},
    "glm-flat":{"input_per_mtok":0.1,"output_per_mtok":0.5,"cache_read_per_mtok":0.03}}}}'

cost_payload() { # $1 = model id
  printf '{"model":{"display_name":"%s","id":"%s"},"session_id":"t",' "$1" "$1"
  printf '"workspace":{"current_dir":"/tmp/pet"},"context_window":{"used_percentage":10,'
  printf '"context_window_size":200000,"current_usage":{"input_tokens":1000,'
  printf '"cache_creation_input_tokens":0,"cache_read_input_tokens":100000,"output_tokens":2000}},'
  printf '"cost":{"total_cost_usd":18.088}}'
}

cost_render() { # $1=config json  $2=model  $3=PET_NOW_UTC  $4=extra env
  printf '%s' "$1" > "$PET_DIR/config.json"
  rm -f "$PET_DIR/cost-state.json"     # each case starts a fresh accumulator
  # with_env, not a bare ${4:-}: bash only treats assignment words written
  # literally in the source as assignments, so an expanded one becomes the
  # command name and the render fails — which a "must NOT contain" assertion
  # cannot see. And not `env` either: see with_env's note.
  HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=1 \
    PET_NOW_UTC="$3" with_env "${4:-}" \
    bash "$SL" <<< "$(cost_payload "${2:-deepseek-flash}")" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g'
}
cost_of() { grep -o '\$[0-9.]*' <<< "$1" | head -1; }

MON_PEAK=2026-10-12T02:00:00Z     # Monday, inside a peak window
MON_GAP=2026-10-12T05:00:00Z      # Monday, between the two windows
SUNDAY=2026-10-11T02:00:00Z       # weekend: off-peak all day
HOLIDAY=2026-10-01T02:00:00Z      # National Day, a Thursday

out_peak="$(cost_render "$CARD_CONFIG" deepseek-flash "$MON_PEAK")"
out_off="$(cost_render "$CARD_CONFIG" deepseek-flash "$MON_GAP")"
check "peak window is labelled 峰"      "$out_peak" "峰"
check "between windows is labelled 谷"  "$out_off" "谷"
check "weekend is off-peak"             "$(cost_render "$CARD_CONFIG" deepseek-flash "$SUNDAY")" "谷"
check "holiday is off-peak"             "$(cost_render "$CARD_CONFIG" deepseek-flash "$HOLIDAY")" "谷"

# Same request priced on both tariffs: the peak total must be exactly double
py - "$(cost_of "$out_off")" "$(cost_of "$out_peak")" <<'PY'
import sys
off, pk = (float(x.lstrip("$")) for x in sys.argv[1:3])
raise SystemExit(0 if abs(pk - 2 * off) < 0.0002 else 1)
PY
if (( $? == 0 )); then ok "peak total is exactly 2x the off-peak total"
else bad "peak total is exactly 2x the off-peak total" "off=$out_off peak=$out_peak"; fi

# A flat catalogue price has no tier to report
out_flat="$(cost_render "$CARD_CONFIG" glm-flat "$MON_PEAK")"
nocheck "flat model shows no tier"      "$out_flat" "峰"
nocheck "flat model shows no tier"      "$out_flat" "谷"
check "flat model still shows a cost"   "$out_flat" "\$"

forced="$(jq -c '.pricing.tier_mode = "off_peak"' <<< "$CARD_CONFIG")"
nocheck "tier_mode pins off-peak at peak hours" \
  "$(cost_render "$forced" deepseek-flash "$MON_PEAK")" "峰"

hidden="$(jq -c '.currency.show_tier = false' <<< "$CARD_CONFIG")"
nocheck "currency.show_tier=false hides the label" \
  "$(cost_render "$hidden" deepseek-flash "$MON_PEAK")" "峰"

noenv="$(cost_render "$CARD_CONFIG" deepseek-flash "$MON_PEAK" PET_COST_TIER_LABEL=0)"
nocheck "PET_COST_TIER_LABEL=0 hides the label" "$noenv" "峰"

# No pricing block at all (what install.sh seeds on a fresh install)
out_bare="$(cost_render '{"display":true}' deepseek-flash "$MON_PEAK")"
check "config without pricing still renders" "$out_bare" "⬡"

# ── context window ───────────────────────────────────────────────────────────
# Claude Code reports 200000 for models it does not recognise as extended-
# context, which understates a gateway model, so the model card's limit wins.
CTX_CONFIG='{"display":true,"currency":{"code":"USD","usd_rate":1},"pricing":{"models":{
  "deepseek-flash":{"source":"deepseek-docs","context_tokens":1000000,
    "off_peak":{"input_per_mtok":0.15,"output_per_mtok":0.6,"cache_read_per_mtok":0.003},
    "peak":{"input_per_mtok":0.3,"output_per_mtok":1.2,"cache_read_per_mtok":0.006}}}}}'

ctx_payload() { # $1=context_window_size  $2=used_percentage
  printf '{"model":{"display_name":"deepseek-flash","id":"deepseek-flash"},"session_id":"t",'
  printf '"workspace":{"current_dir":"/tmp/pet"},"context_window":{"used_percentage":%s,' "$2"
  printf '"context_window_size":%s,"current_usage":{"input_tokens":1000,' "$1"
  printf '"cache_creation_input_tokens":0,"cache_read_input_tokens":499000,"output_tokens":10}},'
  printf '"cost":{"total_cost_usd":1}}'
}

ctx_render() { # $1=config  $2=payload window  $3=payload percentage
  printf '%s' "$1" > "$PET_DIR/config.json"
  rm -f "$PET_DIR/cost-state.json"
  HOME="$TMP" PET_INFO_WIDTH=0 PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=1 \
    PET_NOW_UTC=2026-10-12T05:00:00Z \
    bash "$SL" <<< "$(ctx_payload "$2" "$3")" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -o '\[.*% [0-9.]*[kM]*/[0-9.]*[kM]*'
}

check "model limit overrides Claude Code's 200k default" \
  "$(ctx_render "$CTX_CONFIG" 200000 250)" "[#####-----] 50% 500.0k/1.0M"
check "keeps a larger size when the payload knows better" \
  "$(ctx_render "$CTX_CONFIG" 2000000 25)" "[##--------] 25% 500.0k/2.0M"
check "explicit context_window_tokens wins" \
  "$(ctx_render '{"display":true,"context_window_tokens":500000}' 200000 250)" \
  "[##########] 100% 500.0k/500.0k"
check "without a price table the payload's size stands" \
  "$(ctx_render '{"display":true}' 200000 250)" "[##########] 250% 500.0k/200.0k"

# ── per-session cost accumulator ─────────────────────────────────────────────
# A single slot keyed by session id meant any id change — resuming, or a second
# session rendering — threw the running total away and looked like a reset.
FLAT1='{"display":true,"currency":{"code":"USD","usd_rate":1},"pricing":{"models":{
  "m":{"input_per_mtok":1,"output_per_mtok":2,"cache_read_per_mtok":0.1}}}}'

sess_render() { # $1=config $2=session id $3=input tokens → echoes that session's total
  printf '%s' "$1" > "$PET_DIR/config.json"
  {
    printf '{"model":{"display_name":"m","id":"m"},"session_id":"%s",' "$2"
    printf '"workspace":{"current_dir":"/tmp/pet"},"context_window":{"used_percentage":10,'
    printf '"context_window_size":200000,"current_usage":{"input_tokens":%s,' "$3"
    printf '"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}},'
    printf '"cost":{}}'
  } | HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=1 \
      bash "$SL" >/dev/null 2>&1
  jq -r --arg s "$2" '.sessions[$s].total_usd // "none"' "$PET_DIR/cost-state.json" 2>/dev/null
}

rm -f "$PET_DIR/cost-state.json"
check "session accumulates its first request" "$(sess_render "$FLAT1" A 1)" "0.000001"
sess_render "$FLAT1" A 2 >/dev/null
check "session keeps accumulating"            "$(sess_render "$FLAT1" A 3)" "0.000006"
sess_render "$FLAT1" B 9 >/dev/null
check "a second session gets its own total"   "$(jq -r '.sessions.B.total_usd' "$PET_DIR/cost-state.json")" "0.000009"
check "switching sessions does not wipe A"    "$(jq -r '.sessions.A.total_usd' "$PET_DIR/cost-state.json")" "0.000006"

printf '%s' '{"session_id":"OLD","total_usd":1.5,"last_fp":"1|0|0|0","model":"m"}' > "$PET_DIR/cost-state.json"
check "the old single-slot file migrates"     "$(sess_render "$FLAT1" OLD 2)" "1.500002"

py - "$PET_DIR/cost-state.json" <<'PY'
import json, sys
from pathlib import Path

Path(sys.argv[1]).write_text(json.dumps({"sessions": {
    f"s{i}": {"total_usd": 1, "last_fp": f"{i}|0|0|0",
              "updated_at": f"2026-01-{i + 1:02d}T00:00:00Z"}
    for i in range(20)}}), encoding="utf-8")
PY
sess_render "$FLAT1" NEW 1 >/dev/null
check "the session map is capped"             "$(jq '.sessions | length' "$PET_DIR/cost-state.json")" "20"

# ── output rate ──────────────────────────────────────────────────────────────
# tok/s = output tokens from the transcript / the API time those responses
# actually took, both taken from the same request→response pairs. The numerator
# cannot come from current_usage.output_tokens: that only describes the last
# response, so sampling it every 30s loses the ones in between — measured 4x low
# in a tool-calling turn. The denominator cannot come from the payload's
# total_api_duration_ms, which keeps counting time for history a compaction has
# dropped. Four traps get a case each: the rate must not fall over when the
# model has no price match (that path exits early), it must not be disabled
# along with the priced estimate, a response recorded twice must not be counted
# twice, and a transcript whose responses cannot be paired must not be rescanned
# from the top on every render.
RATE_CONFIG='{"display":true,"currency":{"code":"USD","usd_rate":1},"pricing":{"models":{
  "m":{"input_per_mtok":1,"output_per_mtok":2,"cache_read_per_mtok":0.1}}}}'

# Echoed payloads use cwd /tmp/pet, so Claude Code's project dir is -tmp-pet.
TRANSCRIPTS="$TMP/claude-config/projects/-tmp-pet"
mkdir -p "$TRANSCRIPTS"

add_response() { # $1=session $2=message id $3=output tokens [$4=timestamp]
  if [[ -n "${4:-}" ]]; then
    jq -cn --arg id "$2" --argjson out "$3" --arg ts "$4" \
      '{type:"assistant",timestamp:$ts,message:{id:$id,usage:{output_tokens:$out}}}' \
      >> "$TRANSCRIPTS/$1.jsonl"
  else
    jq -cn --arg id "$2" --argjson out "$3" \
      '{type:"assistant",message:{id:$id,usage:{output_tokens:$out}}}' \
      >> "$TRANSCRIPTS/$1.jsonl"
  fi
}

add_request() { # $1=session $2=request id $3=timestamp
  jq -cn --arg id "$2" --arg ts "$3" \
    '{type:"api-request",id:$id,timestamp:$ts}' >> "$TRANSCRIPTS/$1.jsonl"
}

add_pair() { # $1=session $2=request id $3=message id $4=out tokens $5=req ts $6=resp ts
  add_request "$1" "$2" "$5"
  jq -cn --arg id "$3" --argjson out "$4" --arg ts "$6" --arg ref "$2" \
    '{type:"assistant",requestRef:$ref,timestamp:$ts,
      message:{id:$id,usage:{output_tokens:$out}}}' >> "$TRANSCRIPTS/$1.jsonl"
}

rate_payload() { # $1=session $2=api ms
  printf '{"model":{"display_name":"m","id":"m"},"session_id":"%s",' "$1"
  printf '"workspace":{"current_dir":"/tmp/pet"},"context_window":{"used_percentage":10,'
  printf '"context_window_size":200000,"current_usage":{"input_tokens":0,'
  printf '"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}},'
  printf '"cost":{"total_cost_usd":1,"total_api_duration_ms":%s}}' "$2"
}

rate_run() { # $1=config $2=session $3=api ms $4=extra env
  printf '%s' "$1" > "$PET_DIR/config.json"
  # with_env, not a bare ${4:-}: bash only treats assignment words written
  # literally in the source as assignments, so an expanded one becomes the
  # command name. And not `env` either: see with_env's note.
  HOME="$TMP" CLAUDE_CONFIG_DIR="$TMP/claude-config" \
    PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=1 \
    with_env "${4:-}" \
    bash "$SL" <<< "$(rate_payload "$2" "$3")" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g'
}

rate_of() { grep -o '[0-9.]* tok/s' <<< "$1" | head -1; }

rm -f "$PET_DIR/cost-state.json" "$TRANSCRIPTS"/*.jsonl
nocheck "no rate before any API time is reported" "$(rate_run "$RATE_CONFIG" R 0)" "tok/s"
nocheck "no rate without a transcript"            "$(rate_run "$RATE_CONFIG" R 1000)" "tok/s"

add_pair R q1 r1 100 '2026-10-20T00:00:00Z' '2026-10-20T00:00:01Z'   # 100 tok / 1s
check "rate is output tokens per API second" \
  "$(rate_of "$(rate_run "$RATE_CONFIG" R 1000)")" "100.0 tok/s"

add_pair R q2 r2 200 '2026-10-20T00:00:02Z' '2026-10-20T00:00:04Z'   # +200 tok / 2s
check "a second response accumulates into the rate" \
  "$(rate_of "$(rate_run "$RATE_CONFIG" R 2000)")" "100.0 tok/s"

check "a repeated render does not inflate the rate" \
  "$(rate_of "$(rate_run "$RATE_CONFIG" R 2000)")" "100.0 tok/s"

# The same response recorded again (Claude Code does this for multi-block
# messages) must not be counted twice.
jq -cn --arg id "r2" --arg ts '2026-10-20T00:00:04Z' --arg ref "q2" \
  '{type:"assistant",requestRef:$ref,timestamp:$ts,
    message:{id:$id,usage:{output_tokens:200}}}' >> "$TRANSCRIPTS/R.jsonl"
check "a duplicated transcript record is counted once" \
  "$(rate_of "$(rate_run "$RATE_CONFIG" R 2000)")" "100.0 tok/s"

# The same message id is also written *first* as a thinking-only placeholder
# whose usage is still zeroed, before the completed record appears. That
# placeholder must not consume the id: doing so dropped every real record and
# undercounted the numerator 15-25x on a live machine, which showed up as a
# plausible-looking but far too slow rate. 300 tok over 3s = 100 tok/s.
jq -cn '{type:"api-request",id:"q3",timestamp:"2026-10-20T00:00:05Z"}' \
  >> "$TRANSCRIPTS/R.jsonl"
jq -cn '{type:"assistant",requestRef:"q3",timestamp:"2026-10-20T00:00:05.5Z",
  message:{id:"r3",usage:{output_tokens:0}}}' >> "$TRANSCRIPTS/R.jsonl"
jq -cn '{type:"assistant",requestRef:"q3",timestamp:"2026-10-20T00:00:08Z",
  message:{id:"r3",usage:{output_tokens:300}}}' >> "$TRANSCRIPTS/R.jsonl"
check "a zero-token placeholder does not hide its completed record" \
  "$(rate_of "$(rate_run "$RATE_CONFIG" R 2000)")" "100.0 tok/s"
check "and the placeholder's id was not counted as the response" \
  "$(jq -r '.sessions.R.paired_tokens' "$PET_DIR/cost-state.json")" "600"

add_pair R3 q1 r1 100 '2026-10-20T00:00:00Z' '2026-10-20T00:00:01Z'
check "rate survives a model with no price card" \
  "$(rate_of "$(rate_run '{"display":true}' R3 1000)")" "100.0 tok/s"

add_pair R4 q1 r1 100 '2026-10-20T00:00:00Z' '2026-10-20T00:00:01Z'
check "rate survives PET_PRICING_COST=0" \
  "$(rate_of "$(rate_run "$RATE_CONFIG" R4 1000 PET_PRICING_COST=0)")" "100.0 tok/s"

# The priced estimate must stay off when the user turned it off, even though the
# block now also runs for the rate's sake.
check "PET_PRICING_COST=0 still keeps Claude's cost" \
  "$(rate_run "$RATE_CONFIG" R4 1000 PET_PRICING_COST=0 | grep -o '\$[0-9.]*' | head -1)" '$1.0000'

nocheck "PET_OUTPUT_RATE=0 hides the rate" \
  "$(rate_run "$RATE_CONFIG" R 2000 PET_OUTPUT_RATE=0)" "tok/s"

# A state file written by an older version carries counts in a shape this one
# cannot continue from, so it is rescanned from scratch rather than added to.
add_pair RM q1 r1 100 '2026-10-20T00:00:00Z' '2026-10-20T00:00:01Z'
printf '%s' '{"sessions":{"RM":{"out_tokens_total":5000,"paired_tokens":9000,
  "transcript_offset":99999,"rate_v":2,"counted_ids":["r1"]}}}' \
  > "$PET_DIR/cost-state.json"
check "an older state shape is rescanned, not continued" \
  "$(rate_of "$(rate_run "$RATE_CONFIG" RM 1000)")" "100.0 tok/s"
check "and the rescan drops the stale dedupe set" \
  "$(jq -r '.sessions.RM.paired_tokens' "$PET_DIR/cost-state.json")" "100"

nocheck "rate is a hideable segment" \
  "$(rate_run "$(jq -c '.info = {hide: ["rate"]}' <<< "$RATE_CONFIG")" R 2000)" "tok/s"

# A response is only counted when the api-request record that produced it has
# been seen, because the wait is the difference between the two timestamps. The
# pair can land in different reads, so an unmatched request id has to survive in
# the state until its response arrives.
# The measured wait is the request→response difference, not the gap between
# responses: 100 tokens produced over a 2s wait plus 300 over a 4s wait is
# 400/6s, even though the responses sit 10s apart on the clock.
add_pair RP p1 m1 100 '2026-10-20T00:00:00Z' '2026-10-20T00:00:02Z'
add_pair RP p2 m2 300 '2026-10-20T00:00:10Z' '2026-10-20T00:00:14Z'
check "rate divides tokens by the request→response wait" \
  "$(rate_of "$(rate_run "$RATE_CONFIG" RP 999999)")" "66.7 tok/s"

# A response whose request record was dropped (what compaction does to the
# history it discards) is skipped rather than counted with a guessed wait.
jq -cn '{type:"assistant",requestRef:"gone",timestamp:"2026-10-20T00:01:00Z",
  message:{id:"orphan",usage:{output_tokens:9999}}}' >> "$TRANSCRIPTS/RP.jsonl"
check "a response with no matching request is skipped" \
  "$(rate_of "$(rate_run "$RATE_CONFIG" RP 999999)")" "66.7 tok/s"

# The payload's own API total must not enter the figure at all: it carries time
# for history a compaction has already dropped, which is what made a live
# session read 26 tok/s against a real ~180.
check "the payload's API total is ignored" \
  "$(rate_of "$(rate_run "$RATE_CONFIG" RP 999999)")" "66.7 tok/s"

# requestRef arrived in Claude Code 2.1.301. A transcript recorded before that
# has responses but no api-request records, so nothing can be paired — the
# segment must go quiet rather than fall back to a guess. The payload here
# carries a plausible-looking API total, which is exactly the trap.
add_response ROLD o1 5000 '2026-10-20T00:00:00Z'
add_response ROLD o2 5000 '2026-10-20T00:00:01Z'
nocheck "a pre-2.1.301 transcript shows no rate at all" \
  "$(rate_run "$RATE_CONFIG" ROLD 2000)" "tok/s"
check "and it does not invent one from the payload" \
  "$(jq -r '.sessions.ROLD.paired_tokens // 0' "$PET_DIR/cost-state.json")" "0"
# Nothing pairs in that transcript, so a guard keyed on paired tokens would
# never persist the offset and every render would rescan the whole file from the
# top for the rest of the session — the cost of this feature growing with the
# session, in the case that produces no rate to show for it.
check "and its offset is persisted anyway" \
  "$(jq -r '.sessions.ROLD.transcript_offset | floor' "$PET_DIR/cost-state.json")" \
  "$(wc -c < "$TRANSCRIPTS/ROLD.jsonl" | tr -d ' ')"
# ...and persisted once, not on every render: the offset not moving means the
# scan consumed nothing, which is the case worth skipping the write for.
ROLD_MTIME="$(stat -c %Y "$PET_DIR/cost-state.json" 2>/dev/null || stat -f %m "$PET_DIR/cost-state.json")"
sleep 1
rate_run "$RATE_CONFIG" ROLD 2000 >/dev/null
check "a render with nothing new does not rewrite the state" \
  "$(stat -c %Y "$PET_DIR/cost-state.json" 2>/dev/null || stat -f %m "$PET_DIR/cost-state.json")" \
  "$ROLD_MTIME"

# Claude Code's append can be caught mid-write: a usage record averages 3-4 KB
# and peaks past 50 KB, so the tail of the file is often a fragment. The offset
# has to stop at the last complete line — advancing past a fragment means the
# next read starts after a record that is still arriving, and that response is
# lost for good rather than merely late.
add_pair RF q1 r1 100 '2026-10-20T00:00:00Z' '2026-10-20T00:00:01Z'
check "the pair before a fragment reads normally" \
  "$(rate_of "$(rate_run "$RATE_CONFIG" RF 1000)")" "100.0 tok/s"

add_request RF q2 '2026-10-20T00:00:02Z'
WHOLE="$TMP/whole-record.jsonl"
jq -cn --arg id "r2" --argjson out 300 --arg ts '2026-10-20T00:00:04Z' --arg ref "q2" \
  '{type:"assistant",requestRef:$ref,timestamp:$ts,
    message:{id:$id,usage:{output_tokens:$out}}}' > "$WHOLE"
UPTO="$(wc -c < "$TRANSCRIPTS/RF.jsonl" | tr -d ' ')"
head -c 30 "$WHOLE" >> "$TRANSCRIPTS/RF.jsonl"     # the writer is still going
check "a half-written last line is not counted" \
  "$(rate_of "$(rate_run "$RATE_CONFIG" RF 2000)")" "100.0 tok/s"
check "and the offset stops at the last complete line" \
  "$(jq -r '.sessions.RF.transcript_offset | floor' "$PET_DIR/cost-state.json")" "$UPTO"

tail -c +31 "$WHOLE" >> "$TRANSCRIPTS/RF.jsonl"    # the writer finishes it
check "the response is counted once its line is complete" \
  "$(rate_of "$(rate_run "$RATE_CONFIG" RF 2000)")" "133.3 tok/s"

# ── effort ───────────────────────────────────────────────────────────────────
# effort.level in the payload is the level Claude Code resolved for the current
# turn, after any silent downgrade — "max" on a model that cannot take it
# arrives as "high". The key is absent (not empty) on a model without effort
# support, so the segment has to vanish rather than render a blank box; the
# transcript's assistant.effort is the fallback, one response behind. Both the
# payload and the fallback are checked, plus the precedence between them.
effort_render() { # $1 = config json, $2 = extra payload members (may be "")
  printf '%s' "$1" > "$PET_DIR/config.json"
  jq -cn --arg extra "${2:-}" '{model:{display_name:"m",id:"m"}, session_id:"EFF",
    workspace:{current_dir:"/tmp/pet"},
    context_window:{used_percentage:5,context_window_size:200000,
      current_usage:{input_tokens:1,cache_creation_input_tokens:0,
                     cache_read_input_tokens:1,output_tokens:1}},
    cost:{total_cost_usd:0.01}} + ($extra | if . == "" then {} else fromjson end)' \
  | HOME="$TMP" CLAUDE_CONFIG_DIR="$TMP/claude-config" \
    PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=1 \
    bash "$SL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}
effort_seg() { sed -n 's/.*⬡ m │ \([^│]*\) │.*/\1/p' <<< "$1" | sed 's/ *$//'; }

EFFORT_CONFIG='{"display":true}'
for lvl in low medium high xhigh max; do
  check "effort $lvl comes from the payload" \
    "$(effort_seg "$(effort_render "$EFFORT_CONFIG" "{\"effort\":{\"level\":\"$lvl\"}}")")" "$lvl"
done

# Same model, no effort key: the segment is gone, and what follows closed up —
# no empty cell between the model and the directory.
out="$(effort_render "$EFFORT_CONFIG")"
check "no effort key leaves the model next to the directory" \
  "$(sed -n 's/.*⬡ m │ \([^│]*\) │.*/\1/p' <<< "$out" | sed 's/ *$//')" "/tmp/pet"

# The fallback reads the assistant record, and it must not need a paired
# response: an effort is stated by the record whether or not its api-request
# survived a compaction, and a change should show up even when the rate cannot.
rm -f "$PET_DIR/cost-state.json" "$TRANSCRIPTS"/EFF*.jsonl
jq -cn '{type:"assistant",timestamp:"2026-10-20T00:00:01Z",effort:"medium",
  message:{id:"e1",usage:{output_tokens:50}}}' >> "$TRANSCRIPTS/EFF.jsonl"
check "effort falls back to the transcript" \
  "$(effort_seg "$(effort_render "$EFFORT_CONFIG")")" "medium"

jq -cn '{type:"assistant",timestamp:"2026-10-20T00:00:02Z",effort:"max",
  message:{id:"e2",usage:{output_tokens:50}}}' >> "$TRANSCRIPTS/EFF.jsonl"
check "the newest assistant record wins" \
  "$(effort_seg "$(effort_render "$EFFORT_CONFIG")")" "max"

# The payload describes the turn in progress; the transcript only catches up
# when that response lands. So the payload has to win, or switching effort would
# show the old level until the first response came back.
check "the payload outranks the transcript fallback" \
  "$(effort_seg "$(effort_render "$EFFORT_CONFIG" '{"effort":{"level":"low"}}')")" "low"

# A state entry written before this feature has no last_effort, and the scan
# resumes from a persisted offset — so the fallback would find nothing in the
# bytes it reads. Asserting the payload path here keeps that from looking like a
# fresh-scan requirement.
printf '%s' '{"sessions":{"EFF":{"paired_tokens":0,"paired_api_ms":0,
  "transcript_offset":0,"rate_v":4,"counted_ids":[]}}}' > "$PET_DIR/cost-state.json"
check "a state entry without last_effort still shows the payload's level" \
  "$(effort_seg "$(effort_render "$EFFORT_CONFIG" '{"effort":{"level":"high"}}')")" "high"

nocheck "effort is a hideable segment" \
  "$(effort_render '{"display":true,"info":{"hide":["effort"]}}' '{"effort":{"level":"max"}}')" "max"

# Malformed payload must not take the line down; the effort key simply is not
# there, and the same empty-object fallback the rest of the bar uses applies.
out="$(HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=0 \
  bash "$SL" <<< 'not json' 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
check "malformed stdin still renders the bar" "$out" "⬡ Claude"
nocheck "malformed stdin invents no effort"   "$out" "│ undefined"

# ── fitting the bar to the terminal ──────────────────────────────────────────
# Claude Code renders the status line with wrap:"truncate", so a bar wider than
# the window used to lose its tail — cost and line counts, the parts that matter
# at the moment they appear. It splits at segment boundaries instead, and the
# last line is padded to the window width so it sits flush right, above Claude
# Code's own "auto mode on" footer rather than as a left-aligned block stacked
# on it.
#
# COLUMNS is how the width gets in: Claude Code spawns the command from a
# terminal and the variable is there (measured 155). tput is the second source.
# The cases below pin it through PET_INFO_WIDTH so a tput that answers in a
# non-terminal (it does, on Git Bash) cannot decide what they assert.
FIT_CONFIG='{"display":true,"currency":{"code":"USD","usd_rate":1},"pricing":{"models":{
  "m":{"input_per_mtok":1,"output_per_mtok":2,"cache_read_per_mtok":0.1}}}}'
FIT_PAYLOAD="$(jq -cn '{
  model:{display_name:"Sonnet",id:"m"}, session_id:"fit",
  workspace:{current_dir:"/tmp/project"},
  effort:{level:"high"},
  context_window:{used_percentage:21,context_window_size:200000,
    current_usage:{input_tokens:10,cache_creation_input_tokens:0,
                   cache_read_input_tokens:31000,output_tokens:1200}},
  cost:{total_cost_usd:0.01,total_duration_ms:192000,
        total_lines_added:12,total_lines_removed:3}}')"

# A home of its own, and no state.json in it: the assertion is about the metrics
# bar's line count, so a creature drawn above it would make every case read one
# line too many. PET_DIR follows HOME here, which is what the script resolves.
FIT_HOME="$TMP/home-fit"
mkdir -p "$FIT_HOME/.claude/claude-pet"

fit_render() { # $1 = width, $2 = config json → the bar, escapes stripped
  printf '%s' "$2" > "$FIT_HOME/.claude/claude-pet/config.json"
  printf '%s' "$FIT_PAYLOAD" | HOME="$FIT_HOME" PET_INFO_WIDTH="$1" \
    PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=0 \
    bash "$SL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}
fit_width() { # longest line of $1, in characters
  awk '{ if (length > m) m = length } END { print m + 0 }' <<< "$1"
}
# Count non-empty lines. `wc -l <<< "$s"` would add one for the newline the
# here-string appends, so a single-line bar measured as two.
fit_lines() { awk 'NF { n++ } END { print n + 0 }' <<< "$1"; }

# A wide terminal must not be touched: no newline, and the tail still present.
fit_wide="$(fit_render 200 "$FIT_CONFIG")"
check "a bar that fits is left on one line" "$(fit_lines "$fit_wide")" "1"
check "and nothing is dropped from it"      "$fit_wide" "+12/-3"

# Narrow: it splits, and no line exceeds the window.
fit_narrow="$(fit_render 80 "$FIT_CONFIG")"
check "a narrow window splits the bar"      "$(fit_lines "$fit_narrow")" "2"
check "no line is wider than the window"    "$(fit_width "$fit_narrow")" "80"
check "the cost survives the split"         "$fit_narrow" '$0.0100'
check "and so do the line counts"           "$fit_narrow" "+12/-3"
check "the split happens between segments"  "$fit_narrow" "cache 99%"

# The last line is padded to the full width, which is what makes it right-
# aligned. It has to be measured with the escapes still in it, because that
# padding lives inside them.
fit_pad="$(printf '%s' "$FIT_PAYLOAD" | HOME="$FIT_HOME" PET_INFO_WIDTH=80 \
  PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=0 \
  bash "$SL" 2>/dev/null | tail -1)"
case "$fit_pad" in
  *$'\033[0m') pad_closed=yes ;;
  *)           pad_closed=no ;;
esac
check "the padded line ends in a reset, so trim() keeps the padding" "$pad_closed" "yes"

# Much narrower than any segment: still one segment per line, never clipped.
fit_tiny="$(fit_render 30 "$FIT_CONFIG")"
check "a very narrow window still shows every segment" \
  "$(grep -cF '+12/-3' <<< "$fit_tiny")" "1"
check "and no line overflows the window" \
  "$(awk '{ if (length > m) m = length } END { print (m <= 30) }' <<< "$fit_tiny")" "1"

# info.wrap:false restores the single line, however long — Claude Code then
# truncates it, which is the old behaviour.
check "info.wrap=false keeps the bar on one line" \
  "$(fit_lines "$(fit_render 80 '{"display":true,"info":{"wrap":false}}')")" "1"

# No width available: nothing is attempted. Guessing would either wrap a bar
# that fits or clip one that does not. PET_INFO_WIDTH=0 is the way to say so out
# loud — unsetting COLUMNS is not enough, because tput answers even when the
# command was not started from a terminal.
fit_nowidth="$(printf '%s' "$FIT_PAYLOAD" | HOME="$FIT_HOME" PET_INFO_WIDTH=0 \
  PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=0 \
  bash "$SL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
check "without a width the bar is untouched" "$(fit_lines "$fit_nowidth")" "1"
check "and its tail is still there"          "$fit_nowidth" "+12/-3"

# The width has to count display cells, not bytes: ⚡ and CJK are two cells,
# while ⬡ │ are one — and treating every non-ASCII character as wide would push
# the padding short and leave the last line ragged.
cell_width() { # source the width helper out of the script and use it
  bash -c '
    source <(sed -n "/^ESC_SEQ=/,/^}/p" "$1")
    vis_width "$2"
  ' _ "$SL" "$1"
}
check "a wide glyph counts as two cells"   "$(cell_width '峰')" "2"
check "the bolt counts as two cells"       "$(cell_width '⚡')" "2"
check "the model mark counts as one"       "$(cell_width '⬡')" "1"
check "the divider counts as one"          "$(cell_width '│')" "1"
check "escapes take no cells"              "$(cell_width $'\033[38;5;245mab\033[0m')" "2"

# ── concurrent renders share the state file ──────────────────────────────────
# The status line refreshes every 30s while hooks fire for the same session, and
# a second Claude Code session renders against the same cost-state.json. Two
# renders that each load the map, scan, then save will have the second save drop
# the first's session — an entire session's cost and rate vanish. This was not a
# narrow window: before the lock, two sessions rendering together lost one in
# 12 of 12 trials, and even a 1 KB transcript lost one in 8 of 12.
#
# PET_TEST_STATE_HOLD stands in for a slow scan by holding the read-modify-write
# open, which makes the overlap deterministic instead of a matter of timing
# luck. It sits between the load and the save, so with the lock held it only
# serialises the writers, while without it every trial loses an entry.
add_pair RACE_A q1 m1 100 '2026-10-20T00:00:00Z' '2026-10-20T00:00:01Z'
add_pair RACE_B q1 m1 100 '2026-10-20T00:00:00Z' '2026-10-20T00:00:01Z'

race_sessions() { # number of sessions in the state file after one concurrent round
  rm -f "$PET_DIR/cost-state.json"
  local s
  for s in RACE_A RACE_B; do
    rate_run "$RATE_CONFIG" "$s" 1000 "PET_TEST_STATE_HOLD=0.6" >/dev/null &
  done
  wait
  jq -r '.sessions | length' "$PET_DIR/cost-state.json" 2>/dev/null || echo 0
}

race_kept=0
for _ in 1 2 3; do
  [[ "$(race_sessions)" == "2" ]] && race_kept=$((race_kept + 1))
done
check "concurrent renders do not drop each other's session" "$race_kept" "3"

# The rate and the cost accumulators both write the session entry. They used to
# take the lock and save separately — two transactions per render, and two
# windows to lose another session's update instead of one. A single render must
# now persist both sets of fields in one write, which is what this checks: the
# two halves land together, and the file is rewritten once.
rm -f "$PET_DIR/cost-state.json"
printf '%s' '{"display":true,"currency":{"code":"USD","usd_rate":1},"pricing":{"models":{
  "m":{"input_per_mtok":1,"output_per_mtok":2,"cache_read_per_mtok":0.1}}}}' > "$PET_DIR/config.json"
add_pair ONCE q1 m1 100 '2026-10-20T00:00:00Z' '2026-10-20T00:00:01Z'
# Non-zero usage: a fingerprint of all zeros means "no request yet", and the
# cost accumulator deliberately skips that.
once_payload="$(jq -cn '{
  model:{display_name:"m",id:"m"}, session_id:"ONCE",
  workspace:{current_dir:"/tmp/pet"},
  context_window:{used_percentage:10,context_window_size:200000,
    current_usage:{input_tokens:10,cache_creation_input_tokens:0,
                   cache_read_input_tokens:10,output_tokens:100}},
  cost:{total_cost_usd:1,total_api_duration_ms:1000}}')"
once_out="$(HOME="$TMP" CLAUDE_CONFIG_DIR="$TMP/claude-config" \
  PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=1 \
  bash "$SL" <<< "$once_payload" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
check "one render still reports the rate" "$(rate_of "$once_out")" "100.0 tok/s"
# Both accumulators' fields must be present after a single write.
once_state="$(jq -c '.sessions.ONCE // {}' "$PET_DIR/cost-state.json" 2>/dev/null)"
check "the rate fields were persisted"   "$(jq -r '.paired_tokens // "missing"' <<< "$once_state")" "100"
check "the cost fields were persisted"   "$(jq -r 'if .total_usd then "set" else "missing" end' <<< "$once_state")" "set"
check "and both share one updated_at"    "$(jq -r 'if .updated_at then "set" else "missing" end' <<< "$once_state")" "set"

# The Windows lock branch. msvcrt is Windows-only, so its use is checked with a
# stub that records what it was asked to do: a byte-range lock needs the file to
# hold at least one byte, and the lock has to be released on the way out.
py - "$SL" <<'PY'
import os, re, sys
from pathlib import Path
src = Path(sys.argv[1]).read_text(encoding="utf-8")
block = re.search(r"@contextmanager\ndef state_lock\(\):.*?\n(?=\n# ──|def )", src, re.S)
assert block, "state_lock not found"
code = block.group(0)
# Import the pieces the function closes over.
ns = {"os": os, "contextmanager": __import__("contextlib").contextmanager,
      "state_path": Path("/tmp/pet-locktest/cost-state.json"),
      "fcntl": None}
calls = []
class StubMsvcrt:
    LK_LOCK, LK_UNLCK = 2, 0
    @staticmethod
    def locking(fd, mode, nbytes):
        calls.append((mode, nbytes))
        assert nbytes == 1, "a byte-range lock must cover one byte"
ns["msvcrt"] = StubMsvcrt()
Path("/tmp/pet-locktest").mkdir(parents=True, exist_ok=True)
exec(code, ns)
with ns["state_lock"]():
    lock_file = Path("/tmp/pet-locktest/cost-state.lock")
    assert lock_file.exists(), "sidecar lock file was not created"
    assert lock_file.stat().st_size >= 1, "lock file needs a byte to lock"
assert calls == [(2, 1), (0, 1)], f"expected lock then unlock of 1 byte, got {calls}"
print("ok")
PY
if [[ $? -eq 0 ]]; then ok "the Windows lock takes and releases a byte range"
else bad "the Windows lock takes and releases a byte range" "stub check failed"; fi

# ── peak-tariff alert ────────────────────────────────────────────────────────
# Peak costs double, so past a cost threshold the warning moves to the front of
# the line with a countdown; before peak starts it pre-warns instead. Every knob
# is meant to be configurable, so each one gets a case.
PEAK_CONFIG='{"display":true,"currency":{"code":"CNY","symbol":"¥","usd_rate":6.70036411},
  "peak_alert":{"enabled":true,"countdown":true,"pre_warn_minutes":15,"cost_threshold":1,"show_premium":true},
  "pricing":{"tier_mode":"auto","peak_days":[1,2,3,4,5],
   "peak_windows":[["01:00","04:00"],["06:00","10:00"]],"off_peak_dates":["2026-10-01"],
   "models":{"deepseek-flash":{"context_tokens":1000000,
     "off_peak":{"input_per_mtok":0.15,"output_per_mtok":0.6,"cache_read_per_mtok":0.003},
     "peak":{"input_per_mtok":0.3,"output_per_mtok":1.2,"cache_read_per_mtok":0.006}}}}}'

peak_cfg() { jq -c "$1" <<< "$PEAK_CONFIG" > "$PET_DIR/config.json"; }

peak_render() { # $1=now (UTC) $2=cache-read tokens; 30M ≈ ¥1.22 at peak rates
  rm -f "$PET_DIR/cost-state.json"
  {
    printf '{"model":{"display_name":"deepseek-flash","id":"deepseek-flash"},"session_id":"t",'
    printf '"workspace":{"current_dir":"/tmp/pet"},"context_window":{"used_percentage":50,'
    printf '"context_window_size":200000,"current_usage":{"input_tokens":1000,'
    printf '"cache_creation_input_tokens":0,"cache_read_input_tokens":%s,"output_tokens":2000}},' "$2"
    printf '"cost":{"total_cost_usd":49.33}}'
  # PET_INFO_WIDTH=0: these cases assert on one line, and a tput-derived width
  # would split the bar before `tail -1` looked at it.
  } | HOME="$TMP" PET_INFO_WIDTH=0 PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_NOW_UTC="$1" \
      bash "$SL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | tail -1
}
count_in() { grep -c "$1" <<< "$2"; }

MON_PEAK=2026-10-12T02:00:00Z     # Monday, inside a peak window
MON_OFF=2026-10-12T05:00:00Z      # Monday, between the windows
MON_WARN=2026-10-12T05:50:00Z     # ten minutes before peak starts

peak_cfg '.'
line="$(peak_render "$MON_PEAK" 30000000)"
check "peak over the threshold leads the line" "$(count_in '^⚡峰' "$line")" "1"
check "countdown says when off-peak returns"   "$(count_in '⚡峰 2h00m' "$line")" "1"
check "shows what peak has cost extra"         "$(count_in '+¥0\.6' "$line")" "1"
check "the quiet trailing marker steps aside"  "$(count_in '¥1.2242 峰' "$line")" "0"

peak_cfg '.peak_alert.cost_threshold = 99'
check "below the threshold it stays quiet" \
  "$(count_in '¥1.2242 峰' "$(peak_render "$MON_PEAK" 30000000)")" "1"

peak_cfg '.'
check "off-peak raises nothing at all" \
  "$(count_in '⚡' "$(peak_render "$MON_OFF" 30000000)")" "0"
check "pre-warns just before peak"  \
  "$(count_in '⚡峰 10m 后' "$(peak_render "$MON_WARN" 30000000)")" "1"

peak_cfg '.peak_alert.pre_warn_minutes = 0'
check "pre-warning can be switched off" \
  "$(count_in '⚡' "$(peak_render "$MON_WARN" 30000000)")" "0"

peak_cfg '.peak_alert.enabled = false'
check "enabled=false restores the old behaviour" \
  "$(count_in '¥1.2242 峰' "$(peak_render "$MON_PEAK" 30000000)")" "1"

peak_cfg '.peak_alert.countdown = false | .peak_alert.show_premium = false'
check "countdown and premium can be switched off" \
  "$(count_in '^⚡峰 │' "$(peak_render "$MON_PEAK" 30000000)")" "1"

# ── information segments (info.show / info.hide) ─────────────────────────────
# info.show is the master switch for the metrics bar; info.hide drops segments
# while it is on. model is deliberately NOT hideable, so the bar cannot end up
# blank by accident.
INFO_BASE='{"display":true,"currency":{"code":"CNY","symbol":"¥","usd_rate":6.70036411},
  "pricing":{"models":{"deepseek-flash":{"context_tokens":1000000,
    "off_peak":{"input_per_mtok":0.15,"output_per_mtok":0.6,"cache_read_per_mtok":0.003},
    "peak":{"input_per_mtok":0.3,"output_per_mtok":1.2,"cache_read_per_mtok":0.006}}}}}'
INFO_PAYLOAD='{"model":{"display_name":"deepseek-flash","id":"deepseek-flash"},"session_id":"i","workspace":{"current_dir":"/home/ada/projects/github/AI/claude/claudePet"},"context_window":{"used_percentage":21.7,"context_window_size":200000,"current_usage":{"input_tokens":120,"cache_creation_input_tokens":800,"cache_read_input_tokens":41180,"output_tokens":1234}},"cost":{"total_cost_usd":0.01234,"total_duration_ms":192000,"total_lines_added":12,"total_lines_removed":3}}'

info_render() { # $1 = config JSON
  printf '%s' "$1" > "$PET_DIR/config.json"
  rm -f "$PET_DIR/cost-state.json"
  HOME="$TMP" PET_INFO_WIDTH=0 PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_NOW_UTC=2026-10-12T05:00:00Z \
    bash "$SL" <<< "$INFO_PAYLOAD" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}

bar="$(info_render "$INFO_BASE")"
check "default draws every conditional segment" \
  "$(count_in 'cache 97%' "$bar")" "1"
check "default draws duration and lines" \
  "$(( $(count_in '3m12s' "$bar") + $(count_in '+12/-3' "$bar") ))" "2"

bar="$(info_render "$(jq -c '.info = {hide: ["cache","out","duration","lines"]}' <<< "$INFO_BASE")")"
check "hide drops the named segments"  "$(( $(count_in 'cache 97%' "$bar") + $(count_in '3m12s' "$bar") + $(count_in '+12/-3' "$bar") ))" "0"
check "hide keeps the others"          "$(count_in '⬡ deepseek-flash' "$bar")" "1"
# the card says 1M, so 42.1k of context is 4% — the window override at work
check "hide keeps the context bar"     "$(count_in '4% 42.1k/1.0M' "$bar")" "1"

bar="$(info_render "$(jq -c '.info = {hide: ["model"]}' <<< "$INFO_BASE")")"
check "model is not hideable"          "$(count_in '⬡ deepseek-flash' "$bar")" "1"

bar="$(info_render "$(jq -c '.info = {show: false}' <<< "$INFO_BASE")")"
check "info.show=false drops the bar entirely" "$(count_in '⬡ deepseek-flash' "$bar")" "0"
check "info.show=false keeps the pet"  "$(count_in 'Pet: ◆' "$bar")" "1"

out="$(info_render "$(jq -c '.display = false | .info = {show: false}' <<< "$INFO_BASE")")"
check "both switches off print nothing at all" "${#out}" "0"

# ── Windows portability ──────────────────────────────────────────────────────
# These three were found on a real Windows box; the first two are bugs on any
# platform, the third was invisible on Linux because no path there has a
# backslash.

# printf %b interprets escapes, so a Windows path lost its separators before
# reaching the terminal: C:\tmp arrived as C:<TAB>mp. The final print is %s now
# and the palette holds real ESC bytes instead of the text \033. The payload is
# built by jq so the backslashes reach it as JSON escapes, not as shell input.
#
# Reset the config first: the peak tests above leave info.show=false behind, and
# a bar that is switched off prints nothing — which would look like a failure
# here rather than the deliberate silence it is.
printf '%s' '{"display":true}' > "$PET_DIR/config.json"
WIN_PAYLOAD="$(jq -cn --arg dir 'C:\tmp\projects' '{
  model:{display_name:"m",id:"m"}, session_id:"w",
  workspace:{current_dir:$dir},
  context_window:{used_percentage:5,context_window_size:200000,
    current_usage:{input_tokens:1,cache_creation_input_tokens:0,
                   cache_read_input_tokens:1,output_tokens:1}},
  cost:{total_cost_usd:0.01}}')"
win_raw="$(HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=0 \
  bash "$SL" <<< "$WIN_PAYLOAD" 2>/dev/null)"
win_out="$(sed 's/\x1b\[[0-9;]*m//g' <<< "$win_raw")"
# pnorm now folds the backslashes to forward slashes on purpose, so the path
# that reaches the bar is C:/tmp/projects. What this guards is the older bug:
# printf %b read \t as a tab and printed "C:<TAB>mp". Either spelling is fine
# here, a tab is not.
nocheck "a backslash path does not become a tab"  "$win_out" 'C:	mp'
check   "the whole Windows path reaches the bar"  "$win_out" '/tmp/projects'

# The palette must be real ESC bytes, or switching the final print to %s would
# have left the colours on screen as literal text "\033[38;5;245m".
check "the palette is real escape bytes" \
  "$(grep -c '\\033' <<< "$win_raw")" "0"
check "and the ESC byte is actually there" \
  "$([[ "$win_raw" == *$'\033'* ]] && echo yes || echo no)" "yes"

# `command -v python3` accepts the Microsoft Store stub, which prints "Python
# was not found" and exits 0. Two things have to hold, and neither is proved by
# looking for the stub's message (the script sends stderr to /dev/null):
#
#   1. a stub earlier in PATH must not hide a working interpreter later in it —
#      `command -v` stops at the first match, so the probe has to enumerate;
#   2. with no working interpreter at all, the block is skipped rather than
#      entered-and-failed.
#
# The observable split is cost-state.json plus the cost figure: the accumulators
# are python-only, and a failed estimate falls back to the payload's number.
STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\necho "Python was not found; run without arguments to install from the Microsoft Store"\nexit 0\n' \
  > "$STUB_BIN/python3"
chmod +x "$STUB_BIN/python3"
printf '%s' '{"display":true,"currency":{"code":"USD","usd_rate":1},"pricing":{"models":{"m":{"input_per_mtok":1,
  "output_per_mtok":2,"cache_read_per_mtok":0.1}}}}' > "$PET_DIR/config.json"
rm -f "$PET_DIR/cost-state.json"
stub_out="$(HOME="$TMP" PATH="$STUB_BIN:$PATH" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 \
  PET_PRICING_COST=1 bash "$SL" <<< "$WIN_PAYLOAD" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
nocheck "the Store python stub's noise never reaches the bar" "$stub_out" "Python was not found"
check   "the bar still renders with a stub on PATH"           "$stub_out" "⬡ m"
check   "a stub does not hide the real python behind it" \
  "$([[ -f "$PET_DIR/cost-state.json" ]] && echo written || echo missing)" "written"
# The payload claims 0.01; the card prices this request at ~0.000003, so the
# figure proves the estimate ran instead of falling back.
nocheck "and the cost is the estimate, not the fallback" "$stub_out" '$0.0100'

# With no working interpreter reachable, the block must be skipped: nothing
# written, nothing on stderr, and the payload's own number in the bar.
#
# The interpreter is hidden by removing every directory that holds one from
# PATH, not by replacing PATH with a bare stub directory. Git Bash's utilities
# are native binaries that load their runtime DLLs by name from their own
# directory, so a PATH made only of copied binaries fails to start bash at all
# ("error while loading shared libraries", exit 127) — which the test would
# report as "printed nothing" while proving nothing. Filtering keeps the real
# runtime reachable and only takes the interpreters away.
NOSH="$TMP/no-python"
mkdir -p "$NOSH"
for n in python3 python; do
  printf '#!/bin/sh\necho "Python was not found"\nexit 0\n' > "$NOSH/$n"
  chmod +x "$NOSH/$n"
done
NOSH_PATH="$NOSH"
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  if [[ -x "$d/python3" || -x "$d/python" || -x "$d/python.exe" || -x "$d/python3.exe" ]]; then
    continue                       # a real interpreter lives here: drop the dir
  fi
  NOSH_PATH="$NOSH_PATH:$d"
done < <(printf '%s' "$PATH" | tr ':' '\n')
rm -f "$PET_DIR/cost-state.json"
nopy_out="$(HOME="$TMP" PATH="$NOSH_PATH" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 \
  PET_PRICING_COST=1 bash "$SL" <<< "$WIN_PAYLOAD" 2>"$TMP/nopy.err" | sed 's/\x1b\[[0-9;]*m//g')"
check "without a real python nothing is written" \
  "$([[ -f "$PET_DIR/cost-state.json" ]] && echo written || echo missing)" "missing"
check "and stderr stays empty"  "$(cat "$TMP/nopy.err")" ""
check "and the bar falls back to the payload's cost" "$nopy_out" '$0.0100'

# ── path normalisation (Windows + WSL) ───────────────────────────────────────
# On Windows the same directory arrives in three shapes that never compare
# equal: Claude Code reports C:\Users\me\proj, git answers C:/Users/me/proj, and
# Git Bash's HOME is /c/Users/me. The repo-root and ~ prefixes both missed, so
# the directory segment fell back to a full absolute path. pnorm folds the
# drive-letter spellings together and leaves every POSIX path alone — WSL's
# /mnt/c/... is a real Linux path and must not be read as a drive letter.
pnorm_fn() {
  bash -c '
    source <(sed -n "/^pnorm() {/,/^}/p" "'"$SL"'")
    pnorm "$1"
  ' _ "$1"
}
# The Windows spelling of a path, as the status line would see it coming back
# from a native binary. Only meaningful under MSYS (where cygpath exists).
pnorm_msys_fn() {
  bash -c '
    source <(sed -n "/^pnorm() {/,/^}/p" "'"$SL"'")
    source <(sed -n "/^pnorm_msys() {/,/^}/p" "'"$SL"'")
    pnorm_msys "$1"
  ' _ "$1"
}
check "backslash path is folded to forward slashes" \
  "$(pnorm_fn 'E:\local-ai\proj')" "E:/local-ai/proj"
check "an already-forward path is unchanged" \
  "$(pnorm_fn 'E:/local-ai/proj')" "E:/local-ai/proj"
check "drive-relative C:proj becomes C:/proj" \
  "$(pnorm_fn 'C:proj')" "C:/proj"
check "WSL /mnt/c is left alone" \
  "$(pnorm_fn '/mnt/c/Users/me')" "/mnt/c/Users/me"
check "a POSIX path is left alone" \
  "$(pnorm_fn '/home/ada/x')" "/home/ada/x"
check "root survives" "$(pnorm_fn '/')" "/"
check "a drive root survives" "$(pnorm_fn 'C:/')" "C:/"

# The dir segment folds both sides before comparing, so a cwd whose separators
# differ from git's answer still resolves to repo-relative form. A real repo is
# used — an env override would only test the variable, not the comparison.
WINREPO="$TMP/winrepo"
mkdir -p "$WINREPO/sub"
git -C "$WINREPO" init -q 2>/dev/null
printf '%s' '{"display":true,"info":{"hide":["context","cache","out","cost","duration","lines"]}}' \
  > "$PET_DIR/config.json"
repo_out="$(HOME="$TMP" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=0 \
  bash "$SL" <<< "$(jq -cn --arg dir "$WINREPO/sub" '{
    model:{display_name:"m",id:"m"}, session_id:"d",
    workspace:{current_dir:$dir},
    context_window:{used_percentage:5,context_window_size:200000,
      current_usage:{input_tokens:1,cache_creation_input_tokens:0,
                     cache_read_input_tokens:1,output_tokens:1}},
    cost:{total_cost_usd:0.01}}')" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
check "a repo-relative dir is shown, not the absolute path" \
  "$repo_out" "winrepo/sub"
# The ~ prefix must fold too: HOME and the path both reach fmt_dir in whatever
# spelling the platform gave them.
#
# HOME is passed in the Windows spelling here. On Git Bash `mktemp -d` answers
# /tmp/..., which only MSYS understands; a native binary (jq) expands it to
# C:/Users/…/Temp/… before it reaches the payload, so HOME and the directory
# arrived in two different spellings and no prefix could match. That is a
# property of the harness, not of the folding rule — the Windows-vs-MSYS case
# already has its own test above ("backslash cwd under a drive-letter HOME").
home_spelling="$(cygpath -m "$TMP" 2>/dev/null)"
[[ -n "$home_spelling" ]] || home_spelling="$TMP"
home_out="$(HOME="$home_spelling" PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=0 \
  bash "$SL" <<< "$(jq -cn --arg dir "$home_spelling/plain/dir" '{
    model:{display_name:"m",id:"m"}, session_id:"h",
    workspace:{current_dir:$dir},
    context_window:{used_percentage:5,context_window_size:200000,
      current_usage:{input_tokens:1,cache_creation_input_tokens:0,
                     cache_read_input_tokens:1,output_tokens:1}},
    cost:{total_cost_usd:0.01}}')" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
check "a path under HOME is shown with ~" "$home_out" "~/plain/dir"

# The cases above pass on Linux with or without the folding, because a POSIX
# path is already in the folded form. These drive fmt_dir directly with the
# mixed spellings only Windows produces, which is what the folding is for.
fmt_case() { # $1 = HOME, $2 = dir, $3 = repo root
  bash -c '
    source <(sed -n "/^pnorm() {/,/^}/p" "'"$SL"'")
    source <(sed -n "/^pnorm_msys() {/,/^}/p" "'"$SL"'")
    source <(sed -n "/^fmt_dir() {/,/^}/p" "'"$SL"'")
    HOME="$1" fmt_dir "$2" "$3"
  ' _ "$1" "$2" "$3"
}
check "backslash cwd vs forward git root folds together" \
  "$(fmt_case 'C:/Users/me' 'E:\local-ai\proj\src' 'E:/local-ai/proj')" "proj/src"
check "backslash cwd under a drive-letter HOME gets ~" \
  "$(fmt_case 'C:/Users/me' 'C:\Users\me\work\thing' '')" "~/work/thing"
check "WSL cwd and root are compared untouched" \
  "$(fmt_case '/home/me' '/mnt/c/work/proj/sub' '/mnt/c/work/proj')" "proj/sub"
check "WSL path under HOME still collapses to ~" \
  "$(fmt_case '/home/me' '/home/me/x/y' '')" "~/x/y"

# Elision must keep whatever anchors the path. POSIX paths are anchored by the
# leading "/", Windows ones by the drive letter; the elided branch used to print
# a bare "/" either way, so E:/a/b/c/d came out as /…/b/c — a path that does not
# exist, with the drive silently gone.
check "a deep Windows path elides but keeps its drive letter" \
  "$(fmt_case '/home/me' 'E:\a\b\c\d' '')" "E:/…/c/d"
check "a short Windows path is shown whole" \
  "$(fmt_case '/home/me' 'E:\local-ai\claude\claudePet' '')" "E:/local-ai/claude/claudePet"
check "a deep POSIX path still elides to a leading slash" \
  "$(fmt_case '/home/me' '/opt/x/y/z' '')" "/…/y/z"

# The projects/<name> Claude Code derives replaces every non-alphanumeric
# character, not just slashes — so a Windows path keeps a double dash where the
# drive colon was. Replacing only '/' left the name untouched and the transcript
# was never found. Exercised through the rate, which is the only reader.
#
# Direct check of the rule, independent of any file lookup.
py -c '
import re, sys
cases = [
    ("E:\\local-ai\\claude\\proj", "E--local-ai-claude-proj"),
    ("C:\\Users\\me\\my_proj.v2",  "C--Users-me-my-proj-v2"),
    ("/mnt/c/Users/me/proj",       "-mnt-c-Users-me-proj"),
    ("/home/ada/x",                "-home-ada-x"),
]
bad = [(p, re.sub(r"[^A-Za-z0-9]", "-", p), w) for p, w in cases
       if re.sub(r"[^A-Za-z0-9]", "-", p) != w]
for p, got, w in bad:
    print("  FAIL project dir for %r: got %r want %r" % (p, got, w))
sys.exit(1 if bad else 0)
' && ok "the project dir name replaces every non-alphanumeric" \
  || { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "the project dir name replaces every non-alphanumeric"; }

# And end to end: a transcript filed under the Windows-derived name must be
# found from a Windows-style cwd, so the rate appears. It is placed one level
# deeper than the glob looks, i.e. NOT at projects/<name>/<session>.jsonl, so
# only the exact-path branch can find it — otherwise the glob fallback would
# rescue the wrong rule and the test would pass either way.
WINPROJ_DIR="$TMP/claude-config/projects/E--local-ai-proj"
mkdir -p "$WINPROJ_DIR"
add_pair WP wq1 wm1 100 '2026-10-20T00:00:00Z' '2026-10-20T00:00:01Z'
cp "$TRANSCRIPTS/WP.jsonl" "$WINPROJ_DIR/WP.jsonl"
winrate="$(HOME="$TMP" CLAUDE_CONFIG_DIR="$TMP/claude-config" \
  PET_FX_UPDATE=0 PET_PRICING_UPDATE=0 PET_PRICING_COST=1 \
  bash "$SL" <<< "$(jq -cn --arg dir 'E:\local-ai\proj' '{
    model:{display_name:"m",id:"m"}, session_id:"WP",
    workspace:{current_dir:$dir},
    context_window:{used_percentage:5,context_window_size:200000,
      current_usage:{input_tokens:1,cache_creation_input_tokens:0,
                     cache_read_input_tokens:1,output_tokens:1}},
    cost:{total_cost_usd:0.01}}')" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
check "a transcript under a Windows-derived project dir is found" \
  "$winrate" "100.0 tok/s"

echo
if (( FAIL > 0 )); then
  printf '  %d passed, %d FAILED\n' "$PASS" "$FAIL"
  exit 1
fi
printf '  %d passed\n' "$PASS"
