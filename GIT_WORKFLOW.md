# Git & gh Workflow — `test-terraform`

How to work on this repo from **any** machine without flattening `week-2/` into the
repo root or clobbering `origin/main`. Read this once before touching git on a new box.

Remote: `https://github.com/leeclay95/test-terraform.git` — default branch `main`.

---

## 1. The one thing that went wrong before

The repo has files at the **root** *and* a `week-2/` subfolder:

```
test-terraform/            <-- REPO ROOT (this is the git repo)
├── .gitignore
├── README.md              <-- root-level files, NOT part of week-2
├── s3.tf
├── outputs.tf
├── verify.sh
├── evidence/
└── week-2/                <-- a SUBFOLDER, not its own repo
    ├── README.md
    ├── WALKTHROUGH.md
    ├── GAPS.md
    ├── generated.tf
    ├── hardening.tf
    ├── import.tf
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    ├── verify.sh
    ├── scripts/
    ├── previous/
    └── evidence/
```

The break happened because on the other machine, `week-2/` was treated as if it were
the whole project. Files got moved up to the root (`week-2/generated.tf` → `generated.tf`),
`README.md`/`WALKTHROUGH.md` were deleted, it was committed as "testing", and
**force-pushed**. That rewrote `origin/main` into a flat, README-less mess.

**Git records every path relative to the repo root.** If you move a file, git records a
move. If you commit from a directory that looks like the root but isn't, you restructure
the whole repo. The rules below make that impossible to do by accident.

---

## 2. One-time setup on a new machine

Clone the **whole repo** — never copy just the `week-2/` folder onto a new box and
`git init` inside it.

```bash
git clone https://github.com/leeclay95/test-terraform.git
cd test-terraform
```

Confirm you cloned the real thing (you should see `README.md` and `week-2/` at the top):

```bash
ls
git ls-files | head
```

Set your identity and the pull strategy so pulls never create surprise merge commits:

```bash
git config user.name  "leeclay95"
git config user.email "you@example.com"
git config pull.ff only          # refuse to auto-merge; you resolve divergence deliberately
```

Authenticate `gh` (once per machine):

```bash
gh auth login                    # choose GitHub.com > HTTPS > login with browser
gh auth status                   # verify
```

---

## 3. Daily workflow (the safe loop)

Run git from the **repo root** (`test-terraform/`). You can `cd week-2` to *edit* files,
but do your `add` / `commit` / `push` from the root so the paths are unambiguous.

```bash
cd /path/to/test-terraform       # always start at the root

# 1. Sync before you touch anything
git pull --ff-only origin main

# 2. Edit files — inside week-2/ or wherever they live
#    (open the editor at the REPO ROOT, not at week-2/)

# 3. Stage. Prefer explicit paths so you never grab a stray restructure:
git add week-2/generated.tf week-2/scripts/02-create-rds.sh
#    ...or stage everything, but ONLY after checking status (step 4):
# git add -A

# 4. LOOK at what you're about to commit. This is the guard rail:
git status
git diff --cached --stat

# 5. Commit
git commit -m "week-2: <what you changed>"

# 6. Push (plain push — never --force)
git push origin main
```

### The status check that stops a flatten (step 4)

Before every commit, read `git status` / `git diff --cached --stat`. **Abort** if you see:

- renames that pull files OUT of `week-2/`, e.g. `renamed: week-2/generated.tf -> generated.tf`
- `deleted: README.md` or `deleted: week-2/WALKTHROUGH.md` that you didn't intend
- new top-level `.tf` / `scripts/` that used to live under `week-2/`

If you see any of those, you're about to flatten the repo. `git restore --staged .` and
figure out why (usually: you're committing from inside `week-2/` or an editor moved things).

---

## 4. Golden rules (memorize these)

1. **Never `git init` inside `week-2/`.** There is exactly one repo, and its root is
   `test-terraform/`. Check with `git rev-parse --show-toplevel` — it must end in
   `/test-terraform`, never `/week-2`.
2. **Never move files out of `week-2/`** (`git mv week-2/x .`) unless that's genuinely
   the change you want reviewed.
3. **Never `git push --force` / `--force-with-lease` to `main`.** Force-push is only for
   deliberate recovery (see §6), never routine work.
4. **Always `git status` before you commit**, and confirm the paths start with `week-2/`.
5. **Always `git pull --ff-only` before starting.** If it refuses because histories
   diverged, stop and reconcile — don't force anything.
6. **Open your editor/IDE at the repo root**, not at `week-2/`. IDE git integrations
   commit relative to the folder you opened; open `week-2/` and it's easy to restructure.

---

## 5. Branch + PR workflow with `gh` (recommended over pushing straight to main)

Working on a branch and merging via PR means a bad restructure shows up in the PR diff
*before* it ever touches `main`.

```bash
cd /path/to/test-terraform
git pull --ff-only origin main

git switch -c week2/<short-topic>        # new branch off main

# ...edit under week-2/, then:
git add week-2/<files>
git commit -m "week-2: <change>"
git push -u origin week2/<short-topic>

# Open the PR and eyeball the diff (look for stray root-level file moves):
gh pr create --base main --title "week-2: <change>" --body "<what/why>"
gh pr diff                                # review the file list — all paths under week-2/?

# Merge once it looks right:
gh pr merge --squash --delete-branch
```

Handy `gh` checks:

```bash
gh repo view --web          # open the repo in a browser to eyeball the file tree
gh pr status                # your open PRs
gh run list                 # CI runs, if any
```

---

## 6. If it happens again — recovery

**Case A: the remote got flattened/clobbered, but a good local clone exists somewhere.**
From the machine that still has the good history:

```bash
git fetch origin
git log --oneline -3 origin/main         # confirm the bad commit is on top
git branch backup/bad-$(date +%F) origin/main   # keep the bad commit, just in case
git push --force-with-lease origin main  # rewind remote to your good local main
```

**Case B: your local got flattened but the remote is still good.**

```bash
git fetch origin
git reset --hard origin/main             # discard local mess, match remote exactly
```

**Case C: you already pushed a bad commit and no clean clone exists.** Find the last good
commit and reset the remote to it:

```bash
git log --oneline -20                    # find the last good SHA (e.g. e5e484d)
git branch backup/bad origin/main        # safety net
git reset --hard <good-sha>
git push --force-with-lease origin main
```

Always create a `backup/…` branch before any `--force` push so nothing is truly lost.

---

## 7. Quick reference card

```bash
git rev-parse --show-toplevel     # MUST end in /test-terraform (never /week-2)
git pull --ff-only origin main    # sync before work
git status                        # ALWAYS run before commit — check paths are week-2/...
git add week-2/<file>             # stage explicit paths
git commit -m "week-2: ..."       # commit
git push origin main              # push (NEVER --force in normal work)
```

If any command wants to move files to the root or delete `README.md`/`WALKTHROUGH.md` —
**stop**. That's the flatten. It is never part of a normal week-2 edit.
