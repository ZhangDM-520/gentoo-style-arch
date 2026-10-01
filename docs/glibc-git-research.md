# Research: adding `glibc-git` and `lib32-glibc-git`

**Checked:** 2026-10-01. Findings below describe the official Arch packaging
revision current at retrieval, not a promise about a later branch tip. No
glibc source tree was cloned, and no makepkg build, install, or package hook
was run; the cited PKGBUILD and INSTALL files were read directly.
This brief combines that packaging snapshot with first-party GNU glibc build
guidance and the repository's recipe, topology, and validation contracts.
Claims about Arch packaging are pinned to packaging commit
`2d1fceaab454b56fe64092986109207839f63e4d`; upstream build guidance is pinned
to glibc commit `db6d1da22e65327ae29dcf9bc50986b2e8f3f0bd` unless noted
otherwise.

## GNU glibc upstream build and test guidance

The pinned upstream [`INSTALL`](https://sourceware.org/git/?p=glibc.git;a=blob;f=INSTALL;hb=db6d1da22e65327ae29dcf9bc50986b2e8f3f0bd)
requires an out-of-tree build (lines 15–29). It lists GCC 12.1 or newer,
GNU make 4.0 or newer, and GNU binutils 2.39 or newer among its tool
requirements (lines 467–529); verify these requirements again when moving to a
new upstream revision because the document's verification notes are tied to
release-time tool versions.

Two configure options are easy to confuse:

- `--enable-kernel=VERSION` sets the minimum Linux kernel ABI supported at
  runtime. Upstream says a higher floor can reduce compatibility code and
  improve performance (lines 82–87).
- `--with-headers=DIRECTORY` selects the Linux UAPI headers used to build
  glibc. Upstream recommends installed kernel headers and says they do not
  need to match the running kernel (lines 69–81 and 596–611).

Upstream places ABI and processor-target flags in `CC`, and optimization/debug
flags in `CFLAGS`; its default `CFLAGS` is `-g -O2`, and supplied `CFLAGS`
must enable optimization (lines 38–49). The documented `CC="gcc -m32"`
example demonstrates 32-bit compilation, not Arch's multilib packaging or
co-installation layout. Its adjacent `-O3` is an example, not a requirement.
The official [GCC x86 options](https://gcc.gnu.org/onlinedocs/gcc-16.1.0/gcc/x86-Options.html)
document that `-march` selects instructions and `-march=native` selects those
available on the build CPU; that can make binaries unusable on other CPUs.
For this project, start with host `makepkg.conf` and do not add recipe-specific
`-O3`, `-march`, or `-mtune` flags, as required by
[`CONTRIBUTING.md`](../CONTRIBUTING.md#optimization-and-trimming-standard)
and [`docs/portability.md`](portability.md#cpu-optimization).

### Performance choices

The strongest low-risk baseline is the official Arch configuration described
below: it retains `--enable-multi-arch`, disables the profile library with
`--disable-profile`, and sets `options=(!lto)`. Keep those settings initially;
do not treat generic LTO or profiling switches as a glibc optimization without
measured evidence and a test plan. If adding instrumentation later, the
project's shared [`lib/pgo.sh`](../lib/pgo.sh) payload check and
[`build-all.fish`](../build-all.fish) install refusal also apply.

Arch's `--enable-kernel=4.4` is a compatibility policy, not a tune-for-this-host
flag. Raising it is an upstream-supported way to trade older-kernel support
for possible performance, but only do so after explicitly changing the
supported-kernel floor and testing that contract. A locally installed rolling
kernel alone is not evidence that every supported Arch x86_64 host has the
same minimum.

### Tests and system-library safety

Upstream directs packagers to run `make check` and says not to use the built
library if tests fail. It recommends running tests as an unprivileged user and
notes that tests rely on normal system files such as `/etc/passwd` and
`/etc/nsswitch.conf` (lines 296–313). By default, dynamic tests use the
installed C library; `--enable-hardcoded-path-in-tests` changes that behavior
(lines 160–164). Upstream's install guidance recommends single-user mode and a
reboot when replacing the primary C library, and documents `DESTDIR` for
staging into another root (lines 380–416). This reinforces the Arch recipe's
warning below: use a disposable VM or isolated chroot for end-to-end testing,
not the development host's live libc.

Upstream does not specify an Arch package split, `/usr/lib32` layout, or
co-installation contract. Those details come from Arch's PKGBUILD below.

## Official source and package identity

Arch keeps the `glibc`, `lib32-glibc`, and `glibc-locales` split outputs in the
single `archlinux/packaging/packages/glibc` packaging project. The latest
`main` commit returned by the official GitLab API on the checked date was
`2d1fceaab454b56fe64092986109207839f63e4d` (2026-09-27); this report pins
recipe citations to that commit. The official package API listed both
`glibc` and `lib32-glibc` as `pkgbase=glibc`, in `core`, at
`2.44+r50+g1848099f063e-1`. A lookup for a separate
`archlinux/packaging/packages/lib32-glibc` project returned 404. These
repository and package locations are as checked; do not assume that
`lib32-glibc` is necessarily published in `multilib`.

- [Current `main` commit API](https://gitlab.archlinux.org/api/v4/projects/archlinux%2Fpackaging%2Fpackages%2Fglibc/repository/commits?ref_name=main&per_page=1) and [pinned commit permalink](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/commit/2d1fceaab454b56fe64092986109207839f63e4d)
- [`PKGBUILD` at that commit, lines 9-16](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L9-16) and [`.SRCINFO`, lines 1-29](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/.SRCINFO#L1-29)
- [`glibc` package page](https://archlinux.org/packages/core/x86_64/glibc/) and [`lib32-glibc` package page](https://archlinux.org/packages/core/x86_64/lib32-glibc/); [official `glibc` metadata](https://archlinux.org/packages/search/json/?name=glibc&repo=Core) and [`lib32-glibc` metadata](https://archlinux.org/packages/search/json/?name=lib32-glibc)
- [Standalone `lib32-glibc` packaging-project lookup](https://gitlab.archlinux.org/api/v4/projects/archlinux%2Fpackaging%2Fpackages%2Flib32-glibc) (404 at retrieval)

The PKGBUILD's package URL is the GNU C Library project. Its VCS source is
`https://forge.sourceware.org/glibc/glibc-mirror`, pinned to upstream commit
`1848099f063e99d4ffecbd7667766d54862398b9`. The recipe records
`pkgver=2.44+r50+g1848099f063e`, `pkgrel=1`, and derives `pkgver()` using
`git describe --abbrev=12 --tags`; the exact commit pin, rather than a moving
branch reference, determines the checkout in this packaging revision.
[`PKGBUILD`, lines 9-16 and 29-30](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L9-30),
[`pkgver()`, lines 66-69](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L66-69)

## Build configuration, floors, and dependencies

The package-base makepkg options are `staticlibs` and `!lto`. Shared configure
flags set `/usr` as the prefix and `/usr/include` as the headers path, set
`--with-bugurl=https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/issues`,
enable bind-now,
fortify-source, multi-arch, strong stack protection, and SystemTap; set
`--enable-kernel=4.4`; and disable nscd, profiling, and `-Werror`. The recipe
separately declares `linux-api-headers>=4.10` as a runtime dependency. Those
are two distinct settings in the source; the PKGBUILD does not explain why
their version numbers differ. [`PKGBUILD`, lines 25-28 and 78-92](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L25-92);
[`.SRCINFO`, lines 50-60](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/.SRCINFO#L50-60)

For the native build, the recipe sets library, libexec, and shared-library
directories under `/usr/lib`, enables CET and SFrame, runs `make -O`, then
builds the info pages with `make info` (commented as being for reproducibility).
The x86_64-only 32-bit build reuses the shared configure flags in a separate
`lib32-glibc-build` directory, adds `--host=i686-pc-linux-gnu`, and puts its
library and libexec files under `/usr/lib32`; CET and SFrame are not explicitly
added to that invocation. Its compiler commands are `gcc -m32 -mstackrealign`
and `g++ -m32 -mstackrealign`. [`PKGBUILD`, lines 103-146](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L103-146)

The recipe does not pin a GCC version or replace the full host `CFLAGS`.
Instead, it removes `_FORTIFY_SOURCE=3` from `CFLAGS` because the comment says
it breaks the testsuite build, while configure-time fortify remains enabled.
On aarch64 it removes `-fno-plt`; the adjacent comment associates that
workaround with `ldconfig` segfaults on glibc 2.44. For the 32-bit build, it
removes `-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer`; the recipe
comment cites NVIDIA-driver crashes when Steam starts. [`PKGBUILD`, lines 94-101 and 124-145](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L94-145)

The source comments give this toolchain build order:
`linux-api-headers -> glibc -> binutils -> gcc -> glibc -> binutils -> gcc`;
they also note that Valgrind requires rebuilding for each major glibc version.
The declared build dependencies are `gd`, `git`, and `python`, plus
x86_64-specific `lib32-gcc-libs`. The PKGBUILD invokes `gcc`/`g++` for the
32-bit build but does not specify compiler versions. [`PKGBUILD`, lines 6-24 and 124-132](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L6-24)

| Output package | Runtime dependencies and architecture |
| --- | --- |
| `glibc` | `filesystem`, `linux-api-headers>=4.10`, and `tzdata`; optdepends `gd` for `memusagestat` and `perl` for `mtrace`; PKGBUILD architectures `x86_64` and `aarch64`. |
| `lib32-glibc` | Exact dependency `glibc=$pkgver`; x86_64 only; split options also include `!emptydirs`. |
| `glibc-locales` | Exact dependency `glibc=$pkgver`. |

The package-base build dependencies and the split runtime dependencies above
are recorded in [`.SRCINFO`, lines 5-13 and 48-72](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/.SRCINFO#L5-72)
and the [official package metadata for `glibc`](https://archlinux.org/packages/search/json/?name=glibc&repo=Core)
and [`lib32-glibc`](https://archlinux.org/packages/search/json/?name=lib32-glibc).
The recipe declares no `checkdepends` in `.SRCINFO`, and the package API
reports none.

## Split outputs, installed paths, and hooks

The three output names are declared together in `pkgname`: `glibc`,
`lib32-glibc`, and `glibc-locales`. The `glibc` function installs the native
build, removes the generated `etc/ld.so.cache` from the package image, and
installs locale configuration, `locale-gen`, the always-available C.UTF-8
locale, tracing-probe headers, tunables, and its package-manager hooks. The
`glibc-locales` function packages pregenerated locale data and removes C.UTF-8
from that split because the main `glibc` package already ships it.
[`PKGBUILD`, lines 188-249 and 280-289](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L188-289)

The `lib32-glibc` package is not a second upstream checkout: it installs the
separately configured 32-bit build from the same pinned source/version. Its
packaging step removes non-32-bit install paths, retains `*-32.h` headers,
creates `/usr/lib/ld-linux.so.2` pointing into `/usr/lib32`, installs
`/etc/ld.so.conf.d/lib32-glibc.conf` containing `/usr/lib32`, and links
`/usr/lib32/locale` to the native locale directory. Its package options include
`!emptydirs`. [`PKGBUILD`, lines 251-278](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L251-278);
[`lib32-glibc.conf`, line 1](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/lib32-glibc.conf#L1)

The source list contains the pinned glibc VCS checkout and local configuration,
locale, header, tunables, and hook files; it contains no patch file.
`prepare()` creates build directories and enters the source directory but does
not apply an Arch patch. This is a statement about the inspected Arch packaging
revision, not about upstream glibc's own history or source contents.
[`PKGBUILD`, lines 29-46 and 71-76](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L29-76)

The PKGBUILD installs six hooks with `glibc` and two with `lib32-glibc`
([install calls](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L238-244)
and [lib32 install calls](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L275-277)):

- After glibc install/upgrade, `locale-gen` runs. The paired pre-removal hook
  deletes `/usr/lib/locale/locale-archive`.
  [`10-glibc-locale-gen.hook`](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/10-glibc-locale-gen.hook#L1-12)
  and [`10-glibc-remove-locale-archive.hook`](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/10-glibc-remove-locale-archive.hook#L1-10).
- The ldconfig hook runs `/usr/bin/ldconfig -r .` post-transaction for glibc
  install/upgrade and changes to the listed linker/tunables configuration
  paths. A paired pre-removal hook deletes `/etc/ld.so.cache`.
  [`11-glibc-ldconfig.hook`](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/11-glibc-ldconfig.hook#L1-37)
  and [`11-glibc-remove-ldconfig-cache.hook`](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/11-glibc-remove-ldconfig-cache.hook#L1-9).
- The native iconv hook runs `iconvconfig`; its paired pre-removal hook deletes
  `/usr/lib/gconv/gconv-modules.cache`.
  [`12-glibc-iconvconfig.hook`](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/12-glibc-iconvconfig.hook#L1-24)
  and [`12-glibc-remove-iconvconfig-cache.hook`](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/12-glibc-remove-iconvconfig-cache.hook#L1-10).
- The lib32 iconv hook runs
  `/usr/bin/iconvconfig --nostdlib --output=/usr/lib32/gconv/gconv-modules.cache /usr/lib32/gconv`;
  its paired pre-removal hook deletes that cache.
  [`12-lib32-glibc-iconvconfig.hook`](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/12-lib32-glibc-iconvconfig.hook#L1-24)
  and [`12-lib32-glibc-remove-iconvconfig-cache.hook`](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/12-lib32-glibc-remove-iconvconfig-cache.hook#L1-10).

The official package API returned empty `provides`, `conflicts`, and
`replaces` arrays for both `glibc` and `lib32-glibc`; the corresponding split
stanzas in `.SRCINFO` also declare no such fields. This describes the metadata
retrieved on the checked date. [Official `glibc` metadata](https://archlinux.org/packages/search/json/?name=glibc&repo=Core),
[official `lib32-glibc` metadata](https://archlinux.org/packages/search/json/?name=lib32-glibc),
[`.SRCINFO`, lines 50-72](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/.SRCINFO#L50-72)

## Build and test expectations

The PKGBUILD's `check()` enters `glibc-build` (not `lib32-glibc-build`),
adjusts test-build flags, removes a list of tests that the recipe attributes to
Arch build-system restrictions, then runs `make -O check`. The skipped tests
are `tst-ldconfig-cache`, `tst-pthread-gdb-attach`,
`tst-pthread-gdb-attach-static`, `test-errno-linux`, `tst-mlock2`,
`tst-ntp_gettime`, `tst-ntp_gettimex`, `tst-pkey`, `tst-mseal-pkey`,
`tst-process_mrelease`, `tst-shstk-legacy-1g`, and `tst-adjtime`. The recipe
comment says a systemd-nspawn syscall filter is the intended fix. The checked
source defines the test procedure; it is not evidence that those tests passed,
and it does not define a separate 32-bit test run.
[`check()`, lines 153-186](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L153-186)

## Facts, inferences, and safety limits for a rolling `-git` branch

**Facts from these official sources:** this revision pins one upstream commit,
packages version-matched `glibc` and `lib32-glibc` outputs, sets a 4.4 kernel
configure floor, and defines one native-build `check()` run. It also documents
a glibc/binutils/GCC rebuild cycle. None of that specifies a policy for
following an arbitrary moving branch tip. [Pinned source and version](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L9-16),
[lib32 version dependency](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L251-255),
[build-order comment](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L6-7),
[test function](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L161-186)

**Inference / not established by these recipes:** a local `-git` variant would
need an explicit update/version policy and a way to keep its 32-bit output
aligned with the matching 64-bit package. The official recipe's exact-version
dependency demonstrates the current pairing, but does not guarantee ABI
compatibility for arbitrary future commits, safe mixed-version upgrades,
coexistence with the repository package, rollback, or successful tests on a
newer source revision. The recipe also does not establish 32-bit test
coverage. Treat those as open design and validation work, not as guarantees
inherited from Arch.

**Safety:** the output is named `glibc`, the companion output depends on that
exact package version, and transaction hooks alter locale, linker, and iconv
caches. It is therefore a reasonable inference that installing a modified
`glibc` build into a normal running system is a high-impact system-library
replacement, not a side-by-side experiment; test such work in an isolated,
recoverable environment. The inspected source does not document a safe
parallel-install mode. [`PKGBUILD`, package names and dependency](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L9-16),
[lib32 hooks](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L251-277)

One source-integrity detail is worth preserving rather than assuming: the
PKGBUILD declares `validpgpkeys`, but its Git source URL uses `#commit=...`
without a `?signed` query. Arch's [`PKGBUILD(5)` documentation](https://man.archlinux.org/man/PKGBUILD.5.en)
describes the VCS `signed` query as the option that asks makepkg to check
signed VCS revisions. Thus this PKGBUILD pins a commit, but the source does
not explicitly request makepkg's signed-revision check; this report does not
claim that the pinned revision's signature was verified. The same manual
documents `validpgpkeys`. Arch's [`makepkg(8)` documentation](https://man.archlinux.org/man/makepkg.8.en)
defines `--skipinteg` as skipping checksum and PGP checks and `--skippgpcheck`
as skipping PGP checks; do not use those options to work around a verification
failure. [`PKGBUILD`, lines 29-48](https://gitlab.archlinux.org/archlinux/packaging/packages/glibc/-/blob/2d1fceaab454b56fe64092986109207839f63e4d/PKGBUILD#L29-48)

## Recommended shape and project wiring

### One recipe with split outputs

The local project has no glibc recipe or topology record. Its topology maps one
recipe ID/pkgbase to one directory, while `.SRCINFO` indexes every split
`pkgname`; the builder can therefore resolve a split output name to its owning
recipe. This matches Arch's current packaging shape and the local
`llvm-git`/`glib2-git` patterns. Add one recipe at
`packages/core/glibc-git/`, with a single pinned source revision and
`pkgver`, rather than two independently fetched/versioned recipes.
[`config/topology.conf`](../config/topology.conf),
[`docs/architecture.md`](architecture.md),
[`docs/maintainer-guide.md`](maintainer-guide.md#adding-a-recipe),
[`llvm-git/PKGBUILD`](../packages/core/llvm-git/PKGBUILD),
[`glib2-git/PKGBUILD`](../packages/core/glib2-git/PKGBUILD),
[`build-all.fish` package-name resolution fixture](../tests/project.sh#L5-L15)

Arch's current package has a third output, `glibc-locales`, in addition to the
two names in the request. To preserve the current split-package contract and
avoid leaving a separately versioned locale archive behind, include a
`glibc-locales-git` output from the same recipe, or explicitly decide how
`glibc-locales` will remain synchronized with the new base package. The Arch
locale output and 32-bit output both depend on the exact native `glibc`
version. A complete split could therefore be shaped as:

```bash
pkgbase=glibc-git
pkgname=(glibc-git lib32-glibc-git glibc-locales-git)
```

For a renamed package set, make the virtual compatibility explicit:

| Split output | Compatibility metadata to consider |
| --- | --- |
| `glibc-git` | Versioned `provides=("glibc=$pkgver")`; conflict with the stock `glibc` package. |
| `lib32-glibc-git` | Versioned `provides=("lib32-glibc=$pkgver")`; conflict with stock `lib32-glibc`; depend on the matching `glibc-git=$pkgver`. |
| `glibc-locales-git` | Versioned `provides=("glibc-locales=$pkgver")`; conflict with stock `glibc-locales`; depend on the matching `glibc-git=$pkgver`. |

Arch's current packages declare no `provides` or `conflicts` because their
names match the virtual names and installed files. A renamed local package
needs versioned `provides` entries: Arch `PKGBUILD(5)` documents that `name=version`
can satisfy `name>=version`, while this project requires versioned provides
for version-constrained dependencies. Do not add `replaces` merely by copying
a -git recipe pattern; choose that separately if automatic package-manager
replacement is intended.
[`PKGBUILD(5)`](https://man.archlinux.org/man/PKGBUILD.5.en),
[`docs/MEMORY.md` provides discipline](MEMORY.md#1-golden-rules-violations-caused-real-breakage),
[`tests/recipe-contract.sh`](../tests/recipe-contract.sh)

This metadata is needed by existing local consumers: `gcc-snapshot` has
`lib32-glibc` in `makedepends`, its `lib32-gcc-libs-snapshot` output requires
`lib32-glibc>=2.40`, and its other split outputs require `glibc>=2.40`;
`vscodium-insiders-git` requires `glibc>=2.28-4`. The new providers must sort
at or above those floors. The package's shared source/version and the exact
dependency on `glibc-git=$pkgver` keep the 64-bit, 32-bit, and locale outputs
matched.
[`gcc-snapshot/PKGBUILD`](../packages/core/gcc-snapshot/PKGBUILD#L21),
[`gcc-snapshot` 32-bit output](../packages/core/gcc-snapshot/PKGBUILD#L465-L470),
[`gcc-snapshot/.SRCINFO`](../packages/core/gcc-snapshot/.SRCINFO#L52-L55),
[`vscodium-insiders-git/.SRCINFO`](../packages/git/vscodium-insiders-git/.SRCINFO#L30)

### Topology and install behavior

Put the one recipe record in the logical `core` group; `core` is used for
heavy/ABI-coupled packages even when a physical category differs. A possible
record is:

```text
glibc-git|packages/core/glibc-git|core|linux-api-headers
```

Keep `linux-api-headers` as an edge only if the final recipe retains that
package dependency and the build-order relationship: Arch's glibc package
depends on `linux-api-headers>=4.10`, uses `/usr/include` headers, and the local
header recipe records the toolchain order beginning
`linux-api-headers -> glibc`. There is no separate topology ID or edge between
the 64-bit and 32-bit outputs because they are split from the same recipe and
installed together. The group assignment matters operationally: core packages
run alone and core selection automatically enables immediate installation
before consumers build. That is appropriate only if selecting `-g core` is
intended to install this system libc.
[`config/topology.conf` record format and ABI tags](../config/topology.conf#L1-L19),
[`linux-api-headers/PKGBUILD`](../packages/stable/linux-api-headers/PKGBUILD#L6-L16),
[`docs/build-guide.md` installation modes](build-guide.md#installation-modes),
[`README.md` group definitions](../README.md#what-is-included)

There is one deliberate graph decision. `gcc-snapshot` is a real multilib
consumer, but adding `glibc-git` to its topology edges makes every normal
selection of the glibc recipe expand to the full GCC snapshot build. That may
be desirable for a same-pass toolchain refresh, but is costly and is not
proven necessary for every glibc commit by the cited package metadata. Add
that consumer edge (and an `abi=must` tag only if omission must be gated) only
after deciding that policy. Do not add edges to every recipe merely because
its `depends` contains `glibc`: this project's edges encode local build-order
reasons and selecting a provider expands all its consumers. For contrast, the
local `systemd` recipe lists `lib32-gcc-libs` as a makedepends while its
topology row has no `gcc-snapshot` edge.
[`gcc-snapshot` topology row](../config/topology.conf#L29),
[`systemd` topology row](../config/topology.conf#L87),
[`systemd/PKGBUILD`](../packages/stable/systemd/PKGBUILD#L30-L33),
[`docs/maintainer-guide.md` coupled-stack rules](maintainer-guide.md#updating-coupled-stacks)

Every split `pkgname` must be added to the host's `[options]` `IgnorePkg`
closure so normal repository upgrades do not replace the locally maintained
outputs. This is a host configuration step, not a repository file change.
Regenerate and commit `.SRCINFO`; update the static group/recipe counts in
`README.md` and the descriptive package-name count in `tests/project.sh` from
the resulting metadata. At the completion of the research phase, no such host
or recipe changes had been made; the later implementation is recorded in
[`docs/NOTE.md`](NOTE.md#2026-10-01--split-glibc-git-package-integration).
[`docs/MEMORY.md` IgnorePkg rule](MEMORY.md#1-golden-rules-violations-caused-real-breakage),
[`tests/recipe-contract.sh` IgnorePkg lint](../tests/recipe-contract.sh),
[`README.md`](../README.md#what-is-included),
[`tests/project.sh`](../tests/project.sh#L5-L15)

### Validation boundary

For a later implementation, the repository's recipe checks are
`bash -n`, `makepkg --printsrcinfo --dir packages/core/glibc-git`,
`fish build-all.fish --audit`, `--list`, dry-runs for `core`, `stable`, and
`git`, and the full `bash tests/run-all.sh` battery. These verify syntax,
metadata, topology, and project fixtures; they do **not** prove glibc works.
Build and run upstream `make check` in a disposable Arch chroot or VM, and
perform an explicit 32-bit loader/library smoke test there: the inspected Arch
`check()` runs against `glibc-build` and does not define a separate 32-bit
test run. Do not install or replace the host's libc as part of a recipe
research or syntax-check task.
[`CONTRIBUTING.md` validation](../CONTRIBUTING.md#validation),
[`docs/architecture.md` runtime-state boundary](architecture.md)
