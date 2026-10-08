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
git -C "$P" init -q && git -C "$P" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init

pass=0; fail=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "FAIL: $*"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1 (expected '$3', got '$2')"; fi; }

SID=testsession01
event() { jq -nc --arg s "$SID" --arg c "$P" '{session_id: $s, cwd: $c}'; }
send()  { local ev="$1" extra="$2"; event | jq -c ". + $extra" | bash "$H" "$ev"; }

# guard EXPECT TOOL INPUT_JSON
guard() {
  local out got
  out="$(event | jq -c --arg t "$2" --argjson i "$3" '. + {tool_name: $t, tool_input: $i}' | bash "$H" guard)"
  if [ -n "$out" ]; then got=DENY; else got=ALLOW; fi
  check "$got $2 $(jq -r '.command // .file_path // .path // .code // .name // ""' <<<"$3" | head -1)" "$got" "$1"
}
sh() { jq -nc --arg c "$1" '{command: $c}'; }

# ---------------------------------------------------------------- on / off
guard ALLOW Bash "$(sh 'rm -rf ~/elsewhere')"            # nothing enforced before it's on

ctx="$(send prompt '{prompt_text: "/grindstone:on Build a CLI that parses a/b & c files"}' | jq -r .hookSpecificOutput.additionalContext)"
[[ "$ctx" == "Grindstone is ON"* ]] && ok || bad "on: context was: $ctx"
NOTES="$P/.claude/grindstone/notes-${SID:0:8}.md"
[ -f "$NOTES" ] && ok || bad "notes file not created"
grep -q 'Build a CLI that parses a/b & c files' "$NOTES" && ok || bad "task not written into notes"
grep -q "Project folder: $P" "$NOTES" && ok || bad "project folder not written into notes"

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
guard ALLOW Bash "$(sh 'git add -A && git commit -m "fix push handling"')"
guard ALLOW Bash "$(sh 'cat ~/.bashrc | head')"
guard ALLOW Bash "$(sh 'grep -rn foo /usr/include 2>/dev/null')"
guard ALLOW Bash "$(sh '/usr/bin/env node scripts/build.js > dist/out.txt')"
guard ALLOW Bash "$(sh 'echo hi > /tmp/x.log 2>&1')"
guard ALLOW Bash "$(sh 'curl -s https://example.com/api | jq .')"
guard ALLOW Bash "$(sh 'cd src && rm -rf build')"
guard ALLOW Bash "$(sh 'git log --grep=push')"
guard ALLOW Bash "$(jq -nc --arg c "cd \"$P/src\" && make" '{command: $c}')"
guard ALLOW mcp__lean-ctx__ctx_shell "$(jq -nc --arg c "$P" '{command: "npm install lodash", cwd: $c}')"

guard DENY Bash "$(sh 'rm -rf ~/elsewhere')"
guard DENY Bash "$(sh 'rm -rf /')"
guard DENY Bash "$(sh 'cp build/app ~/bin/')"
guard DENY Bash "$(sh 'echo x >> ~/.bashrc')"
guard DENY Bash "$(sh 'cd ~/elsewhere && git reset --hard')"
guard DENY Bash "$(sh 'cd .. && rm -rf *')"
guard DENY Bash "$(sh 'cd && ls')"
guard DENY Bash "$(sh 'git -C ~/elsewhere checkout .')"
guard DENY Bash "$(sh 'make -C ../other install')"
guard DENY Bash "$(sh 'sudo rm x')"
guard DENY Bash "$(sh 'npm install -g typescript')"
guard DENY Bash "$(sh 'brew install ripgrep')"
guard DENY Bash "$(sh 'apt-get install curl')"
guard DENY Bash "$(sh 'git push origin main')"
guard DENY Bash "$(sh 'git -C . push')"
guard DENY Bash "$(sh 'gh pr create --fill')"
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
CLAUDE_PLUGIN_OPTION_EXTRA_ALLOWED_PATHS="~/elsewhere, ~/also-ok" guard ALLOW Bash "$(sh 'rm -rf ~/also-ok/build')"
CLAUDE_PLUGIN_OPTION_EXTRA_ALLOWED_PATHS='["~/elsewhere"]' guard ALLOW Write '{"file_path": "~/elsewhere/x"}'

# other sessions are unaffected
SID=othersession guard ALLOW Bash "$(sh 'rm -rf ~/elsewhere')"

# ---------------------------------------------------------------- cycles
modes=""
for i in 1 2 3 4 5 6; do
  r="$(send stop '{}' | jq -r .reason)"
  case "$r" in *"REVIEW cycle"*) modes+="R" ;; *"work cycle"*) modes+="W" ;; *) modes+="?" ;; esac
done
check "cycle modes" "$modes" "WWWWRW"
[[ "$r" == *"haven't changed in"* ]] && ok || bad "stale-notes nudge missing"
r="$(send stop '{}' | jq -r .reason)"
[[ "$r" == *"[Grindstone · cycle 7]"* ]] && ok || bad "cycle counter: $r"

sed -e 's/^Status: planning/Status: saturated/' "$NOTES" >"$NOTES.new" && mv "$NOTES.new" "$NOTES"
r1="$(send stop '{}' | jq -r .reason)"; r2="$(send stop '{}' | jq -r .reason)"
[[ "$r1" == *"Lens: Correctness"* && "$r2" == *"Lens: Tests"* ]] && ok || bad "saturated lens rotation"
[[ "$r1" != *"haven't changed"* ]] && ok || bad "stale nudge after notes changed"

rm "$NOTES"
[[ "$(send stop '{}' | jq -r .reason)" == *"notes file is missing"* ]] && ok || bad "missing-notes recovery"

# ---------------------------------------------------------------- usage-limit wake
err="$(event | jq -c '. + {error_type: "rate_limit"}' | GRINDSTONE_RETRY_WAIT=2 bash "$H" failure 2>&1 >/dev/null)"
check "failure exit code" "$?" "2"
[[ "$err" == "[Grindstone] The previous turn ended"* ]] && ok || bad "wake message: $err"

# ---------------------------------------------------------------- off
send prompt '{prompt_text: "/grindstone:off"}' >/dev/null
check "stop after off" "$(send stop '{}')" ""
guard ALLOW Bash "$(sh 'git push')"
check "failure after off" "$(event | jq -c '. + {error_type: "rate_limit"}' | GRINDSTONE_RETRY_WAIT=2 bash "$H" failure 2>&1; echo $?)" "0"

# refuses to run from the home folder
ctx="$(jq -nc --arg h "$HOME" '{session_id: "homecase", cwd: $h, prompt_text: "/grindstone:on x"}' \
        | CLAUDE_PROJECT_DIR="$HOME" bash "$H" prompt | jq -r .hookSpecificOutput.additionalContext)"
[[ "$ctx" == *"could NOT be turned on"* ]] && ok || bad "home-folder refusal: $ctx"
[ -z "$(ls -A "$CLAUDE_PLUGIN_DATA/sessions")" ] && ok || bad "session state left behind"

rm -rf "$TMP"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
