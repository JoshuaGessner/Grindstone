#!/usr/bin/env bash
# Grindstone test suite. Runs the hook script against simulated Claude Code
# events; touches nothing outside tests/.tmp/. Usage: bash tests/run.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
H="$REPO/plugins/grindstone/scripts/grindstone-hook.sh"
TMP="$REPO/tests/.tmp"
P="$TMP/my project"            # a space in the name on purpose
export CLAUDE_PLUGIN_ROOT="$REPO/plugins/grindstone"
export CLAUDE_PLUGIN_DATA="$TMP/data"
export CLAUDE_PROJECT_DIR="$P"
unset CLAUDE_PLUGIN_OPTION_ALLOW_REMOTE CLAUDE_PLUGIN_OPTION_EXTRA_ALLOWED_PATHS

rm -rf "$TMP"; mkdir -p "$P/src"
gitp() { git -C "$P" -c user.name=t -c user.email=t@example.com "$@"; }
gitp init -q && gitp commit -q --allow-empty -m init

pass=0; fail=0
ok()    { pass=$((pass + 1)); }
bad()   { fail=$((fail + 1)); echo "FAIL: $*"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1 (expected '$3', got '$2')"; fi; }
has()   { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1: '$3' not in: ${2:0:300}"; fi; }
hasnt() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1: '$3' unexpectedly in: ${2:0:300}"; fi; }

SID=testsession01
TRANSCRIPT=""
event() { jq -nc --arg s "$SID" --arg c "$P" --arg t "$TRANSCRIPT" '{session_id: $s, cwd: $c, transcript_path: $t}'; }
send()  { event | jq -c ". + $2" | bash "$H" "$1"; }
enable() { send prompt "$(jq -nc --arg p "$1" '{prompt_text: $p}')" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
stop()  { send stop '{}'; }
notes() { echo "$P/.claude/grindstone/notes-${SID:0:8}.md"; }
T=203001010000
touch_notes() { T=$((T + 1)); touch -m -t "$T" "$(notes)"; }

# guard EXPECT TOOL INPUT_JSON
guard() {
  local out got
  out="$(event | jq -c --arg t "$2" --argjson i "$3" '. + {tool_name: $t, tool_input: $i}' | bash "$H" guard)"
  if [ -n "$out" ]; then got=DENY; else got=ALLOW; fi
  check "$got $2 $(jq -r '.command // .file_path // .path // .code // .name // ""' <<<"$3" | head -1)" "$got" "$1"
}
sh() { jq -nc --arg c "$1" '{command: $c}'; }

# ================================================================ task mode
guard ALLOW Bash "$(sh 'rm -rf ~/elsewhere')"            # nothing enforced before it's on

ctx="$(enable "/grindstone:on Build a CLI that parses a/b & c files, don't skip tests")"
has "on: context" "$ctx" "Grindstone is ON"
has "on: task mode" "$ctx" "Mode: Task given"
hasnt "on: no survey in task mode" "$ctx" "Project survey"
[ -f "$(notes)" ] && ok || bad "notes file not created"
has "task written into notes" "$(cat "$(notes)")" "Build a CLI that parses a/b & c files, don't skip tests"
has "project folder in notes" "$(cat "$(notes)")" "Project folder: $P"
has "no pre-existing changes" "$(cat "$(notes)")" "None."

# ---------------------------------------------------------------- guard
guard ALLOW Write "$(jq -nc --arg p "$P/src/a.ts" '{file_path: $p}')"
guard ALLOW Edit '{"file_path": "src/a.ts"}'
guard ALLOW Write '{"file_path": "/tmp/scratch.txt"}'
guard ALLOW Read "$(jq -nc --arg p "$HOME/.bashrc" '{file_path: $p}')"
guard DENY  Write "$(jq -nc --arg p "$HOME/.bashrc" '{file_path: $p}')"
guard DENY  Edit "$(jq -nc --arg p "$P/../outside.ts" '{file_path: $p}')"
guard DENY  Write '{"file_path": "~/elsewhere/x"}'
guard DENY  mcp__fs__write_file "$(jq -nc --arg p "$HOME/x" '{path: $p}')"
guard ALLOW mcp__fs__write_file "$(jq -nc --arg p "$P/x" '{path: $p}')"
guard DENY  mcp__lean-ctx__ctx_patch "$(jq -nc --arg p "$HOME/x.ts" '{ops: [{path: $p}]}')"
guard DENY  mcp__lean-ctx__ctx_call "$(jq -nc --arg p "$HOME/.bashrc" '{name: "ctx_edit", arguments: {path: $p}}')"
guard DENY  Artifact '{"file_path": "x.html"}'

guard ALLOW Bash "$(sh 'npm test && npm run build')"
guard ALLOW Bash "$(sh 'git add src/a.ts && git commit -m "fix push handling"')"
guard ALLOW Bash "$(sh 'cat ~/.bashrc | head')"
guard ALLOW Bash "$(sh 'grep -rn foo /usr/include 2>/dev/null')"
guard ALLOW Bash "$(sh '/usr/bin/env node scripts/build.js > dist/out.txt')"
guard ALLOW Bash "$(sh 'echo hi > /tmp/x.log 2>&1')"
guard ALLOW Bash "$(sh 'curl -s https://example.com/api | jq .')"
guard ALLOW Bash "$(sh 'cd src && rm -rf build')"
guard ALLOW Bash "$(sh 'git log --grep=push')"
guard ALLOW Bash "$(jq -nc --arg c "cd \"$P/src\" && make" '{command: $c}')"
guard ALLOW mcp__lean-ctx__ctx_shell "$(jq -nc --arg c "$P" '{command: "npm install lodash", cwd: $c}')"
guard ALLOW Bash "$(sh 'gh issue list --state open --limit 50')"
guard ALLOW Bash "$(sh 'gh issue view 12 --comments')"
guard ALLOW Bash "$(sh 'gh pr list && gh pr view 3')"
guard ALLOW Bash "$(sh 'gh api repos/o/r/issues')"
guard ALLOW Bash "$(sh 'git checkout -b feature/export')"
guard ALLOW Bash "$(sh 'git stash && git stash pop')"
guard ALLOW Bash "$(sh 'git revert --no-edit HEAD')"
guard ALLOW Bash "$(sh 'git restore src/a.ts')"

guard DENY Bash "$(sh 'rm -rf ~/elsewhere')"
guard DENY Bash "$(sh 'rm -rf /')"
guard DENY Bash "$(sh 'cp build/app ~/bin/')"
guard DENY Bash "$(sh 'echo x >> ~/.bashrc')"
guard DENY Bash "$(sh 'cd ~/elsewhere && ls')"
guard DENY Bash "$(sh 'cd .. && rm -rf *')"
guard DENY Bash "$(sh 'cd && ls')"
guard DENY Bash "$(sh 'git -C ~/elsewhere checkout main')"
guard DENY Bash "$(sh 'make -C ../other install')"
guard DENY Bash "$(sh 'sudo rm x')"
guard DENY Bash "$(sh 'npm install -g typescript')"
guard DENY Bash "$(sh 'brew install ripgrep')"
guard DENY Bash "$(sh 'apt-get install curl')"
guard DENY Bash "$(sh 'git push origin main')"
guard DENY Bash "$(sh 'git -C . push')"
guard DENY Bash "$(sh 'gh pr create --fill')"
guard DENY Bash "$(sh 'gh issue create --title x --body y')"
guard DENY Bash "$(sh 'gh issue comment 12 --body done')"
guard DENY Bash "$(sh 'gh api -X POST repos/o/r/issues')"
guard DENY Bash "$(sh 'gh api repos/o/r/issues -f title=x')"
guard DENY Bash "$(sh 'gh auth token')"
guard DENY Bash "$(sh 'git reset --hard HEAD~1')"
guard DENY Bash "$(sh 'git clean -fdx')"
guard DENY Bash "$(sh 'git checkout -- .')"
guard DENY Bash "$(sh 'git restore .')"
guard DENY Bash "$(sh 'git stash drop')"
guard DENY Bash "$(sh 'git branch -D old')"
guard DENY Bash "$(sh 'find ~/Documents -name "*.tmp" -delete')"
guard DENY Bash "$(sh 'sed -i "" s/a/b/ ~/.bashrc')"
guard DENY Bash "$(sh 'python3 -c "open(\"$HOME/x\",\"w\")"')"
guard DENY Bash "$(sh 'ls ~/elsewhere | xargs rm')"
guard DENY Bash "$(sh 'mv src $HOME/backup')"
guard DENY mcp__lean-ctx__ctx_shell "$(jq -nc --arg c "$HOME/elsewhere" '{command: "rm -rf build", cwd: $c}')"
guard DENY mcp__lean-ctx__ctx_execute "$(jq -nc --arg p "$HOME/notes.txt" '{language: "python", code: ("open(\"" + $p + "\",\"w\")")}')"
guard DENY mcp__lean-ctx__ctx_call '{"name": "ctx_shell", "arguments": {"command": "git push"}}'

# settings
CLAUDE_PLUGIN_OPTION_ALLOW_REMOTE=true guard ALLOW Bash "$(sh 'git push origin main')"
CLAUDE_PLUGIN_OPTION_ALLOW_REMOTE=true guard ALLOW Bash "$(sh 'gh issue comment 12 --body done')"
CLAUDE_PLUGIN_OPTION_EXTRA_ALLOWED_PATHS="~/elsewhere, ~/also-ok" guard ALLOW Bash "$(sh 'rm -rf ~/also-ok/build')"
CLAUDE_PLUGIN_OPTION_EXTRA_ALLOWED_PATHS='["~/elsewhere"]' guard ALLOW Write '{"file_path": "~/elsewhere/x"}'

# other sessions are unaffected
SID=othersession guard ALLOW Bash "$(sh 'rm -rf ~/elsewhere')"

# ---------------------------------------------------------------- cycles
modes=""
for i in 1 2 3 4 5 6; do
  touch_notes
  r="$(stop | jq -r .reason)"
  case "$r" in *"REVIEW cycle"*) modes+="R" ;; *"work cycle"*) modes+="W" ;; *) modes+="?" ;; esac
done
check "cycle modes" "$modes" "WWWWRW"
has "work prompt mentions features" "$r" "planned feature"
hasnt "no stale nudge while notes change" "$r" "haven't changed"

r="$(stop | jq -r .reason)"; r="$(stop | jq -r .reason)"
has "stale nudge after 2 quiet cycles" "$r" "haven't changed in 2"
r="$(stop | jq -r .reason)"; r="$(stop | jq -r .reason)"
has "stuck nudge after 4 quiet cycles" "$r" "no recorded progress"
echo x >"$P/src/b.txt"; gitp add src/b.txt; gitp commit -q -m b
r="$(stop | jq -r .reason)"
hasnt "a commit counts as progress" "$r" "no recorded progress"
for i in 1 2 3 4 5 6 7; do stop >/dev/null; done
out="$(stop)"
has "pauses after 8 quiet cycles" "$(jq -r .systemMessage <<<"$out")" "paused itself"
check "pause clears state" "$(ls -A "$CLAUDE_PLUGIN_DATA/sessions")" ""
check "nothing after pause" "$(stop)" ""

# saturated, task mode: rotating lenses including Product & features
enable "/grindstone:on Build a CLI" >/dev/null
sed -e 's/^Status: planning/Status: saturated/' "$(notes)" >"$(notes).new" && mv "$(notes).new" "$(notes)"
touch_notes; r1="$(stop | jq -r .reason)"; touch_notes; r2="$(stop | jq -r .reason)"
has "saturated lens 1" "$r1" "Lens: Fresh-eyes"
has "saturated lens 2" "$r2" "Lens: Correctness"
touch_notes; r3="$(stop | jq -r .reason)"
has "product lens" "$r3" "Lens: Product & features"
has "product lens asks for feature plans" "$r3" "feature plans"

# idle: turns itself off
sed -e 's/^Status: saturated/Status: idle — everything left needs a human decision/' "$(notes)" >"$(notes).new" && mv "$(notes).new" "$(notes)"
out="$(stop)"
check "idle lets the turn end" "$(jq -r '.decision // "none"' <<<"$out")" "none"
has "idle message" "$(jq -r .systemMessage <<<"$out")" "turned itself off: idle — everything left needs a human decision"
check "idle clears state" "$(ls -A "$CLAUDE_PLUGIN_DATA/sessions")" ""

rm "$(notes)"
enable "/grindstone:on x" >/dev/null; rm "$(notes)"
has "missing-notes recovery" "$(stop | jq -r .reason)" "notes file is missing"

# ---------------------------------------------------------------- usage-limit wake
err="$(event | jq -c '. + {error_type: "rate_limit"}' | GRINDSTONE_RETRY_WAIT=2 bash "$H" failure 2>&1 >/dev/null)"
check "failure exit code" "$?" "2"
has "wake message" "$err" "[Grindstone] The previous turn ended"

# ---------------------------------------------------------------- off
send prompt '{prompt_text: "/grindstone:off"}' >/dev/null
check "stop after off" "$(stop)" ""
guard ALLOW Bash "$(sh 'git push')"
check "failure after off" "$(event | jq -c '. + {error_type: "rate_limit"}' | GRINDSTONE_RETRY_WAIT=2 bash "$H" failure 2>&1; echo $?)" "0"

# ================================================================ discovery mode
SID=discover0001
printf '# Roadmap\n- [ ] CSV export\n' >"$P/ROADMAP.md"
printf 'function f() {\n  // TODO: handle empty input\n  // FIXME: off by one\n}\n' >"$P/src/a.js"
printf '{"scripts": {"test": "jest", "build": "tsc", "lint": "eslint ."}}\n' >"$P/package.json"
printf '# Rules\n' >"$P/CLAUDE.md"
gitp add -A && gitp commit -q -m "project files"
printf 'Status: working\n## Backlog\n| P | Item |\n|---|---|\n| P1 | finish parser | \n| P3 | docs |\n' >"$P/.claude/grindstone/notes-oldsess1.md"
echo "user's half-done work" >>"$P/src/a.js"          # uncommitted user work
echo "new" >"$P/src/draft.js"
ctx="$(enable "/grindstone:on")"
has "discover: mode" "$ctx" "Self-directed (Discovery mode)"
has "discover: survey" "$ctx" "Project survey:"
has "discover: earlier notes" "$ctx" ".claude/grindstone/notes-oldsess1.md: working, 2 backlog items"
has "discover: roadmap" "$ctx" "ROADMAP.md"
has "discover: conventions" "$ctx" "CLAUDE.md"
has "discover: npm scripts" "$ctx" "npm scripts: build, lint, test"
has "discover: TODO markers" "$ctx" "src/a.js:2"
has "discover: pre-existing warning" "$ctx" "don't edit, revert or commit those files"
NOTES_TEXT="$(cat "$(notes)")"
has "discover: mode in notes" "$NOTES_TEXT" "Mode: Self-directed (Discovery mode)"
has "discover: dirty file in notes" "$NOTES_TEXT" 'src/a.js'
has "discover: untracked file in notes" "$NOTES_TEXT" 'src/draft.js'

# saturated in discovery mode: pick the next mission instead of reviewing forever
sed -e 's/^Status: planning/Status: saturated/' "$(notes)" >"$(notes).new" && mv "$(notes).new" "$(notes)"
touch_notes
has "discover: next mission" "$(stop | jq -r .reason)" "Run Discovery mode again"
send prompt '{prompt_text: "/grindstone:off"}' >/dev/null

# conversation mode: no task, but the chat has earlier messages
SID=convo0000001
TRANSCRIPT="$TMP/transcript.jsonl"
{
  jq -nc '{type: "user", message: {role: "user", content: "Add dark mode to the settings page"}}'
  jq -nc '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: "Sure"}]}}'
} >"$TRANSCRIPT"
has "conversation mode" "$(enable "/grindstone:on")" "Continuing the conversation's task"
send prompt '{prompt_text: "/grindstone:off"}' >/dev/null

# a transcript holding only the command itself counts as no conversation
SID=convo0000002
jq -nc '{type: "user", message: {role: "user", content: "<command-name>/grindstone:on</command-name>"}}' >"$TRANSCRIPT"
has "command-only transcript = discovery" "$(enable "/grindstone:on")" "Discovery mode"
send prompt '{prompt_text: "/grindstone:off"}' >/dev/null
TRANSCRIPT=""

# an empty project folder
SID=empty0000001
E="$TMP/empty project"; mkdir -p "$E"
ctx="$(event | jq -c --arg c "$E" '. + {cwd: $c, prompt_text: "/grindstone:on"}' | CLAUDE_PROJECT_DIR="$E" bash "$H" prompt | jq -r .hookSpecificOutput.additionalContext)"
has "empty folder survey" "$ctx" "The project folder is empty"
has "empty folder not a repo" "$ctx" "Self-directed"
send prompt '{prompt_text: "/grindstone:off"}' >/dev/null

# refuses to run from the home folder
ctx="$(jq -nc --arg h "$HOME" '{session_id: "homecase", cwd: $h, prompt_text: "/grindstone:on x"}' \
        | CLAUDE_PROJECT_DIR="$HOME" bash "$H" prompt | jq -r .hookSpecificOutput.additionalContext)"
has "home-folder refusal" "$ctx" "could NOT be turned on"
check "no session state left behind" "$(ls -A "$CLAUDE_PLUGIN_DATA/sessions")" ""

rm -rf "$TMP"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
