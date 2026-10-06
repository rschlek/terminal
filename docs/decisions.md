# Decisions

Newest first. Each entry: the date, what was decided, and why.

## 2026-10-05 - The agent menu refreshes its own installed copy

Setup writes `plugin-source.txt` next to the installed menu (plugin folder,
name, version). At start the installed menu compares that version with the
manifest of the recorded folder and, when the folder is named after its
version, of its sibling version folders, and copies the newest newer one's
scripts over itself, then runs them. Why: plugin caches install each version
in a new folder and leave the installed menu copy alone, so a menu installed
once never saw a fix until setup ran again; checking only the recorded folder
would never see the new version folder. Comparing versions numerically and
checking the manifest's name keeps it to newer copies of the same plugin. Any
failure falls back to running the menu as it is, silently, and `agents.yaml` is
never touched.

## 2026-10-05 - The session list is a per-block `session_list` key

A block's `session_list: claude` makes Resume list past chats from every
folder, read from Claude Code's session store; `off` keeps the agent's own
resume command. With no key a block named `claude` gets `claude` and every
other block `off`. Why: Claude Code's own picker only lists the chats of the
folder it opens in, while Codex lists every folder itself; the key names the
store format rather than the agent, so a renamed or second Claude block can opt
in, and existing configs need no change.

## 2026-10-05 - Enter reopens a chat where it started; Tab picks another folder

In the session list Enter changes to the chat's original folder (the first
working folder recorded in its file) and runs the `resume` line plus the
session id; Tab opens the project view to choose another folder. Why: Tab is
the project view's existing alternate-action key, and Claude Code reopens a
chat from any folder with its context intact, so a different folder is a valid
choice.

## 2026-10-05 - The launcher's start folder is `-StartIn`

`new-warp-chat.ps1 -StartIn <dir>` prepends a quoted
`Set-Location -LiteralPath ... -ErrorAction Stop` to the tab command, and
breakout uses it to open a chat in another project for both CLIs. Why: only
Codex takes a folder flag, and a folder change in the tab works for any
command and leaves the user in that folder when the CLI exits.
