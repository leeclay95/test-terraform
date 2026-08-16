# Week 4 — tfsec gate: set it up, prove it works, undo it

A CI check that scans Terraform on every pull request, fails on anything HIGH or
above, uploads the reports as evidence, and — once branch protection is on — blocks
the merge into `main`.

This walkthrough covers the whole lifecycle: get the workflow onto `main` so new PRs
start going through it, turn on the protection that makes it binding, drive one PR
that fails and one that passes, read the results with `gh`, and roll the whole thing
back if you want the repo as it was.

Run everything from the **repo root** (`test-terraform/`) — see
[`../GIT_WORKFLOW.md`](../GIT_WORKFLOW.md) for why that matters here.

Repo used throughout: `leeclay95/test-terraform`, default branch `main`.

**Contents**

- [§0 Prerequisites](#0-prerequisites)
- [§1 What's in week-4, and how the pipeline runs](#1-whats-in-week-4-and-how-the-pipeline-runs)
- [§2 Get the workflow onto main now](#2-get-the-workflow-onto-main-now)
- [§3 Turn on branch protection](#3-turn-on-branch-protection-this-is-what-blocks-the-merge)
- [§4 The PR that fails](#4-the-pr-that-fails)
- [§5 View the pipeline results with gh](#5-view-the-pipeline-results-with-gh)
- [§6 The PR that passes](#6-the-pr-that-passes)
- [§7 Revert all of it](#7-revert-all-of-it)
- [§8 Troubleshooting](#8-troubleshooting)
- [§9 Quick reference](#9-quick-reference)

---

## §0 Prerequisites

### gh, with the workflow scope

Pushing anything under `.github/workflows/` needs the `workflow` OAuth scope. Without
it the push is rejected at the very last moment, after you have already committed.

```bash
gh auth status                  # look for 'workflow' in Token scopes
gh auth refresh -s workflow     # only if it is missing
```

### tfsec locally (optional, but do it)

CI is a slow way to find out you made a typo. Running the same scan locally first
turns a 60-second round trip into a 2-second one. Pin the same version CI uses —
rules get added between releases, so version drift means local and CI disagree.

```bash
curl -sSLo /tmp/tfsec.tar.gz \
  https://github.com/aquasecurity/tfsec/releases/download/v1.28.14/tfsec_1.28.14_linux_amd64.tar.gz

# Verify before you execute it — same checksum the workflow enforces
echo "329ae7f67f2f1813ebe08de498719ea7003c75d3ca24bb0b038369062508008e  /tmp/tfsec.tar.gz" \
  | sha256sum -c

tar -xzf /tmp/tfsec.tar.gz -C /tmp tfsec
mkdir -p ~/.local/bin && install -m 0755 /tmp/tfsec ~/.local/bin/tfsec
tfsec -v | tail -1              # v1.28.14
```

The exact command CI runs, which you can run any time:

```bash
tfsec week-4 --minimum-severity HIGH
```

### Know where you are

```bash
cd /path/to/test-terraform
git rev-parse --show-toplevel   # MUST end in /test-terraform, never /week-4
git status                      # clean before you start
```

---

## §1 What's in week-4, and how the pipeline runs

```
.github/workflows/tfsec.yml     the pipeline — lives at the REPO ROOT, not in week-4/
week-4/
├── WALKTHROUGH.md              this file
├── insecure_s3.tf.example      deliberately vulnerable S3 — 7 HIGH findings. NOT scanned.
└── secure_s3.tf                the hardened equivalent — 0 findings. THIS is what CI scans.
```

### Why one file ends in `.tf.example`

tfsec scans a **directory**, not a file, and parses every `*.tf` in it as a single
Terraform module. Name the vulnerable file `insecure_s3.tf` and it gets parsed
alongside `secure_s3.tf`: both declare `aws_s3_bucket.demo`, the definitions collide,
and tfsec reports the insecure bucket's attributes *against the secure file*. Every
PR then fails for reasons that have nothing to do with the change under review.

The `.example` suffix keeps it out of the module while leaving it right next to the
file it teaches. It is also the honest lesson: in Terraform there is no such thing as
a `.tf` file that is "only an example" — if it is in the directory, it is the config.

### The two examples

| | `insecure_s3.tf.example` | `secure_s3.tf` |
| --- | --- | --- |
| Encryption | none at all | SSE-KMS with a customer-managed key, rotation on |
| ACL | `public-read` — the world can list and read every object | ACLs disabled via `BucketOwnerEnforced` |
| Public access block | present, all four switches `false` — looks like a control, blocks nothing | all four `true` |
| Versioning | none | enabled |
| Access logging | none | to a separate log bucket |
| tfsec at HIGH+ | **7 findings** | **0 findings** |

`secure_s3.tf` also carries a `#tfsec:ignore:aws-s3-enable-bucket-logging` on the log
bucket, with the reasoning in the comment above it: a log bucket that logs to itself
is an infinite loop, so the accepted pattern is to leave the final sink unlogged.
That is how you record an accepted risk so a reviewer can audit it — as opposed to
deleting the check and hoping nobody notices. Note the placement: the `#tfsec:ignore`
line must sit *immediately* above the resource or tfsec ignores the ignore.

### How the pipeline runs

`.github/workflows/tfsec.yml` triggers on `pull_request` into `main`, plus
`workflow_dispatch` so you can run it by hand. It is four steps:

1. **Install** tfsec `v1.28.14`, downloaded and SHA256-verified. Pinned so a new
   tfsec release can never silently change the verdict on an unchanged repo.
2. **Run** `tfsec week-4 --minimum-severity HIGH`, writing three report formats to
   `evidence/`.
3. **Upload** `evidence/` as the `tfsec-evidence-<run-id>` build artifact, kept 90
   days. This step is `if: always()`, so it runs even when the scan found problems.
4. **Fail** the job if tfsec reported anything.

Steps 2 and 4 are separate on purpose. tfsec exits non-zero when it finds something,
and Actions runs each step with `bash -e` — so a finding would abort the step
immediately and there would be no artifact to review. The failure would delete its
own evidence. Step 2 runs `set +e` and records the exit code instead; step 4 acts on
it. Step 4 also fails closed: a missing exit code means the scan never completed, and
that counts as a failure rather than a pass.

Two knobs, both `env:` values at the top of the workflow:

```yaml
SCAN_PATH: "week-4"
MIN_SEVERITY: "HIGH"
```

**Why only `week-4` and not the whole repo?** `week-2/` still has known HIGH findings
from that lesson's audit. Point the gate at the repo root and every PR fails for
reasons unrelated to the change under review — and a gate that is red by default gets
switched off within a week. This one starts green, so a red X is genuinely *your*
change. Harden a directory, then add it to `SCAN_PATH`.

---

## §2 Get the workflow onto main now

This is the step that makes new PRs start going through the pipeline. Until the
workflow is on `main`, nothing enforces anything.

Push it straight to `main`. Normally this repo prefers the PR flow, but there is
nothing to protect yet and no gate to satisfy — and `workflow_dispatch` only works
once the file is on the default branch.

```bash
git switch main
git pull --ff-only origin main
```

### 2.1 Check the workflow is actually tracked

This repo's `.gitignore` has a blanket `*.yml` rule. Left alone it silently swallows
the workflow — the file sits on disk, `git status` never mentions it, you push, and
nothing ever runs. A negation was added for it. Confirm it took:

```bash
git check-ignore -q .github/workflows/tfsec.yml && echo "STILL IGNORED — fix .gitignore" || echo "tracked, good"
```

Use `-q`, not `-v`. With `-v`, git reports the *negation* as a match and exits `0`,
which reads exactly like "ignored" and is not.

If you get `STILL IGNORED`, `.gitignore` is missing:

```gitignore
!.github/workflows/*.yml
```

### 2.2 Stage, read what you staged, push

```bash
git add .gitignore .github/workflows/tfsec.yml week-4/
git status
git diff --cached --stat
```

Read that file list before committing. Everything should be under `.github/` or
`week-4/`, plus `.gitignore`. If you see files being *moved out of* `week-2/`, stop —
that is the repo-flattening failure mode in `../GIT_WORKFLOW.md` §1.

```bash
git commit -m "week-4: add blocking tfsec HIGH+ pipeline and S3 lesson examples"
git push origin main
```

### 2.3 Confirm GitHub picked it up

```bash
gh workflow list                # 'tfsec' should appear, state 'active'
```

The workflow only triggers on pull requests, so pushing it does not run it. Force a
first run to smoke-test it — this also makes GitHub aware of the check name, which
helps in §3:

```bash
gh workflow run tfsec           # uses workflow_dispatch
sleep 5 && gh run watch         # pick the tfsec run; expect it to go green
```

**From this point every PR into `main` runs the scan.** It reports and it uploads
evidence — but it does not yet *stop* anyone. That is §3.

---

## §3 Turn on branch protection — this is what blocks the merge

**A red X blocks nothing on its own.** It is a visible failure that any impatient
human can merge straight past. What actually blocks the merge is branch protection
listing the check as required.

The context string must match the job's `name:` in the workflow exactly:
`tfsec (HIGH+, blocking)`.

```bash
gh api -X PUT "repos/leeclay95/test-terraform/branches/main/protection" \
  -H "Accept: application/vnd.github+json" \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["tfsec (HIGH+, blocking)"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

- `strict: true` — the branch must also be up to date with `main` before merging, so
  a PR cannot pass against a stale base.
- `enforce_admins: true` — the rule applies to you too. Without it the repo owner can
  click through the gate, which makes the whole exercise theatre.
- `required_pull_request_reviews` and `restrictions` must be present even as `null`.
  The API rejects the payload without them.

Verify:

```bash
gh api "repos/leeclay95/test-terraform/branches/main/protection" \
  --jq '{checks: .required_status_checks.contexts, strict: .required_status_checks.strict, admins: .enforce_admins.enabled}'
```

Expect `tfsec (HIGH+, blocking)`, `true`, `true`.

Note the side effect: protection also means **you can no longer push directly to
`main`**. From here on everything goes through a PR — including §2-style changes.
That is the point, but it is worth knowing before it surprises you.

> **Plan limits.** Branch protection needs a public repo, or GitHub Pro/Team/Enterprise
> for a private one. On a free private repo the API returns `403 Upgrade to GitHub Pro`.
> Either `gh repo edit --visibility public`, or accept that the gate reports without
> enforcing. The rest of this walkthrough still works either way — you just have to
> not merge past the red X yourself.

---

## §4 The PR that fails

Branch, land insecure Terraform in the protected directory, and let CI catch it.

```bash
git switch main
git pull --ff-only origin main
git switch -c week4/insecure-s3
```

Copy the vulnerable example over the scanned config — the realistic scenario of
someone reaching for a known-bad pattern:

```bash
cp week-4/insecure_s3.tf.example week-4/secure_s3.tf
git diff --stat
```

Check locally first, if you installed tfsec:

```bash
tfsec week-4 --minimum-severity HIGH
echo "exit code: $?"
```

Expected — 7 findings, exit `1`:

```
HIGH  aws-s3-block-public-acls          week-4/secure_s3.tf:59
HIGH  aws-s3-block-public-policy        week-4/secure_s3.tf:60
HIGH  aws-s3-enable-bucket-encryption   week-4/secure_s3.tf:44
HIGH  aws-s3-encryption-customer-key    week-4/secure_s3.tf:44
HIGH  aws-s3-ignore-public-acls         week-4/secure_s3.tf:61
HIGH  aws-s3-no-public-access-with-acl  week-4/secure_s3.tf:51
HIGH  aws-s3-no-public-buckets          week-4/secure_s3.tf:62
```

Push it anyway — the point is watching CI stop it:

```bash
git add week-4/secure_s3.tf
git commit -m "week-4: make demo bucket public and drop encryption (deliberately insecure)"
git push -u origin week4/insecure-s3

gh pr create --base main \
  --title "week-4: insecure S3 (should be blocked)" \
  --body "Deliberately insecure. Expecting the tfsec gate to fail this PR."
```

Watch the check:

```bash
gh pr checks --watch
```

```
X  tfsec (HIGH+, blocking)   1m2s   https://github.com/.../actions/runs/...
```

`gh pr checks` exits non-zero when a check fails, so it is scriptable.

Now confirm the merge is actually refused:

```bash
gh pr view --json mergeable,mergeStateStatus \
  --jq '{mergeable, mergeStateStatus}'
# {"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}

gh pr merge --squash
# X Pull request is not mergeable: the base branch policy prohibits the merge.
```

`mergeable: MERGEABLE` just means no git conflicts. `mergeStateStatus: BLOCKED` is
the gate. Leave this PR open — §6 fixes it in place.

---

## §5 View the pipeline results with gh

A failing check that does not say *what* failed gets rerun until it passes. Here is
how to get the detail without leaving the terminal.

### Find the run

```bash
gh run list --workflow tfsec --limit 5
gh run list --branch week4/insecure-s3 --workflow tfsec --limit 1

# Grab the id for scripting
RUN_ID=$(gh run list --branch week4/insecure-s3 --workflow tfsec --limit 1 \
           --json databaseId --jq '.[0].databaseId')
echo "$RUN_ID"
```

### Read the logs

```bash
gh run view "$RUN_ID"                   # step-by-step status
gh run view "$RUN_ID" --log-failed      # only the step that failed
gh run view "$RUN_ID" --log | grep -A3 'Result #'   # the findings as CI saw them
gh run view "$RUN_ID" --web             # open in a browser
```

### Download the evidence

The reason the workflow splits "run" from "fail": the artifact is uploaded before the
build goes red, so it exists for exactly the runs you care about.

```bash
gh run download "$RUN_ID" --name "tfsec-evidence-${RUN_ID}" --dir /tmp/tfsec-evidence
ls /tmp/tfsec-evidence
```

| File | What it is for |
| --- | --- |
| `tfsec.text` | Human-readable — offending lines, impact, resolution, docs link |
| `tfsec.json` | Machine-readable, for `jq`, diffing runs, feeding a dashboard |
| `tfsec.sarif.json` | SARIF — the standard format IDEs and code-scanning tools ingest |

Pull the finding list out:

```bash
jq -r '.results[] | "\(.severity)\t\(.long_id)\t\(.resource)"' /tmp/tfsec-evidence/tfsec.json
```

Get the full story for one rule — problem, blast radius, fix:

```bash
jq -r '.results[] | select(.long_id=="aws-s3-no-public-access-with-acl")
       | "PROBLEM: \(.description)\nIMPACT:  \(.impact)\nFIX:     \(.resolution)\nDOCS:    \(.links[0])"' \
  /tmp/tfsec-evidence/tfsec.json
```

Artifacts are kept 90 days, so this doubles as an audit trail: for any PR in that
window you can produce the exact scan that gated it.

### Watch a run live

```bash
gh run watch                            # pick from a list
gh run watch "$RUN_ID"                  # a specific one
gh pr checks --watch                    # from the PR's point of view
```

---

## §6 The PR that passes

Restore the hardened config on the same branch. No new PR needed — pushing to
`week4/insecure-s3` updates the open PR and retriggers the workflow.

```bash
git checkout main -- week-4/secure_s3.tf     # take the good version back from main
git status --short week-4/                   # MUST show: M  week-4/secure_s3.tf
```

**Do not skip that `git status`.** If it prints nothing, the restore did not happen
and the next three commands will all succeed while doing nothing: `git add` stages an
unchanged file, `git commit` says `nothing added to commit`, `git push` says
`Everything up-to-date`, and `gh pr checks` re-reports the *old* failing run. It looks
exactly like CI ignoring your fix. It is CI correctly judging a branch you never
changed.

(`git checkout <ref> -- <path>` stages the file as well as writing it, which is why
the `M` appears in the left-hand column.)

Verify locally:

```bash
tfsec week-4 --minimum-severity HIGH
echo "exit code: $?"                          # 0, "No problems detected!"
```

What that restored, finding by finding:

| Fix | Clears |
| --- | --- |
| Dropped the `public-read` ACL, set ownership to `BucketOwnerEnforced` (ACLs off entirely) | `aws-s3-no-public-access-with-acl` |
| All four public-access-block switches back to `true` | `aws-s3-block-public-acls`, `aws-s3-block-public-policy`, `aws-s3-ignore-public-acls`, `aws-s3-no-public-buckets` |
| SSE-KMS with a customer-managed key, rotation enabled | `aws-s3-enable-bucket-encryption`, `aws-s3-encryption-customer-key` |

The CMK matters beyond satisfying the check: with a customer-managed key you control
the key policy, you can revoke it, and rotation is provable. The AWS-managed `aws/s3`
key gives you none of that.

Push and watch it go green:

```bash
git add week-4/secure_s3.tf
git commit -m "week-4: restore hardened bucket — SSE-KMS CMK, block all public access"
git push

gh pr checks --watch
```

```
✓  tfsec (HIGH+, blocking)   58s   https://github.com/.../actions/runs/...
```

Confirm the block lifted:

```bash
gh pr view --json mergeable,mergeStateStatus --jq '{mergeable, mergeStateStatus}'
# {"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
```

Merge:

```bash
gh pr merge --squash --delete-branch
git switch main && git pull --ff-only origin main
```

If `strict: true` complains the branch is behind `main`:

```bash
git fetch origin && git merge origin/main && git push
# or let GitHub handle it:
gh pr merge --squash --delete-branch --auto    # merges itself once checks are green
```

You have now watched the same PR go from blocked to mergeable purely on the security
of its Terraform.

### Prefer two separate PRs?

Same thing, one branch each — useful if you want both outcomes visible side by side
in the PR list:

```bash
# The failing one
git switch main && git pull --ff-only origin main
git switch -c week4/pr-fail
cp week-4/insecure_s3.tf.example week-4/secure_s3.tf
git commit -am "week-4: insecure S3 (expect FAIL)" && git push -u origin week4/pr-fail
gh pr create --base main --title "week-4: insecure S3 (expect FAIL)" --body "Should be blocked."

# The passing one — branch from main, so it never contains the bad commit
git switch main
git switch -c week4/pr-pass
# make any harmless change inside the scanned dir, e.g. a comment
printf '\n# Reviewed %s — hardened, no HIGH findings.\n' "$(date +%F)" >> week-4/secure_s3.tf
git commit -am "week-4: annotate hardened S3 (expect PASS)" && git push -u origin week4/pr-pass
gh pr create --base main --title "week-4: annotate hardened S3 (expect PASS)" --body "Should pass."

gh pr list                       # both open
gh pr checks week4/pr-fail       # X
gh pr checks week4/pr-pass       # ✓
```

Close the failing one without merging — it did its job:

```bash
gh pr close week4/pr-fail --delete-branch
gh pr merge week4/pr-pass --squash --delete-branch
```

---

## §7 Revert all of it

Four independent things to undo. Do only the ones you want.

### 7.1 Remove branch protection

```bash
gh api -X DELETE "repos/leeclay95/test-terraform/branches/main/protection"

# confirm it is gone — expect 404 Branch not protected
gh api "repos/leeclay95/test-terraform/branches/main/protection" 2>&1 | head -2
```

Do this **first** if you also plan to remove the workflow, otherwise the required
check will block the PR that deletes it — a gate that refuses to let you dismantle it
because it is not passing. To keep protection but stop requiring the check, re-PUT
§3's payload with `"contexts": []` instead.

### 7.2 Delete the demo branches

```bash
git switch main
git branch -D week4/insecure-s3 week4/pr-fail week4/pr-pass 2>/dev/null
git push origin --delete week4/insecure-s3 week4/pr-fail week4/pr-pass 2>/dev/null
git fetch --prune
```

### 7.3 Turn the pipeline off

Least destructive first.

**Disable, keep the file** — nothing runs, everything stays reviewable:

```bash
gh workflow disable tfsec
gh workflow list --all           # shows 'disabled_manually'
gh workflow enable tfsec         # to switch it back on
```

**Stop it blocking, keep it reporting** — edit `.github/workflows/tfsec.yml` and drop
the last step, or set `MIN_SEVERITY: "CRITICAL"` to narrow what it fails on.

**Delete it:**

```bash
git switch -c week4/remove-tfsec
git rm .github/workflows/tfsec.yml
git commit -m "week-4: remove tfsec pipeline"
git push -u origin week4/remove-tfsec
gh pr create --base main --title "week-4: remove tfsec pipeline" --body "Reverting the week-4 gate."
gh pr merge --squash --delete-branch
```

### 7.4 Undo the whole week-4 commit

If §2's commit is still the tip of `main` and you want the repo exactly as it was:

```bash
git log --oneline -5                       # find the week-4 commit SHA
git switch -c week4/revert
git revert --no-edit <sha>                 # forward-only; never rewrites history
git push -u origin week4/revert
gh pr create --base main --title "Revert week-4 tfsec pipeline" --body "Reverts <sha>."
gh pr merge --squash --delete-branch
```

`git revert` adds a new commit that undoes the old one. Prefer it over
`git reset --hard` + force push: nothing is rewritten, so nobody else's clone breaks.
`../GIT_WORKFLOW.md` §6 covers force-push recovery for the cases where you have no
choice — this is not one of them.

Check what a revert would touch before committing to it:

```bash
git show --stat <sha>
```

If you removed the workflow but left `.gitignore` alone, that is fine — the
`!.github/workflows/*.yml` negation is harmless with no workflows present, and you
will want it again the next time you add one.

---

## §8 Troubleshooting

**The workflow never ran.**
Almost always the `.gitignore` `*.yml` rule. Check what GitHub actually has:

```bash
git ls-files .github/workflows/          # empty output = never committed
git check-ignore -q .github/workflows/tfsec.yml && echo IGNORED || echo "not ignored"
gh workflow list                         # is 'tfsec' registered at all?
```

**`refusing to allow an OAuth App to create or update workflow`** on push.
Missing the `workflow` scope: `gh auth refresh -s workflow`, then push again.

**The check runs but the PR still merges.**
Protection is not configured, the context string does not match the job name exactly
(`tfsec (HIGH+, blocking)`), or `enforce_admins` is false and you are an admin:

```bash
gh api "repos/leeclay95/test-terraform/branches/main/protection" \
  --jq '.required_status_checks.contexts, .enforce_admins.enabled'
```

**403 `Upgrade to GitHub Pro`** on the protection call.
Free plan on a private repo. Make it public or accept report-only mode (§3).

**`gh workflow run` says the workflow has no `workflow_dispatch` trigger.**
The file is not on the default branch yet. `workflow_dispatch` is read from `main`,
not from your feature branch. Finish §2 first.

**Local tfsec disagrees with CI.**
Version drift. `tfsec -v | tail -1` must say `v1.28.14`, matching `TFSEC_VERSION` in
the workflow. Newer tfsec releases add rules.

**The scan passes but you expected findings.**
tfsec only parses `*.tf`, so editing `week-4/insecure_s3.tf.example` changes nothing
the gate sees — that is the whole point of the suffix. To see the vulnerable config
light up, copy it into a scanned filename (§4) or scan a copy on its own:

```bash
mkdir -p /tmp/ins && cp week-4/insecure_s3.tf.example /tmp/ins/s3.tf
tfsec /tmp/ins --minimum-severity HIGH           # 7 findings, always
```

**You fixed it, pushed, and the check is still red — with the same elapsed time.**
You are looking at the previous run; nothing was pushed. The giveaway is the trio
`nothing added to commit` / `Everything up-to-date` / an unchanged `ELAPSED` value.
Your working-tree file is identical to what is already committed, so there was no
change to stage:

```bash
git status --short week-4/          # empty = nothing to commit, the fix never landed
git diff main -- week-4/secure_s3.tf   # is the branch still carrying the bad version?
gh run list --branch "$(git branch --show-current)" --workflow tfsec --limit 3
```

That last command shows run timestamps — if the newest predates your "fix", CI never
ran again. Redo the restore in §6, confirm `git status` shows `M`, then commit.

**`gh pr checks` shows the name as `tfsec/tfsec (HIGH+, blockin...`.**
That is the terminal display format, `<workflow>/<job>`, truncated to fit. The real
check name — the string branch protection matches on — is just the job name. Confirm
it rather than guessing:

```bash
gh api "repos/leeclay95/test-terraform/commits/$(git rev-parse HEAD)/check-runs" \
  --jq '.check_runs[].name'
# tfsec (HIGH+, blocking)
```

Putting `tfsec/tfsec (HIGH+, blocking)` in §3's `contexts` would match nothing, and
the gate would quietly stop blocking anything.

**No artifact on the run.**
The upload step is `if: always()`, so it should always exist. If it is missing the job
died before the scan finished — `gh run view <id> --log-failed`.

**Now you can't push to main.**
Expected after §3. Use a branch and a PR, or remove protection (§7.1).

---

## §9 Quick reference

```bash
# --- local scan (exactly what CI runs) -----------------------------------
tfsec week-4 --minimum-severity HIGH          # exactly what CI runs
tfsec week-4                                  # all severities, not just HIGH

# --- ship the pipeline ---------------------------------------------------
git check-ignore -q .github/workflows/tfsec.yml && echo IGNORED || echo tracked
git add .gitignore .github/workflows/tfsec.yml week-4/ && git status
git commit -m "week-4: add tfsec gate" && git push origin main
gh workflow list && gh workflow run tfsec

# --- branch protection ---------------------------------------------------
gh api repos/leeclay95/test-terraform/branches/main/protection \
  --jq '.required_status_checks.contexts'
gh api -X DELETE repos/leeclay95/test-terraform/branches/main/protection

# --- branch + PR ---------------------------------------------------------
git switch -c week4/<topic>
git add <explicit paths> && git status        # ALWAYS read this before commit
git commit -m "week-4: ..." && git push -u origin week4/<topic>
gh pr create --base main --title "..." --body "..."

# --- view results --------------------------------------------------------
gh pr checks --watch                          # live; non-zero exit on failure
gh run list --workflow tfsec --limit 5
gh run view <run-id> --log-failed
gh run view <run-id> --web
gh run download <run-id> --name tfsec-evidence-<run-id> --dir /tmp/ev

# --- merge ---------------------------------------------------------------
gh pr view --json mergeable,mergeStateStatus
gh pr merge --squash --delete-branch
gh pr merge --squash --delete-branch --auto   # merge once checks go green

# --- undo ----------------------------------------------------------------
gh workflow disable tfsec                     # off, file kept
git revert --no-edit <sha>                    # undo without rewriting history
```
