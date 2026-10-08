#!/usr/bin/env bash
# Grindstone hook handler. Wired up in ../hooks/hooks.json.
#
#   prompt   UserPromptSubmit: "/grindstone:on [task]" turns Grindstone on, "/grindstone:off" turns it off
#   guard    PreToolUse: blocks changes outside the project folder while on
#   stop     Stop: while on, sends Claude into its next work or review cycle
#   failure  StopFailure (asyncRewake): after a usage/rate limit, waits, then wakes Claude
#   end      SessionEnd: clears the session's state
#
# Per-session state: $DATA/sessions/<session_id>/{root,notes,base,count,lens,mtime,stale}

RES="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/grindstone-data}"
SESSIONS="$DATA/sessions"
LOG="$DATA/grindstone.log"
PLAYBOOK="$RES/PLAYBOOK.md"
TEMPLATE="$RES/templates/notes.md"
mkdir -p "$SESSIONS"

# The guard runs before every tool call in every session; bail out fast when no
# session has Grindstone on.
if [ "$1" = guard ] && [ -z "$(ls -A "$SESSIONS" 2>/dev/null)" ]; then exit 0; fi

if ! command -v jq >/dev/null 2>&1; then
  if [ "$1" = prompt ] && grep -qE '"prompt(_text)?"[[:space:]]*:[[:space:]]*"[[:space:]]*/grindstone'; then
    echo "Grindstone could NOT be turned on because the 'jq' tool isn't installed. Tell the user to install jq (macOS: brew install jq · Debian/Ubuntu: sudo apt install jq · Fedora: sudo dnf install jq) and then run /grindstone:on again. Don't start the task."
  fi
  exit 0
fi

# Settings from the plugin's /config options (with defaults for older versions
# and for running outside Claude Code).
is_true() { [[ "$(tr '[:upper:]' '[:lower:]' <<<"$1")" =~ ^(true|yes|1|on)$ ]]; }
RETRY_WAIT="${GRINDSTONE_RETRY_WAIT:-$(( ${CLAUDE_PLUGIN_OPTION_RETRY_MINUTES:-15} * 60 ))}"
REVIEW_EVERY="${GRINDSTONE_REVIEW_EVERY:-${CLAUDE_PLUGIN_OPTION_REVIEW_EVERY:-5}}"
[[ "$RETRY_WAIT" =~ ^[0-9]+$ ]] && (( RETRY_WAIT > 0 )) || RETRY_WAIT=900
[[ "$REVIEW_EVERY" =~ ^[0-9]+$ ]] && (( REVIEW_EVERY > 0 )) || REVIEW_EVERY=5
ALLOW_REMOTE=no
is_true "${CLAUDE_PLUGIN_OPTION_ALLOW_REMOTE:-${GRINDSTONE_ALLOW_REMOTE:-}}" && ALLOW_REMOTE=yes
EXTRA_ALLOWED_PATHS=()
EXTRA_RAW="${CLAUDE_PLUGIN_OPTION_EXTRA_ALLOWED_PATHS:-${GRINDSTONE_EXTRA_ALLOWED_PATHS:-}}"
if [[ "$EXTRA_RAW" == \[* ]]; then
  while IFS= read -r p; do [ -n "$p" ] && EXTRA_ALLOWED_PATHS+=("$p"); done < <(jq -r '.[]?' <<<"$EXTRA_RAW" 2>/dev/null)
else
  while IFS= read -r p; do
    p="$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"$p")"
    [ -n "$p" ] && EXTRA_ALLOWED_PATHS+=("$p")
  done < <(tr ',\n' '\n\n' <<<"$EXTRA_RAW")
fi

# Review lenses, rotated one per review cycle. "Name|what to look at".
LENSES=(
  "Fresh-eyes goal check|Read the full diff since the base commit the way a strict reviewer seeing it for the first time would. Are the acceptance criteria really met, with evidence? Any regressions or leftovers?"
  "Correctness & edge cases|Try to break the main flows: empty, huge, malformed and unexpected input, failure paths, boundaries, concurrency."
  "Tests & verification|Which critical paths have no tests? Are any tests flaky, or passing for the wrong reason? Can the whole thing be verified with one command?"
  "User experience|Use it the way a first-time user would. Look at error messages, empty and loading states, wording, accessibility, and anything confusing or slow."
  "Code quality|Look for duplication, unclear names, dead code, long functions and wrong abstractions. Find the most complex part and see whether it can be simpler."
  "Security & robustness|Check input validation, injection, secrets in code or logs, permissions, unsafe defaults, resource leaks and dependency risk."
  "Performance|Measure before changing anything. Look at hot paths, wasted work, N+1 queries, bundle size and startup time."
  "Docs & setup|Could a newcomer set this up and run it from the docs alone? Add comments where the code isn't obvious and fix docs that are out of date."
)

INPUT="$(cat)"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT")"
CWD="$(jq -r '.cwd // empty' <<<"$INPUT")"
[ -z "$SESSION_ID" ] && exit 0
[[ "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0
S="$SESSIONS/$SESSION_ID"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${SESSION_ID:0:8} $*" >>"$LOG"; }
get() { cat "$S/$1" 2>/dev/null || echo "$2"; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------- path guard

# Absolute, normalised, symlink-resolved form of a path that may not exist yet.
abspath() {
  local p="$1" base="$2" seg head tail=""
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p:2}" ;;
  esac
  p="${p//\$\{HOME\}/$HOME}"; p="${p//\$HOME/$HOME}"
  [[ "$p" == /* ]] || p="$base/$p"
  local IFS=/ out=()
  set -f
  for seg in $p; do
    case "$seg" in
      ""|.) ;;
      ..) ((${#out[@]})) && unset "out[$((${#out[@]} - 1))]" ;;
      *) out+=("$seg") ;;
    esac
  done
  set +f
  head="/${out[*]}"
  while [ ! -e "$head" ] && [ "$head" != / ]; do
    tail="/${head##*/}$tail"; head="${head%/*}"; [ -z "$head" ] && head=/
  done
  head="$(realpath "$head" 2>/dev/null || echo "$head")"
  head="${head%/}$tail"
  echo "${head:-/}"
}

under() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }

TEMP_DIRS=(/tmp /private/tmp /var/tmp /private/var/tmp /var/folders /private/var/folders
           /dev/null /dev/stdout /dev/stderr /dev/tty /dev/fd)
[ -n "${TMPDIR:-}" ] && TEMP_DIRS+=("$(abspath "$TMPDIR" /)")

# May Grindstone change this (absolute) path?
can_write() {
  local d
  under "$1" "$ROOT" && return 0
  for d in "${EXTRA_ALLOWED_PATHS[@]}"; do under "$1" "$(abspath "$d" "$ROOT")" && return 0; done
  for d in "${TEMP_DIRS[@]}"; do under "$1" "$d" && return 0; done
  return 1
}

# May a shell command mention this path? Root-owned system folders are fine to
# reference (running binaries, reading headers); changing them needs sudo, which is blocked.
can_reference() {
  local d
  can_write "$1" && return 0
  under "$1" /usr/local && return 1
  for d in /usr /bin /sbin /lib /lib64 /System /etc /private/etc /dev; do under "$1" "$d" && return 0; done
  return 1
}

SQ="'"
Q_RE='"(~|\$HOME|/|\.\.)[^"]*"'
S_RE="${SQ}(~|\\\$HOME|/|\\.\\.)[^${SQ}]*${SQ}"
U_RE="(^|[[:space:]=:(<>|;&])(~|\\\$HOME|/|\\.\\.)[^[:space:];|&)${SQ}\"<>]*"

# Path-like words in a command or script, one per line.
path_tokens() {
  grep -oE "$Q_RE|$S_RE" <<<"$1" | sed -E "s/^[\"$SQ]//; s/[\"$SQ]\$//"
  sed -E "s#$Q_RE##g; s#$S_RE##g" <<<"$1" | grep -oE "$U_RE" | sed -E 's/^[[:space:]=:(<>|;&]//' | grep -v '^//'
}

# The command word of each pipeline / list segment.
command_heads() {
  awk '{
    gsub(/\|\||&&|;|\||\$\(|`|\(|\)|&/, "\n")
    n = split($0, segs, "\n")
    for (s = 1; s <= n; s++) {
      m = split(segs[s], w, /[ \t]+/)
      for (i = 1; i <= m; i++) {
        x = w[i]
        if (x == "" || x == "!" || x ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
        if (x ~ /^(if|then|else|elif|do|while|until|time|\{|\})$/) continue
        if (x ~ /^(for|case|done|fi|esac|in)$/) break
        print x; break
      }
    }
  }' <<<"$1"
}

HARD_RE='(^|[^[:alnum:]_./-])(sudo|doas|launchctl|crontab|systemctl|systemsetup|scutil|diskutil|csrutil|nvram|shutdown|reboot|halt)([[:space:]]|$)|(^|[^[:alnum:]_-])defaults[[:space:]]+(write|delete)|(npm|pnpm)[[:space:]][^;&|]*[[:space:]](-g|--global)([[:space:]]|$)|yarn[[:space:]]+global|brew[[:space:]]+(install|uninstall|remove|rm|upgrade|reinstall|link|unlink|tap|untap|services|cleanup)|(apt|apt-get|dnf|yum|pacman|zypper|snap)[[:space:]]+(install|remove|purge|upgrade|-S)|pip3?[[:space:]]+install[^;&|]*(--user|--break-system-packages)|(cargo|go|gem)[[:space:]]+install'
REMOTE_RE='git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+push([[:space:]]|$)|gh[[:space:]]+(pr|repo|release|issue|gist|api|workflow)[[:space:]]|(npm|pnpm|yarn)[[:space:]]+publish'
READONLY_RE='^(cat|head|tail|less|more|ls|grep|egrep|fgrep|rg|ag|find|fd|wc|diff|cmp|stat|file|which|type|whereis|pwd|realpath|readlink|du|df|tree|sort|uniq|cut|tr|awk|sed|jq|yq|basename|dirname|test|\[|\[\[|echo|printf|true|false|date|md5|md5sum|shasum|sha256sum|xxd|hexdump|strings|nl|column|comm|paste|fold|rev|tac|od)$'
WRITEFLAG_RE='(^|[[:space:]])(-delete|-exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls|--in-place)([[:space:]=]|$)|sed[[:space:]]([^|;&]*[[:space:]])?-[a-zA-Z]*i([[:space:]]|$)|system[[:space:]]*\('

# Prints why a shell command is blocked, or nothing if it is allowed.
check_shell() {
  local c="$1" base="$2" t a heads outside=""
  if [[ "$c" =~ $HARD_RE ]]; then
    echo "\`${BASH_REMATCH[0]# }\` changes the system or global packages"; return
  fi
  if [ "$ALLOW_REMOTE" != yes ] && [[ "$c" =~ $REMOTE_RE ]]; then
    echo "\`${BASH_REMATCH[0]}\` reaches a remote service (commit locally instead)"; return
  fi
  if [[ "$c" =~ (^|[;&|(])[[:space:]]*cd[[:space:]]*($|[;&|)]) ]]; then
    echo "a bare \`cd\` moves to the home folder"; return
  fi
  # Commands that switch directory: cd, pushd, -C, --directory, --prefix, --cwd.
  local arg="(\"[^\"]*\"|${SQ}[^${SQ}]*${SQ}|[^;&|[:space:])]+)"
  while IFS= read -r t; do
    [ -z "$t" ] || [ "$t" = - ] && continue
    a="$(abspath "$t" "$base")"
    can_write "$a" || { echo "it switches to $a"; return; }
  done < <(grep -oE "(^|[;&|([:space:]])(cd|pushd)[[:space:]]+$arg|[[:space:]](-C|--directory|--prefix|--cwd)[=[:space:]]+$arg" <<<"$c" \
             | sed -E 's/^.*(cd|pushd|-C|--directory|--prefix|--cwd)[=[:space:]]+//' | sed -E "s/^[\"$SQ]//; s/[\"$SQ]\$//")
  # Output redirections.
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    a="$(abspath "$t" "$base")"
    can_write "$a" || { echo "it writes output to $a"; return; }
  done < <(grep -oE '[&0-9]*>>?[[:space:]]*[^&[:space:];|)<>][^[:space:];|)<>]*' <<<"$c" \
             | sed -E 's/^[&0-9]*>>?[[:space:]]*//' | sed -E "s/^[\"$SQ]//; s/[\"$SQ]\$//")
  # Any other path outside the project: only read-only commands may touch it.
  heads="$(command_heads "$c")"
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    grep -qxF -- "$t" <<<"$heads" && continue   # running a program by its path
    a="$(abspath "$t" "$base")"
    can_reference "$a" || { outside="$a"; break; }
  done < <(path_tokens "$c")
  [ -z "$outside" ] && return
  if [[ "$c" =~ $WRITEFLAG_RE ]]; then
    echo "it uses \`${BASH_REMATCH[0]# }\` on $outside"; return
  fi
  while IFS= read -r t; do
    [[ "${t##*/}" =~ $READONLY_RE ]] || { echo "\`${t##*/}\` could modify $outside"; return; }
  done <<<"$heads"
}

deny() {
  log "GUARD blocked $tool: $1"
  jq -nc --arg r "Grindstone guard: blocked because $1. While Grindstone is on you may only change things inside the project folder ($ROOT). Find a way to do this inside the project. If that isn't possible, add it to 'Blocked / Questions for the user' in your notes and move on to other work." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

guard() {
  local name why p a lang
  tool="$(jq -r '.tool_name // empty' <<<"$INPUT")"
  local ti; ti="$(jq -c '.tool_input // {}' <<<"$INPUT")"
  ROOT="$(get root)"
  [ -z "$ROOT" ] && return

  # Gateway tools (e.g. lean-ctx's ctx_call) run another tool; check the tool they wrap.
  if [[ "$tool" =~ __ctx_call$ ]]; then
    name="$(jq -r '.name // empty' <<<"$ti")"
    tool="${tool%ctx_call}${name##*__}"
    ti="$(jq -c '.arguments // {}' <<<"$ti")"
  fi

  if [ "$ALLOW_REMOTE" != yes ] && [[ "$tool" =~ ^(Artifact|ArtifactData|RemoteTrigger|mcp__claude_ai_.*)$ ]]; then
    deny "$tool publishes to or changes a service outside the project"
  fi

  # Shell commands (Bash, and any tool with a command field such as lean-ctx's ctx_shell).
  p="$(jq -r 'if (.command|type) == "string" then .command else empty end' <<<"$ti")"
  if [ -n "$p" ]; then
    why="$(check_shell "$p" "$(jq -r --arg d "$CWD" '.cwd // $d' <<<"$ti")")"
    [ -n "$why" ] && deny "$why"
  fi

  # Code-running tools (e.g. lean-ctx's ctx_execute).
  if [[ "$tool" =~ __ctx_execute$ ]]; then
    lang="$(jq -r '.language // empty' <<<"$ti")"
    p="$(jq -r '[.code, .items] | map(select(. != null)) | join("\n")' <<<"$ti")"
    if [ "$lang" = shell ]; then
      why="$(check_shell "$p" "$CWD")"
      [ -n "$why" ] && deny "$why"
    else
      while IFS= read -r a; do
        [ -z "$a" ] && continue
        a="$(abspath "$a" "$CWD")"
        can_reference "$a" || deny "the script refers to $a"
      done < <(path_tokens "$p")
    fi
  fi

  # File-changing tools: every path-like argument must be inside the project.
  if [[ "$tool" =~ ^(Write|Edit|MultiEdit|NotebookEdit)$ ]] \
     || [[ "$tool" =~ ^mcp__.*__.*(write|edit|patch|create|delete|remove|move|rename|copy|mkdir|refactor|shell|execute|fill) ]]; then
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      a="$(abspath "$p" "$CWD")"
      can_write "$a" || deny "$tool would change $a"
    done < <(jq -r '[paths(scalars) as $k
                      | select(($k | map(select(type == "string")) | last // "")
                               | test("^(file_path|notebook_path|path|paths|file|files|cwd|dir|directory|target|dest|destination|source|output|output_path)$"; "i"))
                      | getpath($k) | select(type == "string")] | .[]' <<<"$ti")
  fi
}

# ---------------------------------------------------------------- events

case "$1" in
  prompt)
    TEXT="$(jq -r '.prompt_text // .prompt // empty' <<<"$INPUT")"
    CMD_RE='^[[:space:]]*/grindstone(:on|:off|:grindstone)?([[:space:]]|$)'
    [[ "$TEXT" =~ $CMD_RE ]] || exit 0
    VERB="${BASH_REMATCH[1]}"
    TASK="$(sed -E '1s#^[[:space:]]*/grindstone(:on|:off|:grindstone)?[[:space:]]*##' <<<"$TEXT")"
    if [ "$VERB" = :off ] || [[ "$(tr '[:upper:]' '[:lower:]' <<<"$TASK" | xargs)" =~ ^(off|stop|disable)$ ]]; then
      rm -rf "$S"
      log "OFF"
      exit 0
    fi

    ROOT="$(abspath "${CLAUDE_PROJECT_DIR:-$CWD}" /)"
    if [ "$ROOT" = / ] || under "$(abspath "$HOME" /)" "$ROOT"; then
      rm -rf "$S"
      log "REFUSED: project folder is the home folder or above"
      jq -nc --arg c "Grindstone could NOT be turned on: this session's folder ($ROOT) is the home folder or above it, so there's no project folder to keep it inside. Tell the user to open a specific project folder and run /grindstone:on again. Don't start the task." \
        '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
      exit 0
    fi

    NOTES="$ROOT/.claude/grindstone/notes-${SESSION_ID:0:8}.md"
    BASE="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo none)"
    mkdir -p "$S" "$(dirname "$NOTES")"
    echo "$ROOT" >"$S/root"
    echo "$NOTES" >"$S/notes"
    echo "$BASE" >"$S/base"
    echo 0 >"$S/count"; echo 0 >"$S/lens"; echo 0 >"$S/stale"

    if [ -f "$NOTES" ]; then
      STATE="Your notes file already exists. If the task has changed, update the Goal and acceptance criteria and re-plan the Backlog."
    else
      [ -z "$TASK" ] && TASK="(Take this from the conversation and restate it here.)"
      T="$(cat "$TEMPLATE")"
      T="${T//__TASK__/$TASK}"
      T="${T//__STARTED__/$(date '+%Y-%m-%d %H:%M')}"
      T="${T//__BASE__/$BASE}"
      T="${T//__ROOT__/$ROOT}"
      printf '%s\n' "$T" >"$NOTES"
      STATE="A notes file has been created from the template. Fill it in during planning."
    fi
    mtime "$NOTES" >"$S/mtime"
    log "ON (base $BASE)"
    jq -nc --arg c "Grindstone is ON for this session. Project folder: $ROOT (a guard blocks changes outside it). Playbook: $PLAYBOOK. Notes: $NOTES. $STATE" \
      '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
    ;;

  guard)
    [ -d "$S" ] && guard
    ;;

  stop)
    [ -d "$S" ] || exit 0
    NOTES="$(get notes)"; BASE="$(get base none)"
    N=$(( $(get count 0) + 1 )); echo "$N" >"$S/count"
    HEAD="[Grindstone · cycle $N] The user is away, so keep working without asking questions. Follow the playbook at $PLAYBOOK (re-read it if it isn't in your context). Notes: $NOTES."

    # Track how many cycles in a row the notes have gone unchanged.
    M="$(mtime "$NOTES")"
    if [ "$M" = "$(get mtime)" ]; then STALE=$(( $(get stale 0) + 1 )); else STALE=0; fi
    echo "$M" >"$S/mtime"; echo "$STALE" >"$S/stale"

    STATUS="$(grep -m1 -i '^Status:' "$NOTES" 2>/dev/null | sed -E 's/^[Ss][Tt][Aa][Tt][Uu][Ss]:[[:space:]]*//' | tr '[:upper:]' '[:lower:]')"

    if [ ! -f "$NOTES" ]; then
      MODE=init
      MSG="$HEAD Your notes file is missing. Recreate it from $TEMPLATE, rebuilding it from the conversation and git history, then carry on."
    elif [[ "$STATUS" == saturated* ]] || (( N % REVIEW_EVERY == 0 )); then
      L=$(get lens 0); echo $(( (L + 1) % ${#LENSES[@]} )) >"$S/lens"
      LENS="${LENSES[$L]}"
      MODE="review:${LENS%%|*}"
      DIFF=""; [ "$BASE" != none ] && DIFF=" Use \`git diff $BASE\` to see everything Grindstone has changed."
      MSG="$HEAD This is a REVIEW cycle. Lens: ${LENS%%|*}. ${LENS#*|}$DIFF Follow the playbook's review-cycle rules: score that Scorecard area with evidence, add your findings to the Backlog as scored items, re-rank the Backlog, and fix at most one P0/P1 finding."
    else
      MODE=work
      MSG="$HEAD Do one work cycle: orient, choose the highest-value item by the playbook's tiers, do it, verify it with evidence, record it in the notes, and add whatever you discovered to the Backlog."
    fi

    if (( STALE >= 2 )); then
      MSG="$MSG Your notes haven't changed in $STALE cycles. Update Now, Log, Backlog and For the user before you do anything else."
    fi
    log "cycle $N $MODE${STATUS:+ (status: $STATUS)}"
    jq -nc --arg r "$MSG" '{decision: "block", reason: $r}'
    ;;

  failure)
    [ -d "$S" ] || exit 0
    NOTES="$(get notes)"
    TYPE="$(jq -r '.error_type // .error // "unknown"' <<<"$INPUT")"
    WAIT=$RETRY_WAIT
    [ "$TYPE" != "rate_limit" ] && WAIT=$(( RETRY_WAIT < 120 ? RETRY_WAIT : 120 ))
    log "API error ($TYPE), retrying in ${WAIT}s"
    # Sleep in short steps so "/grindstone:off" cancels the pending wake-up.
    END=$(( $(date +%s) + WAIT ))
    while [ "$(date +%s)" -lt "$END" ]; do
      [ -d "$S" ] || { log "turned off while waiting"; exit 0; }
      sleep $(( END - $(date +%s) < 30 ? END - $(date +%s) : 30 ))
    done
    [ -d "$S" ] || exit 0
    log "waking after $TYPE"
    echo "[Grindstone] The previous turn ended with an API error ($TYPE). Resume where you left off: re-read the playbook ($PLAYBOOK) and your notes ($NOTES), check 'Now', verify the state of any half-finished step, then continue." >&2
    exit 2
    ;;

  end)
    rm -rf "$S"
    ;;
esac
exit 0
