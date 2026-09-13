# SETUP.md — what only you can do

Cursor can write, and once it's running on your actual Mac, build and test
this code against real compiler errors — something I couldn't do writing
it in a sandbox. But a chunk of this project needs you specifically, not
an agent.

## Before writing any more code

1. Install Xcode + Command Line Tools (`xcode-select --install`), confirm
   `swift --version` works in Terminal.
2. `git init` this project, push to a GitHub repo. Cursor works better
   with real git history (it can diff, you get the included CI workflow
   for free, and you have a rollback point before letting an agent loose).
3. Open the folder in Cursor. If it doesn't pick up `AGENTS.md`
   automatically, say "read AGENTS.md and everything in docs/ before
   starting" as your first message.
4. Decide a bundle identifier (`com.yourname.diskmap`) and app name —
   Cursor can brainstorm names with you, but this is your call, and it's
   threaded through Info.plist, entitlements, and leftover-matching logic
   later.

## Things that need your hands, not Cursor's

- **Watch the first few `swift test` / `swift run` yourself.** Once you
  know what "working" looks like, letting Cursor's agent run these
  autonomously is fine.
- **Granting Full Disk Access during development** — System Settings →
  Privacy & Security → Full Disk Access → add your built app or Terminal.
  Apple requires a human click here; nothing scripts around it.
- **Testing the clone detector for real.** `cp -c original.bin clone.bin`
  on an APFS volume, confirm the app flags them as clones. TASK-005.
- **Judging false positives in the app-leftover finder.** Uninstall a real
  (or disposable test) app, eyeball the staged leftover list, tune the
  matching by feel. This is taste, not something to fully hand off.
- **Apple Developer Program ($99/yr)** — needed once you want to notarize
  and distribute outside your own Mac. A free Apple ID covers local dev.
- **Design calls**: icon, color scheme, which of the 8 views to ship first
  if you want to launch before all of them exist.
- **Reading the diff yourself, every time**, for anything touching
  `CleanupQueue.swift`, `CloneDetector.swift`, or the excluded-paths list.
  These are the three places a bug has real consequences.

## Good Cursor habits for this project

- Work one `TASKS.md` ticket at a time. Paste its prompt, let it finish,
  run tests, review the diff, commit, move on. "Build the whole app" in
  one prompt produces a diff nobody — including Cursor, later — can debug.
- Agent/Composer mode for anything touching more than one file; inline
  chat/edit for single-file fixes.
- After a session, ask Cursor to check off the `TASKS.md` line it finished
  and update any `UNVERIFIED` comment it resolved — keeps the docs honest
  as the actual source of truth for where the project stands.
