# crates/ — the native `gsa` engine

Workspace of the native package manager (`docs/gsa-contract.md`). Phase 1 is
the read-only core: the engine parses the recipe repository natively —
committed `.SRCINFO` plus a strict read-only `PKGBUILD` scan fallback, and the
strictly loaded `config/` topology — and answers queries and build-order
plans. It never evaluates recipe shell and never touches pacman's database.

| Crate | Responsibility |
| --- | --- |
| `gsa-model` | Core types: `RecipeId`, `TopologyRecord`, groups/tags, lane outcomes, plan/outcome rows, the run record and its `format: 2` machine rendering (§H) |
| `gsa-topo` | Strict loaders for `config/topology.conf`, `build-defaults.conf`, `abi-exclusions.conf`, user sets — one malformed record breaks every command, naming the offender and its line |
| `gsa-recipe` | Committed `.SRCINFO` parser + in-memory cache, strict read-only `PKGBUILD` scan fallback, source classification |
| `gsa-graph` | Consumer expansion (reverse build-order closure), one canonical topological sort with cycle refusal, coupled-batch and `app-cluster` grouping |
| `gsa-cli` | The `gsa` binary: hand-rolled action-pass argv grammar (§B), selection semantics (§C), the read-only command surface and its renderings |

Not yet in this workspace (later phases, deliberately not stubbed):
`gsa-sched`, `gsa-build`, `gsa-install`, `gsa-fetch`, `gsa-state`, `gsa-qa`,
`gsa-maint`, `gsa-abi` (`plan-native-pm.md` §3.1).

Build and check: `cargo build`, `cargo test`, `cargo fmt --check`.
Run: `./target/release/gsa --help`.
