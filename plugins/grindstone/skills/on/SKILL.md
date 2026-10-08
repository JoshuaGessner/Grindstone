---
name: on
description: Turn Grindstone on for this session. Claude keeps working on and refining the task without stopping, resumes after usage-limit resets, stays inside the project folder, and runs until you send /grindstone:off.
argument-hint: "[task to work on]"
disable-model-invocation: true
---

Task: $ARGUMENTS

If the context for this turn says Grindstone could NOT be turned on, tell the user why in one or two sentences and stop. Don't start the task.

Otherwise, Grindstone is now ON for this session and the user has stepped away. Hooks will start your next cycle each time you finish a turn, and will wake you again after a usage limit resets. The project folder, playbook path and notes path are in the context for this turn.

Start with a **planning cycle**:

1. Read the playbook (${CLAUDE_PLUGIN_ROOT}/PLAYBOOK.md) in full.
2. Understand the task (above, or the conversation so far if it's empty) and the codebase. Find out how to build, test and run the project, and record that under Project facts.
3. In the notes, write concrete, checkable **acceptance criteria**. Fill in a baseline **Scorecard** (use "?" for areas you haven't looked at yet). Seed the **Backlog** with scored items, starting with the ones that cover the acceptance criteria.
4. Set `Status: working`, write a first **For the user** summary, and commit if this is a git repo.
5. Start on the top Backlog item.
