# Resolving conflicts

A resolution keeps what each pull request meant. Before writing one, read both sides against their common ancestor: `git diff <merge-base> <one side> -- <file>` for each side. Then write the version that holds both changes. Take one side whole only when the other side's change is already contained in it, or has been superseded by it, and say which in the plan.

The project's notes and its own recording rules come first. The patterns below cover what those rules usually leave implicit.

## Records appended at the end

Decision logs, judgement logs, changelogs and their indexes add each entry at the end of a section, so two pull requests adding entries collide at the same spot.

- Keep every entry from both sides. Put the earlier-merged pull request's entries first and the later one's after them, so the record reads in the order it landed.
- If both sides open the same date heading, keep one heading with both sides' entries under it.
- An index lists its entries in the same order as the topic file it indexes.
- Two entries with the same title, or one entry that retires something the other relies on, are a contradiction for Cicely, not a merge. Put it in the plan as a question.

## Handoff and orientation files

A map such as `NEXT.md` tells the next session where things are, so it has to be true of the merged tree.

- Keep every item either side adds.
- When both sides changed the same item, write one item that is true of the combined code. Check each name, path and citation in it against the tree, not against either side's wording.
- Once the last pull request is in, re-read the whole file against the combined tree. A step can carry a correction only in a path it had in conflict, because the merge step replays exactly the conflicted paths. List any other claim that is no longer true as a correction for a follow-up draft pull request.

## Code

- Keep both sides' tests.
- If both sides changed the same function compatibly, combine them. If they changed it incompatibly, the resolution needs new code. Write it, mark it as new code in the plan with its diff, and gate it; or ask, if the right behaviour is a design choice.
- For generated or tool-written files, such as lockfiles, editor-rewritten scenes and settings, or import metadata, follow the project's notes. Regenerate them with the tool rather than merging them by hand where that is possible.

## Conflicts the text does not show

Two pull requests can merge cleanly and still break each other. After each step, before running the gate:

- List what the incoming pull request removed or renamed: functions, files, settings, and the titles of decision or judgement entries. Search the combined tree for references to the old names, especially in lines the other pull requests added.
- Check that every citation the step added, such as an entry title, a path or an issue number, still resolves in the combined tree.
- Check claims of exclusivity, such as "the only", "the one" or "nothing else", in prose the step added or kept. Another pull request may have added the second thing.

The gate catches only what it tests, so a clean gate does not settle a semantic doubt. Raise the doubt as a question in the plan.

## Corrections the checks find

A correction belongs to the rehearsal only when the step had that path in conflict, because the merge step replays exactly the conflicted paths from the step's commit. Make it part of the step's resolution and its commit, show it in the plan, and redo every later step. Any other correction goes into a follow-up draft pull request after the run. Including it would leave a tree that `update.ps1` cannot reproduce, and it reports the mismatch.

For example, #1 renames `Campaign.reading` to `Campaign.page`, and #2 adds a `NEXT.md` bullet citing `Campaign.reading`. They merge cleanly, so `NEXT.md` was in no conflict, and only the re-read after the last step finds the stale citation. The fix goes into a follow-up draft pull request. Had `NEXT.md` been in conflict at #2's step, the corrected bullet would have been part of that step's resolution.

## Recording a resolution

For each resolved file, write one line for the plan and the pull request's comment: what each side changed, and how the resolution keeps both.
