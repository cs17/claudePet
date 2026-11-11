#!/bin/bash
# pet-statusline.sh — Pet Buddy status line for Claude Code
# This script is meant to be sourced/called from a main statusline script,
# or used standalone as the statusline command.
#
# Standalone usage (in ~/.claude/settings.json):
#   "statusLine": { "type": "command", "command": "/path/to/pet-statusline.sh" }
#
# It reads JSON from stdin (Claude Code status line protocol) and outputs
# a status bar with the pet creature displayed above it.

input=$(cat)

PET_DIR="$HOME/.claude/claude-pet"
PET_CONFIG="$PET_DIR/config.json"

# Refresh FX / model pricing in background if cache stale (non-blocking)
FX_UPDATER="${PET_FX_UPDATE_SCRIPT:-$HOME/.claude/claude-pet/update-fx-rate.sh}"
if [[ "${PET_FX_UPDATE:-1}" != "0" && -x "$FX_UPDATER" ]]; then
  "$FX_UPDATER" >/dev/null 2>&1 &
fi
PRICE_UPDATER="${PET_PRICING_UPDATE_SCRIPT:-$HOME/.claude/claude-pet/update-model-pricing.sh}"
if [[ "${PET_PRICING_UPDATE:-1}" != "0" && -x "$PRICE_UPDATER" ]]; then
  "$PRICE_UPDATER" >/dev/null 2>&1 &
fi

# ── Parse JSON ───────────────────────────────────────────────────────────────
# Claude Code statusline protocol: https://code.claude.com/docs/en/statusline
# One jq call for all fields: the status line re-runs constantly and each jq is
# a process. Fields are joined with \x1f, not @tsv — IFS treats tab as a
# whitespace char, so it would collapse an empty field (model.id usually is
# one) and shift every value after it.
parse_status() {
  jq -r '
    def n(x): (x // 0) | if type == "number" then . else 0 end;
    def i(x): n(x) | floor;
    . as $in
    | ($in.context_window.current_usage) as $cu
    | [
        ($in.model.display_name // "Claude"),
        ($in.model.id // ""),
        ($in.session_id // $in.sessionId // ""),
        ($in.workspace.current_dir // $in.cwd // ""),
        i($in.context_window.used_percentage),
        i($in.context_window.context_window_size),
        # Prefer live current_usage (input+cache); fallback to total_input_tokens
        (if $cu != null then
           i($cu.input_tokens) + i($cu.cache_creation_input_tokens) + i($cu.cache_read_input_tokens)
         else i($in.context_window.total_input_tokens) end),
        i($cu.cache_read_input_tokens),
        i($in.context_window.total_output_tokens // $cu.output_tokens),
        i($cu.input_tokens),
        i($cu.cache_creation_input_tokens),
        i($cu.cache_read_input_tokens),
        i($cu.output_tokens),
        n($in.cost.total_cost_usd),
        i($in.cost.total_duration_ms),
        i($in.cost.total_lines_added),
        i($in.cost.total_lines_removed),
        # Effort for the current turn, already resolved by Claude Code — a
        # "max" the model cannot take arrives here as "high". The whole key is
        # absent when the model does not support effort, so // "" turns that
        # into "draw no segment" rather than an empty box in the line.
        ($in.effort.level // "")
      ]
    | map(tostring) | join("\u001f")
  '
}

PARSE=$(parse_status <<< "$input")
# Malformed input: re-parse an empty object so every field still gets a sane default
[[ -n "$PARSE" ]] || PARSE=$(parse_status <<< '{}')

IFS=$'\x1f' read -r \
  MODEL MODEL_ID SESSION_ID DIR PCT CTX_SIZE CTX_USED CACHE_READ OUT_TOK \
  USAGE_IN USAGE_CC USAGE_CR USAGE_OUT COST DUR_MS LINES_ADD LINES_DEL \
  EFFORT_PAYLOAD \
  <<< "$PARSE"
# The payload's value stands on its own: it needs no python, no config file and
# no transcript, so the segment keeps working when all three are missing. The
# block below only adds the transcript fallback for when the key is absent.
EFFORT="${EFFORT_PAYLOAD:-}"

# Optional local $/MTok estimate (auto-updated); may undercount — see README
COST_STATE="$PET_DIR/cost-state.json"
COST_TIER=""   # set to peak/off_peak when the model carries a peak/off-peak card
# Which python actually runs. `command -v` is not enough, and neither is the
# exit status: on Windows the Microsoft Store stub sits on PATH, answers the
# lookup, prints "Python was not found" and exits 0. So require a known marker
# on stdout — that is the only signal a stub cannot fake.
#
# Every candidate on PATH is tried, not just the first of each name. `command -v`
# stops at the first match, so one stub earlier in PATH would hide a working
# interpreter later in it; `which -a` lists them all (Git Bash ships it, and
# elsewhere a missing `which` just falls back to the single `command -v` answer).
_py_candidates() {
  local n all p
  for n in python3 python; do
    if all=$(which -a "$n" 2>/dev/null); then
      while IFS= read -r p; do [[ -n "$p" && -x "$p" ]] && printf '%s\n' "$p"; done <<< "$all"
    else
      p=$(command -v "$n" 2>/dev/null) && [[ -n "$p" && -x "$p" ]] && printf '%s\n' "$p"
    fi
  done
}
PET_PY=""
while IFS= read -r _cand; do
  [[ -n "$_cand" ]] || continue
  if [[ "$("$_cand" -c 'import sys;sys.stdout.write("PETPY")' 2>/dev/null)" == "PETPY" ]]; then
    PET_PY="$_cand"; break
  fi
done <<< "$(_py_candidates)"
unset _cand
# The block below serves two independent features: the priced cost estimate
# (PET_PRICING_COST) and the output rate (PET_OUTPUT_RATE). Run it when either
# is wanted — gating both on the pricing switch would silently take the rate
# down with it.
if { [[ "${PET_PRICING_COST:-1}" != "0" ]] || [[ "${PET_OUTPUT_RATE:-1}" != "0" ]]; } \
   && [[ -f "$PET_CONFIG" ]] && [[ -n "$PET_PY" ]]; then
  COST_CUSTOM=$(
    PET_COST_STATE="$COST_STATE" "$PET_PY" - "$PET_CONFIG" \
      "${MODEL_ID:-}" "${MODEL:-}" "${SESSION_ID:-}" \
      "${USAGE_IN:-0}" "${USAGE_CC:-0}" "${USAGE_CR:-0}" "${USAGE_OUT:-0}" \
      "${COST:-0}" "${DIR:-}" "${EFFORT_PAYLOAD:-}" <<'PY'
import json, os, re, sys
from contextlib import contextmanager
from datetime import datetime, time, timedelta, timezone
from pathlib import Path

try:
    import fcntl                                     # POSIX only; see state_lock
except ImportError:
    fcntl = None
try:
    import msvcrt                                    # Windows only; see state_lock
except ImportError:
    msvcrt = None
import time as _time                                 # `time` below is datetime.time

cfg_path, model_id, model_name, session_id, u_in, u_cc, u_cr, u_out, fallback, cwd, effort_payload = sys.argv[1:12]
state_path = Path(os.environ.get("PET_COST_STATE") or Path.home() / ".claude/claude-pet/cost-state.json")

# Fallback schedule if the config carries no schedule (peak windows are UTC)
DEFAULT_PEAK_WINDOWS = [["01:00", "04:00"], ["06:00", "10:00"]]
# Sessions kept in cost-state.json; older ones are dropped as new ones appear
MAX_SESSIONS = 20
# Shape of the rate fields in the state entry. Bump this whenever a stored
# field's meaning changes, so entries written by an older version are rescanned
# from scratch instead of being continued from (see scan_transcript). v4: the
# offset is now a line boundary, where v3 could leave it inside a fragment.
# v5: zero-token placeholder records no longer consume their message id, so the
# numerator counts the same responses it always should have; entries written by
# v4 carry totals that were silently short and cannot be continued from.
RATE_STATE_V = 5
# A response that took longer than this is a resume, a sleeping laptop or a
# stalled connection rather than generation time; counting it would let one
# outlier swamp the average.
MAX_WAIT_S = 600

def norm(s: str) -> str:
    s = (s or "").lower().strip().split("/")[-1].lstrip("~").split(":")[0]
    return re.sub(r"[^a-z0-9]+", "", s)


def _num(x) -> float:
    try:
        return float(x or 0)
    except (TypeError, ValueError):
        return 0.0


def _epoch(raw):
    """ISO-8601 timestamp to epoch seconds, or None if unusable."""
    if not isinstance(raw, str):
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


# ── per-session state ───────────────────────────────────────────────────────
# One read/modify/write pair, shared by the two accumulators below. The map is
# keyed by session id: a single slot meant any id change — resuming, or a second
# session rendering at the same time — threw the running total away and the
# status line appeared to reset.
def load_sessions() -> dict:
    try:
        st = json.loads(state_path.read_text(encoding="utf-8"))
    except Exception:
        st = {}
    if not isinstance(st, dict):
        st = {}
    sessions = st.get("sessions") if isinstance(st.get("sessions"), dict) else {}
    if not sessions and st.get("session_id"):        # migrate the old single-slot shape
        sessions = {st["session_id"]: {"total_usd": st.get("total_usd") or 0.0,
                                       "last_fp": st.get("last_fp") or "",
                                       "model": st.get("model") or ""}}
    return sessions


def trim_sessions(sessions: dict) -> dict:
    if len(sessions) > MAX_SESSIONS:                 # keep the map from growing forever
        stale = sorted(sessions, key=lambda k: (sessions[k] or {}).get("updated_at") or "")
        for key in stale[:-MAX_SESSIONS]:
            sessions.pop(key, None)
    return sessions


def save_sessions(sessions: dict) -> None:
    try:
        state_path.parent.mkdir(parents=True, exist_ok=True)
        # Unique tmp name: the rename below is atomic, but two writers sharing
        # one tmp path would interleave their writes into it first.
        tmp = state_path.with_suffix(f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps({"sessions": sessions}, ensure_ascii=False, indent=2) + "\n",
                       encoding="utf-8")
        tmp.replace(state_path)
    except Exception:
        try:
            tmp.unlink()
        except Exception:
            pass


@contextmanager
def state_lock():
    """Exclusive lock over one read/modify/write of the state file.

    Renders really do overlap: the status line refreshes every 30s, and a second
    Claude Code session writes this same file. Without the lock both load the
    map, both save, and the second save drops the first's session — a whole
    session's cost and rate disappear, and not in a narrow window: two sessions
    rendering together lost one of them in 12 of 12 trials, and even a 1 KB
    transcript lost one in 8 of 12.

    The lock is taken on a sidecar file rather than on cost-state.json:
    save_sessions replaces the state file by rename, so a lock held on the old
    inode would not exclude a render that had already opened the new one. The
    sidecar is never replaced, so every writer locks the same inode.

    POSIX uses flock; Windows uses msvcrt.locking, which has no flock equivalent
    but does provide byte-range locking. Both are advisory locks between
    cooperating processes, which is all this needs. Windows before this had no
    lock at all, so the 12-of-12 race above applied to it unmitigated.
    """
    if fcntl is None and msvcrt is None:             # no locking primitive here
        yield
        return
    lock_path = state_path.with_suffix(".lock")
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
    except OSError:
        yield                                        # cannot lock; proceed unlocked
        return
    try:
        if fcntl is not None:
            fcntl.flock(fd, fcntl.LOCK_EX)
        else:
            # msvcrt locks a byte range, so it needs at least one byte to exist.
            # LK_LOCK retries for ~10s before raising, which is long enough for
            # the other writer to finish; a failed lock degrades to unlocked
            # rather than dropping the render.
            if os.fstat(fd).st_size == 0:
                os.write(fd, b"\0")
                os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_LOCK, 1)
        yield
    except OSError:
        yield                                        # lock failed; proceed unlocked
    finally:
        try:
            if fcntl is not None:
                fcntl.flock(fd, fcntl.LOCK_UN)
            elif msvcrt is not None:
                try:
                    os.lseek(fd, 0, os.SEEK_SET)
                    msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
                except OSError:
                    pass
        finally:
            os.close(fd)


# ── output rate ─────────────────────────────────────────────────────────────
# Output tokens per second of API time, kept out of the cost math below: the
# rate must survive a missing or unmatched price card, and those paths exit
# early.
#
# The numerator comes from the session transcript, not from the payload.
# current_usage.output_tokens only describes the *last* response, and this
# script renders every ~30s, so sampling it loses every response that completes
# in between — in a tool-calling turn that is most of them. Measured against the
# transcript it read about 4x low (29.6k vs 126k over a 16-minute session). The
# transcript records every response, so it is the only sound source. Reading it
# incrementally keeps this cheap: only the bytes appended since the last render.
#
# The denominator is the API-wait time of those same responses, measured
# request by request. It excludes the time the session spent idle, waiting on
# the user, or running tools, so the ratio is generation speed rather than
# throughput over the session's life.
def projects_root() -> Path:
    base = os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude")
    return Path(base) / "projects"


def project_dir_name(cwd: str) -> str:
    """The projects/<name> Claude Code derives from a working directory.

    Documented rule: every character other than a letter or digit becomes '-'.
    That matters on Windows, where the colon and each backslash are replaced
    too — C:\\Users\\me\\my_proj.v2 becomes C--Users-me-my-proj.v2, with the
    double dash from ':' and '\\'. Linux and WSL paths survive it unchanged
    because they already consist only of letters, digits and slashes.
    """
    return re.sub(r"[^A-Za-z0-9]", "-", cwd or "")


def transcript_for(session_id: str, cwd: str):
    """The session's .jsonl, or None. The exact directory name is tried first,
    then any project (the cwd can change after a session starts, e.g. /add-dir),
    then the transcript's own siblings by session id."""
    if not session_id or session_id == "default":
        return None
    root = projects_root()
    try:
        exact = root / project_dir_name(cwd) / f"{session_id}.jsonl"
        if exact.is_file():
            return exact
        for cand in root.glob(f"*/{session_id}.jsonl"):
            return cand
    except OSError:
        pass
    return None


def scan_transcript(path, entry: dict):
    """(paired output tokens, paired API milliseconds) for this transcript.

    Also records the last effort level seen on an assistant record into
    entry["last_effort"] — the fallback for when the payload carries no
    effort.level. It comes for free here: these records are already parsed line
    by line for their usage, and the field is on the same object.

    Only new lines are read, and only whole ones — see the fragment note below.
    Deduplicated by message id, the same key the cost audit uses: one response
    can be recorded more than once, and counting those again would inflate the
    rate just as badly as missing them deflates it.

    The API time is measured per response rather than taken from the payload's
    running total. An assistant record carries requestRef, which is exactly the
    id of the api-request record that produced it, so the wait is that pair's
    timestamp difference — no estimation involved. This matters because the
    payload's total is not confined to the transcript: after a resume or an
    auto-compaction it still counts API time for history that is no longer
    here, while the tokens can only be counted where they survive. Pairing
    keeps both terms over the same responses, and a dropped history takes its
    api-request records with it, so the surviving pairs are exactly the window
    both can see.
    """
    try:
        size = path.stat().st_size
    except OSError:
        return _num(entry.get("paired_tokens")), _num(entry.get("paired_api_ms"))

    offset = _num(entry.get("transcript_offset"))
    tokens = _num(entry.get("paired_tokens"))
    api_ms = _num(entry.get("paired_api_ms"))
    seen = set(entry.get("counted_ids") or [])
    # api-request records can land in a different read than their response, so
    # unmatched ids are carried in the state until the response shows up.
    pending = entry.get("pending_requests")
    pending = dict(pending) if isinstance(pending, dict) else {}
    # Survives the rescan below on purpose: it describes the newest response in
    # the file, which a rescan re-reads rather than invalidates.
    last_effort = entry.get("last_effort") or ""
    # Start over unless this entry was written by this version, and whenever the
    # file shrank (truncated, rewritten, or compacted away under us). The dedupe
    # set and the pending map have to be cleared with the offset, or the rescan
    # skips every response it already knows and the numerator keeps only what
    # arrived after the reset — the opposite error, and just as wrong.
    if entry.get("rate_v") != RATE_STATE_V or size < offset:
        offset, tokens, api_ms, seen, pending = 0.0, 0.0, 0.0, set(), {}

    # A usage record averages 3-4 KB and peaks past 50 KB, so Claude Code's
    # append can be caught mid-write: the last line is then a fragment. The
    # offset only advances over a line that ended in a newline, so the fragment
    # is re-read once it is complete — advancing past it would persist a byte
    # count that starts the next read after a record no longer in the file, and
    # that response would be lost for good rather than merely late.
    try:
        with path.open("rb") as f:
            f.seek(int(offset))
            for raw in f:
                if not raw.endswith(b"\n"):
                    break
                try:
                    rec = json.loads(raw.decode("utf-8", "replace"))
                except Exception:
                    offset += len(raw)
                    continue
                offset += len(raw)
                if rec.get("type") == "api-request":
                    rid = rec.get("id")
                    rts = _epoch(rec.get("timestamp"))
                    if rid and rts:
                        pending[rid] = rts
                    continue
                # Before the usage check, and before the dedupe: effort belongs
                # to the assistant record itself, and a record that carries no
                # usage still states one. Records are appended in order, so the
                # last one read is the newest.
                lvl = rec.get("effort")
                if isinstance(lvl, str) and lvl:
                    last_effort = lvl
                msg = rec.get("message")
                usage = msg.get("usage") if isinstance(msg, dict) else None
                if not isinstance(usage, dict):
                    continue
                key = msg.get("id") or rec.get("uuid")
                if key is None or key in seen:
                    continue
                # The first record for a message id is often a thinking-only
                # placeholder whose usage has not been filled in yet: it carries
                # output_tokens 0, and the same id is written again once the
                # response completes. Marking the placeholder as seen consumed
                # the id, so every real record after it was dropped as a
                # duplicate — a systematic undercount of the numerator (measured
                # 15-25x low on this machine), which read as a very slow
                # generation rate rather than as a bug. So a zero-token record
                # is skipped without being marked seen, and the first record
                # that actually carries tokens is the one counted. Repeats of
                # that record carry the same value and are deduped as before.
                if _num(usage.get("output_tokens")) <= 0:
                    continue
                seen.add(key)
                # Only a response whose request we have seen counts, so the
                # numerator and the denominator cover the same responses.
                req_ts = pending.pop(rec.get("requestRef"), None)
                if req_ts is None:
                    continue
                ts = _epoch(rec.get("timestamp"))
                if ts is None:
                    continue
                wait = ts - req_ts
                if 0 <= wait < MAX_WAIT_S:
                    tokens += _num(usage.get("output_tokens"))
                    api_ms += wait * 1000.0
    except OSError:
        pass

    entry["paired_tokens"] = tokens
    entry["paired_api_ms"] = api_ms
    entry["transcript_offset"] = offset
    entry["pending_requests"] = dict(list(pending.items())[-500:])
    entry["rate_v"] = RATE_STATE_V
    # Bounded: only responses recent enough to still be in flight need this.
    entry["counted_ids"] = list(seen)[-200:]
    if last_effort:
        entry["last_effort"] = last_effort
    return tokens, api_ms


rate_str = ""

# The effort level to draw. The payload's effort.level is the value Claude Code
# resolved for the current turn — including any silent downgrade, e.g. "max" on
# a model that cannot take it arrives as "high" — so it is preferred whenever it
# is there. The key is simply absent on a model without effort support, which is
# where the transcript fallback in scan_transcript() comes in: it lags one
# response behind (a change only shows once that response lands) and needs the
# scan, which is gated on PET_OUTPUT_RATE. When neither source has a value the
# segment is dropped rather than drawn empty.
effort_str = effort_payload

# One transaction for the whole render. The two accumulators — the output rate
# and the priced cost — write the same session entry, and they used to take the
# lock separately: two load-118KB/save-118KB pairs per render, and two windows
# in which another session's update could be lost instead of one.
#
# The lock is now taken once, before anything is read, and released when the
# line has been emitted. That is the only arrangement in which the map this
# render writes is guaranteed to be the map it read: taking the lock only around
# the save would let another render load, save, and then be overwritten by a
# stale copy. The cost is that a slow transcript scan holds the lock — measured
# at tens of milliseconds, against a 30s refresh, so it does not queue up.
_sessions = None
_entry = None
_state_dirty = False
_lock_cm = None


def begin_state():
    """Take the lock, then load the map once. Idempotent for both accumulators."""
    global _sessions, _entry, _lock_cm
    if _sessions is not None:
        return _entry
    _lock_cm = state_lock()
    _lock_cm.__enter__()
    sid = session_id or "default"
    _sessions = load_sessions()
    entry = _sessions.get(sid)
    _entry = entry if isinstance(entry, dict) else {}
    return _entry


def state_was_changed():
    global _state_dirty
    _state_dirty = True


def end_state():
    """Save once if anything changed, then release the lock.

    Called from emit(), so every exit path — including the ones that cannot
    price the request — persists what the other accumulator changed.
    """
    global _lock_cm, _sessions
    if _sessions is not None and _state_dirty:
        sid = session_id or "default"
        _entry["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        _sessions[sid] = _entry
        save_sessions(trim_sessions(_sessions))
    if _lock_cm is not None:
        _lock_cm.__exit__(None, None, None)
        _lock_cm = None


if os.environ.get("PET_OUTPUT_RATE", "1") != "0":
    sid = session_id or "default"
    path = transcript_for(sid, cwd)

    begin_state()
    read_before = _entry.get("transcript_offset")
    if path:
        tokens, api_ms = scan_transcript(path, _entry)
    else:
        tokens, api_ms = 0.0, 0.0

    # Test hook: hold the read-modify-write open, standing in for a slow scan.
    # It sits between the load and the save, which is the window the lock closes
    # — with the lock held this only serialises the writers, while without it
    # two renders reliably lose one of the two sessions.
    hold = os.environ.get("PET_TEST_STATE_HOLD")
    if hold:
        try:
            _time.sleep(float(hold))
        except (TypeError, ValueError):
            pass

    # Both terms come from the transcript and cover the same responses, so this
    # needs no use of the payload's API total and no clamp to keep them in step.
    if api_ms > 0 and tokens > 0:
        _entry["rate_tok_s"] = tokens / (api_ms / 1000.0)
    rate = _entry.get("rate_tok_s")
    if isinstance(rate, (int, float)) and rate > 0:
        rate_str = f"{rate:.1f}"

    if not effort_str:
        fallback_effort = _entry.get("last_effort")
        if isinstance(fallback_effort, str):
            effort_str = fallback_effort

    # Write only when the scan consumed something: this renders every 30s, and a
    # no-op write on each would be pure churn. Keyed on the offset advancing,
    # not on having paired a response — a transcript whose responses cannot be
    # paired (a pre-2.1.301 one, or a history a compaction dropped) pairs
    # nothing at all, and a token-based guard would never persist the offset, so
    # every render would rescan the whole file for the life of the session and
    # grow the dedupe set in memory without bound.
    if path and _entry.get("transcript_offset") != read_before:
        state_was_changed()


def emit(cost, tier="", ctx="", secs="", direction="", premium=""):
    """The single output line, and the one place the state is saved.

    Every exit path goes through here — including the ones that cannot price the
    request — so the rate is always reported and whatever an accumulator changed
    is always persisted. The lock taken by begin_state() is released here, which
    is what makes the whole render one transaction.
    """
    end_state()
    print("|".join([str(cost), str(tier), str(ctx), str(secs),
                    str(direction), str(premium), rate_str, effort_str]))


try:
    cfg = json.loads(Path(cfg_path).read_text(encoding="utf-8"))
except Exception:
    emit(fallback); raise SystemExit(0)

# PET_PRICING_COST=0 means "keep Claude's total_cost_usd". The block still runs
# when only the rate is wanted, so honour that here rather than computing an
# estimate the user switched off.
if os.environ.get("PET_PRICING_COST", "1") == "0":
    emit(fallback); raise SystemExit(0)

pricing = cfg.get("pricing") if isinstance(cfg.get("pricing"), dict) else {}
models = pricing.get("models") if isinstance(pricing.get("models"), dict) else {}
if not models:
    emit(fallback); raise SystemExit(0)

candidates = []
for raw in (model_id, model_name):
    if not raw:
        continue
    leaf = raw.split("/")[-1].lstrip("~").split(":")[0]
    candidates.append(leaf)
    candidates.append(norm(leaf))

price = None
# exact key first
for c in candidates:
    if c in models:
        price = models[c]; break
if price is None:
    cn = [norm(c) for c in candidates if c]
    best = None
    for key, info in models.items():
        kn = norm(key)
        for c in cn:
            if not c or not kn:
                continue
            sc = -1
            if c == kn: sc = 100
            elif c in kn or kn in c: sc = 80 - abs(len(c) - len(kn))
            if sc >= 0 and (best is None or sc > best[0]):
                best = (sc, info)
        matched = (info or {}).get("matched") or ""
        mn = norm(matched)
        for c in cn:
            if c and mn and (c == mn or c in mn or mn in c):
                sc = 70 - abs(len(c) - len(mn))
                if best is None or sc > best[0]:
                    best = (sc, info)
    if best:
        price = best[1]

if not isinstance(price, dict):
    emit(fallback); raise SystemExit(0)

# The model's context window, when the config knows it. Claude Code reports 200k
# for models it does not recognise as extended-context, which is wrong for a
# gateway alias; the shell uses this to size the bar. Emitted here so the model
# only has to be matched once.
ctx_tokens = price.get("context_tokens")
try:
    ctx_tokens = int(ctx_tokens) if ctx_tokens else 0
except (TypeError, ValueError):
    ctx_tokens = 0


# ── peak / off-peak tier ────────────────────────────────────────────────────
# DeepSeek bills peak hours (UTC, Mon-Fri 01:00-04:00 and 06:00-10:00) at double
# the off-peak rate; every other hour, including weekends and Chinese public
# holidays, is off-peak. Only entries carrying a peak/off_peak card take part.
def utc_now():
    override = os.environ.get("PET_NOW_UTC")
    if override:                     # test hook: pin the clock
        try:
            return datetime.fromisoformat(override.replace("Z", "+00:00")).astimezone(timezone.utc)
        except Exception:
            pass
    return datetime.now(timezone.utc)


def pick_tier(now):
    """'peak' or 'off_peak' for this moment, in UTC.

    isoweekday() is deliberate: Monday is 1, matching peak_days as written.
    The peak windows run 01:00-10:00 UTC = 09:00-18:00 Beijing, so for the
    moments this decision is about, a Chinese holiday date and its UTC date
    always fall on the same day.
    """
    mode = pricing.get("tier_mode")
    if mode in ("peak", "off_peak"):
        return mode
    days = pricing.get("peak_days") or [1, 2, 3, 4, 5]
    if now.isoweekday() not in days:
        return "off_peak"
    if now.date().isoformat() in set(pricing.get("off_peak_dates") or []):
        return "off_peak"
    hhmm = now.strftime("%H:%M")
    for window in pricing.get("peak_windows") or DEFAULT_PEAK_WINDOWS:
        try:
            start, end = window
        except (TypeError, ValueError):
            continue
        if start <= hhmm < end:
            return "peak"
    return "off_peak"


tier = None
if isinstance(price.get("peak"), dict) or isinstance(price.get("off_peak"), dict):
    tier = pick_tier(utc_now())
    chosen = price.get(tier)
    if not isinstance(chosen, dict):
        # a hand-written card with only one tier: use the other rather than nothing
        chosen = price.get("peak" if tier == "off_peak" else "off_peak")
    rates = chosen if isinstance(chosen, dict) else {}
else:
    rates = price      # flat catalogue price, no tiers


def next_switch(now):
    """(seconds, direction) until the next tariff change, for the countdown.

    Peak runs 01:00-04:00 and 06:00-10:00 UTC on configured peak days, so the
    next change is either the end of the window we are in, or the start of the
    next one within the coming week (holidays and weekends are skipped).
    """
    days = pricing.get("peak_days") or [1, 2, 3, 4, 5]
    windows = pricing.get("peak_windows") or DEFAULT_PEAK_WINDOWS
    holidays = set(pricing.get("off_peak_dates") or [])

    def peak_day(d):
        return d.isoweekday() in days and d.isoformat() not in holidays

    def at(d, hhmm):
        return datetime.combine(d, time(int(hhmm[:2]), int(hhmm[3:5])), tzinfo=timezone.utc)

    if peak_day(now.date()):
        for start, end in windows:
            if start <= now.strftime("%H:%M") < end:
                return max(0, int((at(now.date(), end) - now).total_seconds())), "to_off_peak"
    for offset in range(8):
        day = (now + timedelta(days=offset)).date()
        if not peak_day(day):
            continue
        for start, _ in windows:
            target = at(day, start)
            if target > now:
                return int((target - now).total_seconds()), "to_peak"
    return 0, ""


try:
    in_r = float(rates.get("input_per_mtok") or 0)
    out_r = float(rates.get("output_per_mtok") or 0)
    cr_r = float(rates.get("cache_read_per_mtok") or 0)
    tin = float(u_in or 0); tcc = float(u_cc or 0); tcr = float(u_cr or 0); tout = float(u_out or 0)
except Exception:
    emit(fallback); raise SystemExit(0)

# last-request USD estimate
delta = (tin * in_r + tcc * in_r + tcr * cr_r + tout * out_r) / 1e6
fp = f"{int(tin)}|{int(tcc)}|{int(tcr)}|{int(tout)}"

# What this request would have cost off-peak: the difference is the peak premium
premium_delta = 0.0
if tier == "peak" and isinstance(price.get("off_peak"), dict):
    try:
        off = price["off_peak"]
        o_in = float(off.get("input_per_mtok") or 0)
        o_out = float(off.get("output_per_mtok") or 0)
        o_cr = float(off.get("cache_read_per_mtok") or 0)
        off_cost = (tin * o_in + tcc * o_in + tcr * o_cr + tout * o_out) / 1e6
        premium_delta = max(0.0, delta - off_cost)
    except (TypeError, ValueError):
        premium_delta = 0.0

# Accumulate the priced part of the session. This writes the same entry the rate
# accumulator above loaded, and the save happens in emit() — so the two never
# interleave, and only one transaction reaches the file.
# They track new responses differently on purpose — this one by a usage
# fingerprint, the rate by how far the transcript has been read — because a
# shared marker would let whichever ran first consume the other's signal.
sid = session_id or "default"
begin_state()
if not _entry:
    _entry.update({"total_usd": 0.0, "last_fp": ""})

total = float(_entry.get("total_usd") or 0.0)
last_fp = _entry.get("last_fp") or ""
if fp != "0|0|0|0" and fp != last_fp:
    total += delta
    _entry.update({
        "total_usd": total,
        "last_fp": fp,
        "model": model_id or model_name,
    })
    if premium_delta:
        _entry["premium_usd"] = float(_entry.get("premium_usd") or 0.0) + premium_delta
    state_was_changed()

# If we have no accumulated usage yet, fall back to Claude's number.
# Fields: <usd>|<peak|off_peak|>|<context tokens>|<secs to switch>|<direction>|<premium usd>|<tok/s>
# The tariff fields are emitted even when the cost had to fall back — the shell
# decides how loudly to say it — and the rate is emitted whenever it is known.
switch_secs, switch_dir = next_switch(utc_now()) if tier else (0, "")
premium = float(_entry.get("premium_usd") or 0.0)
# Through emit(), not print(): it is where the state is saved.
emit(f"{total:.8f}" if total > 0 else fallback,
     tier or "", str(ctx_tokens or ""), str(switch_secs or ""),
     switch_dir or "", f"{premium:.6f}" if premium else "")
PY
  )
  if [[ -n "$COST_CUSTOM" ]]; then
    # <usd>|<peak|off_peak|>|<context tokens>|<secs to switch>|<direction>|<premium usd>|<tok/s>|<effort>
    # a bare number means none of it was available
    IFS='|' read -r COST COST_TIER COST_WINDOW COST_SECS COST_DIR COST_PREMIUM RATE_TOK_S EFFORT \
      <<< "$COST_CUSTOM"
  fi
fi

# Durations for the peak countdown: 1h52m, 15m, <1m
fmt_dur() {
  local s="${1:-0}"
  if (( s >= 3600 )); then
    printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
  elif (( s >= 60 )); then
    printf '%dm' $((s / 60))
  else
    printf '<1m'
  fi
}

# 15500 -> 15.5k, 200000 -> 200.0k, 1000000 -> 1.0M. Pure bash: awk here would be
# a fork per call, four per render. Rounds to one decimal like printf %.1f did.
fmt_tokens() {
  local n=${1:-0} r
  (( n < 0 )) && n=0
  if (( n >= 1000000 )); then
    r=$(( (n + 50000) / 100000 * 100000 ))
    printf '%d.%dM' $(( r / 1000000 )) $(( (r % 1000000) / 100000 ))
  elif (( n >= 1000 )); then
    r=$(( (n + 50) / 100 * 100 ))
    printf '%d.%dk' $(( r / 1000 )) $(( (r % 1000) / 100 ))
  else
    printf '%d' "$n"
  fi
  return 0
}

# ── Dir + git branch (one git call) ──────────────────────────────────────────
# In a repo:  repo root name + subpath            →  claudePet/src/engine
# Otherwise:  last two segments, elision marked   →  ~/…/claude/claudePet
#
# Paths arrive in up to three shapes on Windows and none of them compare equal:
# Claude Code reports the cwd as C:\Users\me\proj (backslashes), git answers
# C:/Users/me/proj (forward slashes), and Git Bash's HOME is /c/Users/me (MSYS).
# So the repo-root and ~ prefixes below missed on every Windows machine and the
# directory fell back to a full absolute path. pnorm folds all three into the
# forward-slash form before any comparison.
#
# On Linux and in WSL nothing is rewritten: a leading / is already the right
# shape, and /mnt/c/... is a real Linux path that must not be mistaken for a
# drive letter. Only paths that open with X:/ or X:\ are converted.
pnorm() { # $1 = path → forward-slash form, drive letter preserved
  local p="${1:-}" unc=""
  [[ -n "$p" ]] || { printf '%s' ""; return 0; }
  # A path already in //server/share form keeps both leading slashes; the
  # backslash spelling (\\server\share) is left alone rather than guessed at —
  # Claude Code reports drive-letter paths, so it is not worth the risk.
  if [[ "$p" == //* ]]; then unc="/"; p="${p#/}"; fi
  # C:\Users\me  →  C:/Users/me   (only a single letter followed by : or :\ )
  if [[ "$p" =~ ^[A-Za-z]:[\\/] ]]; then
    p="${p//\\//}"
  elif [[ "$p" =~ ^[A-Za-z]:[^/\\] ]]; then
    p="${p:0:1}:/${p:2}"; p="${p//\\//}"      # C:proj → C:/proj
  fi
  # Collapse // and strip a trailing /, but keep a bare "C:/" intact
  while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
  [[ "$p" == */ && ${#p} -gt 3 ]] && p="${p%/}"
  p="${unc}${p}"
  printf '%s' "$p"
}

# MSYS/Git Bash spells the same directory as /c/Users/me. Convert to C:/… so it
# can be compared against paths that came from Claude Code. Deliberately keyed
# on the presence of cygpath: that exists only under MSYS/Cygwin, so WSL and
# Linux keep /mnt/c/... untouched.
pnorm_msys() { # $1 = path → the form Claude Code reports, when it can be known
  local p="${1:-}"
  [[ -n "$p" ]] || { printf '%s' ""; return 0; }
  if [[ "$p" =~ ^/[A-Za-z]/ ]] && command -v cygpath >/dev/null 2>&1; then
    local w
    w=$(cygpath -m "$p" 2>/dev/null) && p="$w"
  fi
  pnorm "$p"
}

GIT_DIR="$(pnorm "$DIR")"
REPO_ROOT=""
BRANCH=""
while IFS= read -r line; do
  if [[ "$line" == /* || "$line" =~ ^[A-Za-z]:[\\/] ]]; then
    REPO_ROOT="$(pnorm "$line")"                   # toplevel is always absolute
  elif [[ -n "$line" ]]; then BRANCH="$line"; fi
done < <(git -C "$GIT_DIR" rev-parse --show-toplevel --abbrev-ref HEAD 2>/dev/null)
# Unborn branch (fresh `git init`) reports "HEAD" — resolve the real name
if [[ "$BRANCH" == "HEAD" ]]; then
  BRANCH=$(git -C "$GIT_DIR" symbolic-ref --short HEAD 2>/dev/null) || BRANCH="HEAD"
fi

fmt_dir() {
  local dir root rel shown prefix slashes parent leaf home
  dir="$(pnorm "$1")"
  root="$(pnorm "$2")"
  home="$(pnorm_msys "$HOME")"
  if [[ -n "$root" ]] && [[ "$dir" == "$root" || "$dir" == "$root"/* ]]; then
    rel="${dir#"$root"}"
    printf '%s%s' "${root##*/}" "$rel"
    return 0
  fi
  # Outside a repo: "~" keeps it readable, "/" keeps it absolute
  if [[ -n "$home" ]] && [[ "$dir" == "$home" || "$dir" == "$home"/* ]]; then
    prefix="~"; shown="${dir#"$home"}"
  else
    prefix=""; shown="$dir"
  fi
  # Pure bash (no tr/wc/awk forks): strip every non-slash to count the depth.
  # A drive letter is not a separator, so E:/a/b/c counts 3 — the same depth as
  # /a/b/c — which is what makes the elision below trigger at the same point on
  # both platforms.
  slashes="${shown//[!\/]/}"
  # Without a prefix the first segment is what anchors the path: "/" on POSIX,
  # "E:" on Windows. Dropping it turned E:/a/b/c into /…/b/c, i.e. a path that
  # does not exist.
  anchor=""
  if [[ -z "$prefix" ]]; then
    if [[ "$shown" =~ ^[A-Za-z]:/ ]]; then
      anchor="${shown:0:2}"                       # E:
      shown="${shown:2}"
      slashes="${slashes#/}"
    fi
  fi
  if (( ${#slashes} > 2 )); then
    parent="${shown%/*}"; parent="${parent##*/}"
    leaf="${shown##*/}"
    printf '%s%s/…/%s/%s' "$prefix" "$anchor" "$parent" "$leaf"
  else
    printf '%s%s%s' "$prefix" "$anchor" "$shown"
  fi
}
DIR_DISPLAY=$(fmt_dir "$GIT_DIR" "$REPO_ROOT")

# ── Cost / duration / lines ──────────────────────────────────────────────────
# Currency: Claude reports USD. Optional FX via env or ~/.claude/claude-pet/config.json:
#   env:  PET_COST_CURRENCY=CNY  PET_USD_RATE=7.2  PET_COST_SHOW_USD=1
#   json: "currency": { "code":"CNY", "symbol":"¥", "usd_rate":7.2, "show_usd":false }
# One read for the whole file: this used to be four jq calls, and the background
# FX updater can rewrite config.json mid-render — a single read is also a
# consistent snapshot. The display toggle comes from the same read.
CFG_DISPLAY="true"; CFG_CODE=""; CFG_RATE=""; CFG_SHOW_USD=""; CFG_SYMBOL=""; CFG_SHOW_TIER=""
CFG_CTX_WINDOW=""; CFG_PK_ENABLED=""; CFG_PK_COUNTDOWN=""; CFG_PK_PREWARN=""; CFG_PK_THRESHOLD=""; CFG_PK_PREMIUM=""
CFG_INFO_SHOW=""; CFG_INFO_HIDE=""; CFG_INFO_WRAP=""
if [[ -f "$PET_CONFIG" ]]; then
  IFS=$'\x1f' read -r CFG_DISPLAY CFG_CODE CFG_RATE CFG_SHOW_USD CFG_SYMBOL CFG_SHOW_TIER CFG_CTX_WINDOW \
    CFG_PK_ENABLED CFG_PK_COUNTDOWN CFG_PK_PREWARN CFG_PK_THRESHOLD CFG_PK_PREMIUM \
    CFG_INFO_SHOW CFG_INFO_HIDE CFG_INFO_WRAP \
    <<< "$(jq -r '[
      (if .display == false then "false" else "true" end),
      (.currency.code // ""),
      (.currency.usd_rate // ""),
      (if .currency.show_usd == true then "1" else "" end),
      (.currency.symbol // ""),
      (if .currency.show_tier == false then "0" else "" end),
      (.context_window_tokens // ""),
      (if .peak_alert.enabled == false then "0" else "1" end),
      (if .peak_alert.countdown == false then "0" else "1" end),
      (.peak_alert.pre_warn_minutes // ""),
      (.peak_alert.cost_threshold // ""),
      (if .peak_alert.show_premium == false then "0" else "1" end),
      (if .info.show == false then "0" else "1" end),
      ((.info.hide // []) | map(select(type == "string")) | join(",")),
      (if .info.wrap == false then "0" else "1" end)
    ] | map(tostring) | join("\u001f")' "$PET_CONFIG" 2>/dev/null)"
fi
PET_DISPLAY="${CFG_DISPLAY:-true}"
SHOW_TIER="${PET_COST_TIER_LABEL:-${CFG_SHOW_TIER:-1}}"

# ── Which information segments to draw ───────────────────────────────────────
# info.show is the master switch for the whole metrics bar; info.hide drops
# individual segments while it is on. `model` is deliberately not hideable — it
# is the line's identity, so the bar cannot end up blank by accident. To hide
# everything, use info.show: false. Side effect worth knowing: the cost estimate
# keeps running while the bar is hidden, so switching it back on shows a correct
# running total instead of a fresh zero.
INFO_SHOW="${PET_INFO_SHOW:-${CFG_INFO_SHOW:-1}}"
INFO_HIDE=",${PET_INFO_HIDE:-${CFG_INFO_HIDE:-}},"
INFO_WRAP="${PET_INFO_WRAP:-${CFG_INFO_WRAP:-1}}"

seg_on() { # $1 = segment name
  [[ "$INFO_SHOW" != "0" ]] || return 1
  [[ "$1" == "model" ]] && return 0
  [[ "$INFO_HIDE" == *",$1,"* ]] && return 1
  return 0
}
# Peak-tariff alert settings (see README). Re-read every render, so editing
# config.json takes effect on the next one — thresholds included.
PK_ENABLED="${PET_PEAK_ALERT:-${CFG_PK_ENABLED:-1}}"
PK_COUNTDOWN="${PET_PEAK_COUNTDOWN:-${CFG_PK_COUNTDOWN:-1}}"
PK_PRE_WARN="${PET_PEAK_PRE_WARN_MINUTES:-${CFG_PK_PREWARN:-15}}"
PK_THRESHOLD="${PET_PEAK_COST_THRESHOLD:-${CFG_PK_THRESHOLD:-1}}"
PK_PREMIUM="${PET_PEAK_PREMIUM:-${CFG_PK_PREMIUM:-1}}"
[[ "$PK_PRE_WARN" =~ ^[0-9]+$ ]] || PK_PRE_WARN=15
[[ "$PK_THRESHOLD" =~ ^[0-9]+(\.[0-9]+)?$ ]] || PK_THRESHOLD=1
COST_CURRENCY="${PET_COST_CURRENCY:-$CFG_CODE}"
USD_RATE="${PET_USD_RATE:-$CFG_RATE}"
COST_SHOW_USD="${PET_COST_SHOW_USD:-$CFG_SHOW_USD}"
COST_SYMBOL="$CFG_SYMBOL"
COST_CURRENCY="${COST_CURRENCY:-USD}"
USD_RATE="${USD_RATE:-1}"
COST_SHOW_USD="${COST_SHOW_USD:-0}"
case "$COST_CURRENCY" in
  CNY|RMB|cny|rmb) COST_SYMBOL="${COST_SYMBOL:-¥}"; COST_CURRENCY="CNY" ;;
  USD|usd|"") COST_SYMBOL="${COST_SYMBOL:-\$}"; COST_CURRENCY="USD"; USD_RATE=1 ;;
  *) COST_SYMBOL="${COST_SYMBOL:-$COST_CURRENCY }" ;;
esac
if [[ "$COST_CURRENCY" = "USD" ]] || [[ "$USD_RATE" = "1" ]] || [[ -z "$USD_RATE" ]]; then
  COST_FMT=$(printf '%s%.4f' "$COST_SYMBOL" "$COST")
else
  COST_LOCAL=$(awk -v c="$COST" -v r="$USD_RATE" 'BEGIN{printf "%.4f", c*r}')
  if [[ "$COST_SHOW_USD" = "1" ]]; then
    COST_FMT=$(printf '%s%s (~$%.4f)' "$COST_SYMBOL" "$COST_LOCAL" "$COST")
  else
    COST_FMT=$(printf '%s%s' "$COST_SYMBOL" "$COST_LOCAL")
  fi
fi
# Which DeepSeek tariff the running total was priced at: 谷 / 峰. Past the cost
# threshold the peak warning moves to the front of the line instead (below), so
# this trailing marker stays quiet then rather than saying it twice.
PK_LOUD=0
if [[ "$PK_ENABLED" != "0" && "$COST_TIER" = "peak" ]]; then
  COST_NUM=$(awk -v c="${COST:-0}" -v r="${USD_RATE:-1}" 'BEGIN{printf "%.6f", c*r}')
  awk -v c="$COST_NUM" -v t="$PK_THRESHOLD" 'BEGIN{exit !(c >= t)}' && PK_LOUD=1
fi
if [[ -n "$COST_TIER" && "$SHOW_TIER" != "0" && "$PK_LOUD" = "0" ]]; then
  case "$COST_TIER" in
    peak)     COST_FMT="${COST_FMT} 峰" ;;
    off_peak) COST_FMT="${COST_FMT} 谷" ;;
  esac
fi
DUR_S=$(( ${DUR_MS:-0} / 1000 ))
if [[ "$DUR_S" -ge 3600 ]]; then
  DUR_FMT=$(printf '%dh%02dm' $((DUR_S/3600)) $(((DUR_S%3600)/60)))
elif [[ "$DUR_S" -ge 60 ]]; then
  DUR_FMT=$(printf '%dm%02ds' $((DUR_S/60)) $((DUR_S%60)))
else
  DUR_FMT="${DUR_S}s"
fi
LINES_FMT="+${LINES_ADD}/-${LINES_DEL}"

# ── Context window size ──────────────────────────────────────────────────────
# Claude Code reports 200000 for models it does not recognise as extended-context,
# which understates a gateway model (deepseek-flash is 1M). Prefer an explicit
# config value, then the limit configured for this model, and only use it when it
# is larger than the payload's. When it wins, recompute the percentage with the
# documented input-only formula so bar, % and numbers stay consistent.
CTX_WINDOW="${CFG_CTX_WINDOW:-}"
[[ "$CTX_WINDOW" =~ ^[0-9]+$ ]] || CTX_WINDOW=""
if [[ -z "$CTX_WINDOW" && -n "${COST_WINDOW:-}" ]] && (( ${COST_WINDOW:-0} > ${CTX_SIZE:-0} )); then
  CTX_WINDOW="$COST_WINDOW"
fi
if (( ${CTX_WINDOW:-0} > 0 )); then
  CTX_SIZE="$CTX_WINDOW"
  PCT=$(( ${CTX_USED:-0} * 100 / CTX_WINDOW ))
fi

# ── Context bar (10 chars) + numeric usage ───────────────────────────────────
# ASCII #/- so terminals missing shade glyphs (▓/░) don't show �.
[[ -z "$PCT" ]] && PCT=0
BAR_W=10
FILLED=$((PCT * BAR_W / 100))
(( FILLED > BAR_W )) && FILLED=$BAR_W
EMPTY=$((BAR_W - FILLED))
# printf -v + parameter expansion: no fork per segment (was two `tr` pipelines)
printf -v BAR '%*s' "$FILLED" ''
printf -v BAR_PAD '%*s' "$EMPTY" ''
BAR="[${BAR// /#}${BAR_PAD// /-}]"
USED_FMT=$(fmt_tokens "$CTX_USED")
SIZE_FMT=$(fmt_tokens "$CTX_SIZE")
CTX_NUM="${USED_FMT}/${SIZE_FMT}"
CACHE_FMT=$(fmt_tokens "$CACHE_READ")
OUT_FMT=$(fmt_tokens "$OUT_TOK")
# Cache hit rate = cache_read / (input + cache_write + cache_read)
# Show % first (intuition), then volume (scale):  cache 99% · 207k
CACHE_DENOM=$(( ${USAGE_IN:-0} + ${USAGE_CC:-0} + ${USAGE_CR:-0} ))
CACHE_SEG=""
if (( CACHE_DENOM > 0 )); then
  CACHE_HIT=$(( ${USAGE_CR:-0} * 100 / CACHE_DENOM ))
  (( CACHE_HIT > 100 )) && CACHE_HIT=100
  if [[ "${USAGE_CR:-0}" != "0" ]]; then
    CACHE_SEG="cache ${CACHE_HIT}% · ${CACHE_FMT}"
  else
    CACHE_SEG="cache 0%"
  fi
fi
BAR_CLR=$'\033[38;5;245m'

# ── ANSI palette ─────────────────────────────────────────────────────────────
# $'…' so these are real ESC bytes, not the four characters \033. The status
# line is printed with %s (see the end of this file) so that a path like C:\tmp
# keeps its backslash instead of having \t turned into a tab by %b; that means
# nothing may rely on printf interpreting escapes any more.
RST=$'\033[0m'
GRAY=$'\033[38;5;245m'
DIM=$'\033[38;5;238m'
SEP="${DIM} │ ${RST}"

# ── Peak-tariff alert ────────────────────────────────────────────────────────
# Peak costs double, so say it where the eye lands first: the start of the line.
# Only past the cost threshold, or it would shout through the ~7h of every
# weekday that is peak. Pre-warning fires just before peak starts, which is the
# actionable half — it is the moment to decide whether to wait.
PK_PREFIX=""
AMBER=$'\033[1;38;5;214m'
if [[ "$PK_ENABLED" != "0" && "$INFO_SHOW" != "0" ]]; then
  if (( PK_LOUD )); then
    PK_PREFIX="${AMBER}⚡峰"
    if [[ "$PK_COUNTDOWN" != "0" ]] && (( ${COST_SECS:-0} > 0 )); then
      PK_PREFIX="${PK_PREFIX} $(fmt_dur "${COST_SECS:-0}")"
    fi
    if [[ "$PK_PREMIUM" != "0" && -n "${COST_PREMIUM:-}" ]] \
       && awk -v p="$COST_PREMIUM" 'BEGIN{exit !(p > 0.0001)}'; then
      PK_PREFIX="${PK_PREFIX} +$(printf '%s%.2f' "$COST_SYMBOL" \
        "$(awk -v p="$COST_PREMIUM" -v r="$USD_RATE" 'BEGIN{printf "%.2f", p*r}')")"
    fi
    PK_PREFIX="${PK_PREFIX}${RST}${SEP}"
  elif [[ "$COST_TIER" = "off_peak" && "$PK_PRE_WARN" -gt 0 && "${COST_DIR:-}" = "to_peak" ]] \
       && (( ${COST_SECS:-0} > 0 )) && (( ${COST_SECS:-0} <= PK_PRE_WARN * 60 )); then
    PK_PREFIX="${AMBER}⚡峰 $(fmt_dur "${COST_SECS:-0}") 后${RST}${SEP}"
  fi
fi

# ── Assemble status bar ──────────────────────────────────────────────────────
# Example:
#   ⬡ model │ high │ claudePet │ [###-------] 21% 42.1k/200k │ cache 99% · 207k │ out 1.2k │ ¥0.01 │ 3m12s │ +12/-3
# Each segment is gated by seg_on, so info.hide can drop any of them but model.
# effort sits next to the model because it qualifies it — the same model at
# "low" and at "max" is a different trade of tokens for quality — and because it
# disappears entirely on a model without effort support, which reads better
# there than as a gap further down the line.
L="$PK_PREFIX"
seg_on model    && L="${L}${GRAY}⬡ ${MODEL}${RST}"
seg_on effort   && [[ -n "${EFFORT:-}" ]] && L="${L}${SEP}${GRAY}${EFFORT}${RST}"
seg_on dir      && L="${L}${SEP}${GRAY}${DIR_DISPLAY}${RST}"
seg_on branch   && [[ -n "$BRANCH" ]] && L="${L}${SEP}${GRAY}⎇ ${BRANCH}${RST}"
seg_on context  && L="${L}${SEP}${BAR_CLR}${BAR}${RST}${GRAY} ${PCT}% ${CTX_NUM}${RST}"
seg_on cache    && [[ -n "$CACHE_SEG" ]] && L="${L}${SEP}${GRAY}${CACHE_SEG}${RST}"
seg_on out      && [[ "${OUT_TOK:-0}" != "0" ]] && L="${L}${SEP}${GRAY}out ${OUT_FMT}${RST}"
RATE_FMT=""
if [[ -n "${RATE_TOK_S:-}" ]]; then printf -v RATE_FMT '%.1f' "$RATE_TOK_S" 2>/dev/null || RATE_FMT="$RATE_TOK_S"; fi
seg_on rate     && [[ -n "$RATE_FMT" ]] && L="${L}${SEP}${GRAY}${RATE_FMT} tok/s${RST}"
seg_on cost     && L="${L}${SEP}${GRAY}${COST_FMT}${RST}"
seg_on duration && [[ "${DUR_MS:-0}" != "0" ]] && L="${L}${SEP}${GRAY}${DUR_FMT}${RST}"
if seg_on lines && { [[ "${LINES_ADD:-0}" != "0" ]] || [[ "${LINES_DEL:-0}" != "0" ]]; }; then
  L="${L}${SEP}${GRAY}${LINES_FMT}${RST}"
fi

# ── Fit the bar to the terminal ──────────────────────────────────────────────
# A narrow window used to cut the tail of the bar off, since Claude Code renders
# a single line with wrap:"truncate" — the cost and the line counts are what
# disappeared, at the times they matter most.
#
# The bar is assembled as segments separated by SEP, and the first one starts
# with a colour escape. Splitting on that exact separator is safe: no segment
# contains it, and the escape sequences they do contain never spell " │ ".
#
# Two modes, chosen with info.wrap (default on):
#   on    the bar splits at segment boundaries into as many lines as it needs.
#         The last line — the one directly above Claude Code's own mode footer
#         ("auto mode on") — is padded to the full width and so sits flush
#         right, which keeps the overflow from reading as a left-aligned block
#         stacked on top of that footer. Nothing is dropped: a segment only ever
#         moves to another line, and the split happens between segments, so no
#         value is cut in half.
#   off   one line, however long. Claude Code renders it with wrap:"truncate",
#         so the tail is cut — for anyone who prefers the old behaviour.
#
# The padding is emitted inside the colour escapes on purpose: Claude Code runs
# every output line through .trim(), which would eat a trailing run of spaces.
# Ending the run with RST leaves .trim() nothing to take.
#
# The width comes from COLUMNS. Claude Code spawns the command from a terminal,
# so it is there in practice (measured 155); tput is the second source for a
# caller that did not inherit it. PET_INFO_WIDTH overrides both — set it to pin
# a width by hand, or to 0 to switch fitting off for a caller where tput would
# otherwise answer. With no width from anywhere, no fitting is attempted at all:
# guessing would either wrap something that fits or clip something that does not.
FIT_WIDTH="${PET_INFO_WIDTH:-${COLUMNS:-}}"
[[ "$FIT_WIDTH" =~ ^[0-9]+$ ]] || FIT_WIDTH="$(tput cols 2>/dev/null)"
if [[ "$FIT_WIDTH" =~ ^[0-9]+$ ]] && (( FIT_WIDTH > 0 )); then :; else FIT_WIDTH=""; fi

# Visible width of a string: escapes have no width, and the CJK characters this
# line can contain (峰 谷 ⚡, plus anything a model name carries) are two cells.
# Scanned by code point, not by cell, so a multi-byte character counts once.
ESC_SEQ=$'\033'
# A CSI sequence (colour, reset) as a regex, stripped one at a time in a loop.
# The parameter-expansion form `${s//$'\033'\[[0-9;]*m/}` looks equivalent but
# is not: `*` there runs past the closing `m` and swallows the text after it,
# so a whole line measured as zero width.
ANSI_RE="${ESC_SEQ}\[[0-9;]*m"
vis_width() {
  local s="$1" w=0 i c
  while [[ "$s" =~ $ANSI_RE ]]; do
    s="${s/"${BASH_REMATCH[0]}"/}"
  done
  # ${#s} is a count of characters, and ${s:i:1} yields one character at a
  # time, so each character is classified exactly once — no byte arithmetic.
  # Widths follow the East Asian Width property, because guessing "any non-ASCII
  # is wide" overstates the box-drawing glyphs this bar is built from: ⬡ is
  # narrow (N) and │ ◆ are ambiguous (A), which terminals draw in one cell,
  # while ⚡ and the CJK in a model name are wide (W) and take two.
  local cp
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    if [[ "$c" == [\ -~] ]]; then
      (( w += 1 )); continue
    fi
    cp=$(printf '%d' "'$c" 2>/dev/null) || cp=0
    # Wide ranges, per Unicode East Asian Width: CJK, Hangul, kana and the
    # fullwidth forms. U+26A1 (⚡) is East Asian Wide but sits below the emoji
    # block, so it needs its own clause — treating it as narrow pulled the
    # padding one cell short whenever the peak-tariff marker was on the line.
    if (( cp == 0x26A1 \
       || (cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x2E80 && cp <= 0xA4CF) \
       || (cp >= 0xAC00 && cp <= 0xD7A3) || (cp >= 0xF900 && cp <= 0xFAFF) \
       || (cp >= 0xFE30 && cp <= 0xFE6F) || (cp >= 0xFF00 && cp <= 0xFF60) \
       || (cp >= 0xFFE0 && cp <= 0xFFE6) || (cp >= 0x1F300 && cp <= 0x1F64F) \
       || (cp >= 0x20000 && cp <= 0x3FFFD) )); then
      (( w += 2 ))
    else
      (( w += 1 ))
    fi
  done
  printf '%d' "$w"
}

# A segment list → lines at most $2 wide, splitting only at segment boundaries.
# Greedy: a segment joins the current line while it still fits, so the number of
# lines is minimal. Every line is emitted with its colour escapes intact and
# closed with RST, because Claude Code renders each line independently and a
# colour left open at the end of a line would bleed into the next.
#
# The last line is padded to the full width and then closed with RST again: the
# padding has to end in an escape for .trim() to keep it, which is what puts the
# final line flush against the right edge, on the row just above Claude Code's
# own mode footer. Nothing is lost either way — wrapping only ever moves
# segments to another line, it never drops or abbreviates one.
wrap_segments() { # $1 = the bar, $2 = max width → prints lines
  local rest="$1" max="$2"
  local line="" lw=0 seg sw sepw=0 pad gap
  local -a lines=()

  sepw=$(vis_width "$SEP")
  # Cut at the first separator each time. Quoting SEP inside the pattern makes
  # both expansions literal, so its escape characters are matched as-is.
  while [[ "$rest" == *"$SEP"* ]]; do
    seg="${rest%%"$SEP"*}"
    rest="${rest#*"$SEP"}"
    sw=$(vis_width "$seg")
    if [[ -n "$line" ]] && (( lw + sepw + sw > max )); then
      lines+=("$line")
      line="$seg"; lw=$sw
    else
      if [[ -n "$line" ]]; then line="${line}${SEP}${seg}"; (( lw += sepw + sw ))
      else line="$seg"; lw=$sw; fi
    fi
  done
  # The final segment and the trailing run of the bar (no separator after it).
  seg="$rest"
  if [[ -n "$seg" ]]; then
    sw=$(vis_width "$seg")
    if [[ -n "$line" ]] && (( lw + sepw + sw > max )); then
      lines+=("$line"); line="$seg"; lw=$sw
    else
      if [[ -n "$line" ]]; then line="${line}${SEP}${seg}"; (( lw += sepw + sw ))
      else line="$seg"; lw=$sw; fi
    fi
  fi
  [[ -n "$line" ]] && lines+=("$line")

  # Right-align the last line. A line that is already at the limit is left
  # alone, and a terminal too narrow to hold even that line gets no padding
  # attempt — the padding is only ever additive, never a reason to clip.
  local last=$(( ${#lines[@]} - 1 ))
  if (( last >= 0 )); then
    gap=$(( max - $(vis_width "${lines[$last]}") ))
    (( gap > 0 )) && { printf -v pad '%*s' "$gap" ''; lines[$last]="${lines[$last]}${pad}${RST}"; }
  fi

  printf '%s\n' "${lines[@]}"
}

# ── Pet Buddy (monstapix block art) ──────────────────────────────────────────
# PET_DISPLAY came from the config read above
PET_STATE="$PET_DIR/state.json"
PET_SPRITES="$PET_DIR/sprites.json"
PET_ACTIVITY="$PET_DIR/last-activity.json"
PET_CREATURES="$PET_DIR/creatures.json"

if [[ "$PET_DISPLAY" = "true" ]] && [[ -f "$PET_STATE" ]] && [[ -f "$PET_SPRITES" ]] && command -v jq &>/dev/null; then
  IFS=$'\x1f' read -r PET_STAGE_IDX PET_LINE_ID PET_XP \
    <<< "$(jq -r '[
      (.currentStageIndex // 0), (.currentLineId // "titan"), (.xp // 0)
    ] | map(tostring) | join("\u001f")' "$PET_STATE" 2>/dev/null)"

  # Name and next threshold in one pass over creatures.json, family-aware.
  # An unknown family (hand-edited state.json) falls back to the first line.
  # keys[0] must be evaluated against .evolutionLines, not the root — inside the
  # pipeline `.` is evolutionLines, so it picks a real family id.
  IFS=$'\x1f' read -r PET_XP_NEXT PET_NAME \
    <<< "$(jq -r --arg line "${PET_LINE_ID:-titan}" --argjson idx "${PET_STAGE_IDX:-0}" '
      (.evolutionLines | (.[$line] // .[keys[0]]) | .stages) as $s
      | ($s[$idx] // $s[0]) as $cur
      | [
          (if $idx + 1 < ($s | length) then $s[$idx + 1].xpRequired else "MAX" end),
          ($cur.name // "???")
        ] | map(tostring) | join("\u001f")' "$PET_CREATURES" 2>/dev/null)"

  # Read last activity message (within 10 min)
  PET_MSG=""
  if [[ -f "$PET_ACTIVITY" ]]; then
    IFS=$'\x1f' read -r ACT_TS ACT_MSG \
      <<< "$(jq -r '[(.timestamp // 0), (.message // "")] | map(tostring) | join("\u001f")' "$PET_ACTIVITY" 2>/dev/null)"
    ACT_S=$(( ${ACT_TS:-0} / 1000 ))
    AGE=$(( $(date +%s) - ACT_S ))
    (( AGE < 600 )) && PET_MSG="$ACT_MSG"
  fi

  # Read sprite lines and print with message on first, info on last.
  # The trailing \r is stripped because jq on Windows is a native binary and
  # writes CRLF: left in, it lands at the end of every sprite row, and a bare CR
  # in the middle of the bar is a cursor reset — the pet's last row ends up
  # overwriting the line the metrics are drawn on.
  SPRITE_LINES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    SPRITE_LINES+=("${line%$'\r'}")
  done < <(jq -r --arg line "${PET_LINE_ID:-titan}" --arg idx "${PET_STAGE_IDX:-0}" \
    '((.[$line] // .[keys[0]])[$idx] // [])[]' "$PET_SPRITES" 2>/dev/null)

  if (( ${#SPRITE_LINES[@]} > 0 )); then
    SPRITE_W=0
    for sl in "${SPRITE_LINES[@]}"; do
      [[ ${#sl} -gt "$SPRITE_W" ]] && SPRITE_W=${#sl}
    done
    SPRITE_W=$((SPRITE_W + 1))

    LAST_IDX=$(( ${#SPRITE_LINES[@]} - 1 ))
    for (( i=0; i<${#SPRITE_LINES[@]}; i++ )); do
      PADDED=$(printf "%-${SPRITE_W}s" "${SPRITE_LINES[$i]}")
      if [[ "$i" -eq 0 ]] && [[ -n "$PET_MSG" ]]; then
        printf "%s\n" "${GRAY}${PADDED} ${PET_MSG}${RST}"
      elif [[ "$i" -eq "$LAST_IDX" ]]; then
        printf "%s\n" "${GRAY}${PADDED} Pet: ◆ ${PET_NAME:-???}  ♥ ${PET_XP}/${PET_XP_NEXT} XP${RST}"
      else
        printf "%s\n" "${GRAY}${PADDED}${RST}"
      fi
    done
  fi
fi

# Print the bar unless the information is switched off (info.show: false). A
# missing state/sprites file must still not blank it — that is what the
# pet-display branch used to get wrong. Printing nothing here with both switches
# off leaves an empty status line row (observed): Claude Code reserves that
# region, so it is not something this script can take back.
if [[ -n "$L" ]]; then
  BAR_LINES=()
  if [[ -n "$FIT_WIDTH" && "${INFO_WRAP:-1}" != "0" ]] \
     && (( $(vis_width "$L") > FIT_WIDTH )); then
    while IFS= read -r _wl; do
      [[ -n "$_wl" ]] && BAR_LINES+=("$_wl")
    done < <(wrap_segments "$L" "$FIT_WIDTH")
  fi
  if (( ${#BAR_LINES[@]} > 0 )); then
    printf "%s\n" "${BAR_LINES[@]}"
  else
    printf "%s\n" "$L"
  fi
fi
