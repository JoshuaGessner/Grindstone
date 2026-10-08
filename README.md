# Grindstone

**Keep Claude working until you tell it to stop.**

Give Claude Code a task, turn Grindstone on, and walk away. Claude works through the task, checks its own work, then keeps refining: tests, edge cases, error handling, polish. You don't have to type "continue". If you hit your usage limit, Grindstone waits for the reset and picks up where it left off. A guard keeps everything it does inside your project folder.

```
/grindstone:on add CSV export to the reports page, with tests
```

…and in the morning, read the summary at the top of `.claude/grindstone/notes-*.md`.

## Install

Grindstone installs through Claude Code's built-in plugin manager, the same way you'd install any Claude Code plugin. Choose where you use Claude Code:

### VS Code, Cursor or Windsurf

1. In the Claude Code panel, type **`/plugins`** and press Enter. The **Manage plugins** window opens.
2. Go to the **Marketplaces** tab. Paste **`JoshuaGessner/Grindstone`** and click **Add**.
3. Go to the **Plugins** tab, find **Grindstone** and click **Install**.
4. Choose **Install for you** so it works in all your projects.

It's ready straight away, with no restart.

**VS Code shortcut:** paste this link into your browser's address bar. It opens VS Code straight to Grindstone's install screen:

```text
vscode://anthropic.claude-code/install-plugin?plugin=grindstone&marketplace=JoshuaGessner/Grindstone
```

### Terminal

Paste this into a Claude Code session:

```
/plugin install grindstone --marketplace JoshuaGessner/Grindstone
```

Confirm adding the marketplace, then choose **Install for you**. On Claude Code versions older than 2.1.275, run these two commands instead:

```
/plugin marketplace add JoshuaGessner/Grindstone
/plugin install grindstone@grindstone
```

### Desktop app (Code tab)

1. Add the marketplace once by running `/plugin marketplace add JoshuaGessner/Grindstone` in a session.
2. Click **+** next to the prompt box, then **Plugins**, then **Add plugin**.
3. Select **Grindstone** and choose **your user account**.

### Check it worked

Type `/grindstone` in a chat. You should see `/grindstone:on` and `/grindstone:off` in the menu.

### Requirements

macOS or Linux (on Windows, use WSL), with `bash` and [`jq`](https://jqlang.org). `jq` ships with macOS 15 and later. Otherwise install it with `brew install jq`, `sudo apt install jq` or `sudo dnf install jq`. If `jq` is missing, Grindstone tells you instead of starting.

### Updates

Claude Code doesn't update plugins from community marketplaces like this one unless you ask it to, or turn on auto-update. Check the [releases page](https://github.com/JoshuaGessner/Grindstone/releases) for what's new.

**Update now**

- **VS Code, Cursor, Windsurf or the desktop app:** paste this into any Claude chat:
  > Run `claude plugin update grindstone@grindstone`
- **Terminal:** run `/plugin`, open the **Installed** tab, select Grindstone and choose **Update now**.

Then start a new chat, or run `/reload-plugins`, to load the new version.

**Update automatically**

- **VS Code, Cursor, Windsurf or the desktop app:** paste this into any Claude chat:
  > In ~/.claude/settings.json, set `"autoUpdate": true` on the `grindstone` entry under `extraKnownMarketplaces`

  Use a chat where Grindstone is off. Its guard blocks changes outside the project folder.
- **Terminal:** run `/plugin`, open the **Marketplaces** tab, select **grindstone** and choose **Enable auto-update**.

With auto-update on, Claude Code checks for a new version in the background a few minutes after you start a chat. The new version loads in your next chat.

## Use

| Type this | What happens |
|---|---|
| `/grindstone:on <task>` | Turns Grindstone on for **this chat** and starts the task |
| `/grindstone:on` | Turns it on without a task. It continues this chat's task if there is one. Otherwise it surveys the project and chooses valuable work by itself: fixes, health work or new features |
| `/grindstone:off` | Turns it off. Claude goes back to stopping after each reply |

- Each chat is separate. Turning it on in one chat doesn't affect your others.
- The stop button pauses the current turn, but Grindstone stays on until you run `/grindstone:off` or close the chat.
- **Use auto mode (or accept-edits mode) in that chat.** If Claude stops to ask permission while you're away, nobody is there to answer.
- Leave your computer awake and the chat open. Grindstone runs inside your Claude Code session.
- If the project is a git repo, Claude commits after each step, so you can review or undo everything later.

## How it works

**Notes.** Turning Grindstone on creates `.claude/grindstone/notes-<id>.md` in your project. This file is Claude's memory between cycles, after context compaction, and across usage-limit pauses. It holds:

- **For the user:** a plain-language summary rewritten every cycle. Read this first.
- **Goal** and checkable **acceptance criteria**.
- **Now:** the one item in progress.
- **Backlog:** a scored to-do list.
- **Scorecard:** a 1-5 rating for correctness, tests, UX, code quality, security, performance and docs, with evidence.
- **Decisions**, **Project facts** (build and test commands), **Questions for the user**, a **Won't do** list, and a **Log** with proof for each step.

**Choosing work.** Claude follows [`PLAYBOOK.md`](plugins/grindstone/PLAYBOOK.md):

1. **Broken things first.** Failing builds or tests, crashes.
2. **The goal.** Acceptance criteria that aren't met yet.
3. **Trust.** Untested critical paths and unhandled errors.
4. **Polish.** The lowest-scoring Scorecard area.
5. **Stretch work.** Only once everything scores 4 or higher, and only next to the goal.

Within a tier it picks the highest *impact × confidence ÷ effort*. Rules against churn stop it from re-polishing the same code, reversing its own decisions without new evidence, or drifting out of scope. Nothing counts as done without evidence.

**No task? It finds its own.** Run `/grindstone:on` on its own in a fresh chat and Grindstone surveys the project. It looks at unfinished work from earlier Grindstone sessions, failing tests, roadmap and TODO files, open GitHub issues (read-only), TODO/FIXME comments, and features the README promises but the code doesn't have. It picks one well-defined *mission*, works it to completion, then looks for the next. Decisions that belong to you go to "Questions for the user" instead of into the code: rewrites, breaking API changes, removing features, major upgrades, anything involving money, auth or licensing.

**Planning and building features.** Before building a feature, Claude writes a plan in the notes: the problem it solves and where the idea came from, scope, design, milestones, acceptance criteria and risks. It then builds one tested, committed milestone at a time. A *Product & features* review regularly looks for the next most valuable capability, so new features compete with fixes and polish on value.

**Your work in progress is safe.** Files you'd changed but not committed when Grindstone started are recorded, and Grindstone won't edit, revert or commit them. It stages its own files by name, and the guard blocks commands that throw work away, such as `git reset --hard`, `git clean -f`, `git checkout .` and `git stash drop`.

**Review cycles.** Every 5th cycle, Claude steps back and reviews the whole project through one lens. The lenses rotate: a fresh-eyes check of the diff against the goal, edge cases, product & features, tests, UX, code quality, security, performance, docs. Findings go into the backlog. When nothing valuable is left, it marks the notes `saturated`. With a task, every cycle then becomes a review so it goes deeper instead of making small changes in circles. Without a task, it picks its next mission.

**Turning itself off.** Grindstone won't burn your quota on nothing. If it finds nothing valid to do, such as in an empty folder or when everything left needs your decision, it writes you a summary and switches itself off. It also notices when it's stuck. After 4 cycles with no progress (no notes update and no commit) it's told to change approach. After 8 it pauses itself.

**Usage limits.** When a turn fails on a usage or rate limit, Grindstone retries every 15 minutes until your limit resets. Failed retries don't use quota. On the first retry that succeeds, Claude re-reads its notes and continues.

## Safety guard

While Grindstone is on in a chat, a guard checks every tool call. It blocks:

- **File edits outside the project folder.** That covers Claude's own edit tools and MCP file tools. Symlinks and `..` are resolved first.
- **Shell commands that could change things outside the project.** For example: writing to an outside file, `cd ~/other && …`, `git -C`/`make -C` elsewhere, or `rm`/`cp`/`mv`/`sed -i`/`find -delete` on an outside path.
- **System-wide changes.** `sudo`, global installs (`npm -g`, `brew`, `apt`, `cargo`/`go install`, `pip --user`), `launchctl`, `systemctl`, `crontab`.
- **Anything that changes something remote.** `git push`, creating or commenting on issues and PRs, releases, `gh api` writes, `npm publish`, and publishing through claude.ai connectors. You can turn this on in settings.
- **Throwing work away.** `git reset --hard`, `git clean -f`, `git checkout .`, `git restore .`, `git stash drop`/`clear`, `git branch -D`.

Reading anything is still allowed, including GitHub issues and PRs (`gh issue list`, `gh pr view`). So are `/tmp` and installing dependencies into the project. Grindstone also won't start if the chat's folder is your home folder or above it.

When the guard blocks something, Claude is told why. It records what it needed under "Questions for the user" and moves on.

> **Limits of the guard:** the shell checks read the command text. They're a strong safety net, not an OS-level sandbox. They can't see inside scripts your project runs (for example, `npm run x` executing code that writes elsewhere), and they can't see paths hidden in other variables. Use version control and review the work.

## Settings

Open `/config` in Claude Code, or select Grindstone on the **Installed** tab of `/plugins` and choose **Configure options**. The options are:

| Setting | Default | |
|---|---|---|
| Retry interval after a usage limit | 15 min | How often to retry while limited |
| Review every N cycles | 5 | How often a review cycle happens |
| Allow pushing and publishing | off | Allow `git push`, PRs and publishing |
| Extra folders it may change | (empty) | Comma-separated, e.g. `~/code/shared-lib` |

## Privacy

Grindstone is a set of local shell hooks and Markdown instructions. It makes no network requests and collects no telemetry. Everything it stores stays on your machine:

- Session state and an activity log, in Claude Code's plugin data folder (`~/.claude/plugins/data/grindstone-…/`). Claude Code removes this folder when you uninstall.
- Your notes, in your project's `.claude/grindstone/` folder. Commit them or add them to `.gitignore`, your choice.

## Uninstall

Open `/plugins` (or `/plugin` in the terminal), select Grindstone on the **Installed** tab, and choose **Uninstall**. Or run:

```
/plugin uninstall grindstone@grindstone
```

## Development

```
bash tests/run.sh        # runs the hook against simulated events; touches nothing outside tests/.tmp
claude --plugin-dir plugins/grindstone    # try local changes
claude plugin validate .
```

## License

MIT
