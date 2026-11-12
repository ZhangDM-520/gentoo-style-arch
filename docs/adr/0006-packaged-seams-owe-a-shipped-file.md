# A shipped seam owes a shipped file, and the packaging proves it

`--print-conf` and `--print-completion` exist so a shipped file can never
drift from the binary: the engine prints the text, the recipe writes it out.
The mechanism worked exactly as designed — and `gsa <TAB>` still completed
filenames, because `gsa-pm`'s `package()` invoked `--print-conf` and never
`--print-completion`. The seam was correct, the engine fixture pinned its
output, the contract row said "which `gsa-pm` installs" — and no shell had a
completion file. Three correct artifacts, one missing `install` line, and the
feature did not exist on any host.

The failure is not specific to completion. It is a shape: **a text-producing
seam is only half a feature, and the half that ships is in the other
repository.** The engine repository cannot see it (its fixtures assert the
seam's output, which is the correct subject for that repo), and the recipe
repository had no check at all, so the boundary between them is where the
guarantee silently ends.

We decided that **the packaging, not the seam, is the assertion surface** for
shipped artifacts, and that the enforcement is reciprocal:

1. **The recipe repository pins the relationship.** `gsa-pm`'s fixture runs the
   real `package()` against the real engine under test and asserts, for every
   rostered `--print-*` seam, that the installed file exists, is non-empty, and
   is **byte-identical** to the engine's own output. A hand-copied file that
   drifted fails as loudly as a deleted `install` line.
2. **The roster is explicit and closed, in both directions.** The fixture
   lists seam → install path; a `--print-*` invocation that is not in the
   roster fails it by name. And the engine publishes the same list —
   `gsa --seam-roster` prints `TEXT_SEAMS` — so the fixture also fails when
   the ENGINE grows a text seam the packaging never invokes. One direction
   alone only catches what the PKGBUILD happens to mention; the original
   defect was precisely a seam the PKGBUILD never mentioned. That two-way
   closure is what makes this durable rather than a one-shot fix.
3. **The engine keeps its own half.** `tests/completion.sh` continues to pin
   the wrapper text and the `--complete` grammar; the recipe fixture never
   duplicates those assertions. Each repository asserts what it owns — the
   fabricator asserts the bytes, the packager asserts their arrival.

Consequences:

- A new text seam costs three changes in one chain: the seam, the recipe row
  plus its `install` line, and the fixture row. That cost is the point; the
  alternative is what happened here, where a working seam shipped to nobody.
- The fixture runs the **installed** engine (§L.10), so it also catches the
  other half of the same gap: a `gsa-pm` built from an engine older than the
  seam it claims to ship.
- Cross-repository coupling is now load-bearing: the recipe battery cannot
  validate `gsa-pm` without an engine on `PATH` (or `GSA_TEST_GSA_BIN`). That
  dependency already existed for every other fixture in that repository, so it
  adds no new failure mode — it names an old one.
- The engine's `docs/build-guide.md` states plainly that *placing* the files
  is the packaging's job, so the next reader does not re-diagnose the seam as
  absent — the mistake this record exists to prevent.

Rejected alternative: have the engine write the files itself at first run.
That would put a root-owned package file outside pacman's ownership (an
unowned file blocks the next `gsa-pm` upgrade, measured), and it would make the
file's content a property of whoever ran the engine first rather than of the
binary that was installed.
