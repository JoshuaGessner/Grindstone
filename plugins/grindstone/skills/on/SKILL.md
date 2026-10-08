---
name: on
description: Turn Grindstone on for this session. Claude keeps working on, refining and extending the task without stopping. With no task, it finds valuable work in the project on its own (fixes, health work or planned features). Resumes after usage-limit resets, stays inside the project folder, and runs until you send /grindstone:off.
argument-hint: "[task to work on — or leave empty to let it choose]"
disable-model-invocation: true
---

Task: $ARGUMENTS

If the context for this turn says Grindstone could NOT be turned on, tell the user why in one or two sentences and stop. Don't start any work.

Otherwise, Grindstone is now ON for this session and the user has stepped away. Hooks will start your next cycle each time you finish a turn, and will wake you again after a usage limit resets. The context for this turn gives you the mode, the project folder, the playbook and notes paths, and, when no task was given, a survey of the project.

Run the **planning cycle** from the playbook (${CLAUDE_PLUGIN_ROOT}/PLAYBOOK.md):

1. Read the playbook in full.
2. Work out the Goal from the mode:
   - **Task given:** plan that task.
   - **No task:** continue the conversation's task if there is a clear one. Otherwise use **Discovery mode** to choose a mission, which can be fixes, health work or a planned feature.
3. Learn how to build, test and run the project, and get a test baseline.
4. Fill in acceptance criteria, Scorecard and a scored Backlog. Write feature plans for any features.
5. Set `Status: working`, write **For the user**, commit if this is a git repo, and start on the top Backlog item.

If Discovery finds nothing valid to work on, for example in an empty folder, set `Status: idle — <reason>`, tell the user briefly, and stop.
