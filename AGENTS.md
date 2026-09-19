# Repository agent guide

This repository (`pixel-backup-gang`) holds legacy Pixel/Android SSD shell
tooling in its root. It is not a monorepo: the macOS Takeout application
lives in a separate, independent sibling repository at
`../takeout-metadata-repair` (its own git history, not a subdirectory here).
The two are related only thematically — both deal with Google Photos/Pixel
data — and share no code.

For Takeout work, switch to that sibling repository and read and follow its
own `AGENTS.md`. Do not modify this repository's legacy shell tooling while
working on the Takeout application, and do not modify Takeout files from
here; cross-repository changes need the user's explicit instruction.

Preserve unrelated and pre-existing working-tree changes. Never use destructive
Git cleanup to make the repository appear clean.
