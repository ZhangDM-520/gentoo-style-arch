//! The built-in makepkg configuration bodies (contract §B.11).
//!
//! The engine stops honouring `/etc/makepkg.conf`: every lane is handed
//! `makepkg --config <generated composite>` whose content is built from these
//! bodies plus the site's `/etc/gsa/*` files plus the build user's
//! `~/.config/gsa/*` clone. These constants are the FLOOR — the rung that
//! always exists, so an engine upgrade ahead of the `gsa-pm` recipe that ships
//! `/etc/gsa/` still builds — and every higher layer simply assigns the same
//! shell variables again.
//!
//! Two kinds of body, deliberately separate:
//!
//! * [`UNIVERSAL`] — settings that are the same whichever compiler runs
//!   (`CARCH`, `BUILDENV`, `OPTIONS`, strip/purge/compress, download and VCS
//!   agents). It is sourced first by every composite.
//! * [`GCC`] / [`CLANG`] — the compiler-specific flag sets. A recipe appends
//!   package-specific deltas to `$CFLAGS`/`$CXXFLAGS`/`$LDFLAGS`; the base
//!   values come from here, never from the host's makepkg.conf.
//!
//! `BUILDDIR`/`PKGDIR`/`PKGDEST`/`SRCDEST` are deliberately absent: the
//! composite re-asserts them from the engine's own environment at the end, so
//! no config file can re-point the build cache (one ladder per setting,
//! rule 73).

use crate::toolchain::Toolchain;

/// Settings that hold for either compiler. Sourced before the per-compiler
/// body, so a site file overriding e.g. `OPTIONS` (but not flags) only has to
/// carry that one assignment.
pub const UNIVERSAL: &str = "\
# gsa universal makepkg settings (built-in — override in /etc/gsa/<compiler>-makepkg.conf)
CARCH=\"x86_64\"
CHOST=\"x86_64-pc-linux-gnu\"
BUILDENV=(!distcc color ccache !check !sign)
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto !autodeps)
INTEGRITY_CHECK=(sha256)
PKGEXT='.pkg.tar.zst'
SRCEXT='.src.tar.gz'

# rustc is not a gcc/clang flag: native codegen belongs to BOTH families, so it
# lives here rather than in a per-compiler body. makepkg never exports
# RUSTFLAGS (its buildenv list is CPPFLAGS/CFLAGS/CXXFLAGS/LDFLAGS), so
# `render` exports it after the bodies — otherwise cargo, a child process,
# never sees it. A recipe that assigns RUSTFLAGS itself still wins.
# The link arg is the other half of the same problem: cargo never reads
# LDFLAGS either, so a recipe that only runs cargo linked with the default
# bfd while every C object in the same build went through mold. rustc's
# default linker driver is cc, so `-C link-arg` reaches the driver's
# `-fuse-ld=`; the tests keep it equal to what the family bodies ship.
RUSTFLAGS=\"-C opt-level=3 -C target-cpu=native -C link-arg=-fuse-ld=mold\"

STRIP_BINARIES=\"--strip-all\"
STRIP_SHARED=\"--strip-unneeded\"
STRIP_STATIC=\"--strip-debug\"
MAN_DIRS=(usr{,/local}{,/share}/{man,info})
DOC_DIRS=(usr/{,local/}{,share/}{doc,gtk-doc})
PURGE_TARGETS=(usr/{,share}/info/dir .packlist *.pod)
DBGSRCDIR=\"/usr/src/debug\"
LIB_DIRS=('lib:usr/lib' 'lib32:usr/lib32')
COMPRESSGZ=(gzip -c -f -n)
COMPRESSBZ2=(bzip2 -c -f)
COMPRESSXZ=(xz -c -z -)
COMPRESSZST=(zstd -c -T0 -)
COMPRESSLZ=(lzip -c -f)
COMPRESSLRZ=(lrzip -q)
COMPRESSLZO=(lzop -q)
COMPRESSZ=(compress -c -f)
DLAGENTS=('file::/usr/bin/curl -qgC - -o %o %u'
          'ftp::/usr/bin/curl -qgfC - --ftp-pasv --retry 3 --retry-delay 3 -o %o %u'
          'http::/usr/bin/curl -qgb \"\" -fLC - --retry 3 --retry-delay 3 -o %o %u'
          'https::/usr/bin/curl -qgb \"\" -fLC - --retry 3 --retry-delay 3 -o %o %u'
          'rsync::/usr/bin/rsync --no-motd -z %u %o'
          'scp::/usr/bin/scp -C %u %o')
VCSCLIENTS=('bzr::breezy'
            'fossil::fossil'
            'git::git'
            'hg::mercurial'
            'svn::subversion')
";

/// GCC's flag set: the host's proven line (`/etc/makepkg.conf` before the
/// rework) plus `FFLAGS`, which is why a Fortran recipe never needs its own
/// drop-in again.
///
/// `-march=native`/`-mtune=native` rather than a pinned `znver5`: identical
/// codegen on this host, but a body that does not silently mis-tune a reader's
/// machine (docs/portability.md). `-fipa-pta` and `-fprefetch-loop-arrays` are
/// off at `-O3` and are the two passes 133 recipes used to append by hand;
/// clang rejects the first and ignores the second, which is exactly why they
/// live in THIS body and not in [`UNIVERSAL`]. `-fira-hoist-pressure` and
/// `-fstack-reuse=all` are gcc defaults at `-O3` and are deliberately absent
/// (shipping them would only be noise).
pub const GCC: &str = "\
# gsa gcc makepkg settings (built-in — override in /etc/gsa/gcc-makepkg.conf)
CFLAGS=\"-march=native -mtune=native -O3 -pipe -fno-plt -fno-semantic-interposition \\
        -fstrict-aliasing -funroll-loops -falign-functions=32 -falign-loops=32 \\
        -ffp-contract=fast -mprefer-vector-width=256 -fcf-protection=none \\
        -fipa-pta -fprefetch-loop-arrays -fno-math-errno -fno-trapping-math \\
        -Wp,-D_FORTIFY_SOURCE=3 -Wno-ignored-attributes\"
# `-fvisibility-inlines-hidden` is C++-only: gcc warns about it in C.
CXXFLAGS=\"$CFLAGS -fvisibility-inlines-hidden\"
FFLAGS=\"-march=native -mtune=native -O3 -pipe -funroll-loops -ffp-contract=fast \\
        -fno-semantic-interposition\"
FCFLAGS=\"$FFLAGS\"
# `-z,now` is its own token on purpose: xorg-server strips `-Wl,-z,now` with a
# single-slash substitution (Arch bug 55102/54845) and keeps working untouched.
LDFLAGS=\"-fuse-ld=mold -Wl,-O1 -Wl,--sort-common -Wl,--as-needed \\
         -Wl,-z,relro -Wl,-z,now -Wl,-z,pack-relative-relocs\"
LTOFLAGS=\"-flto=auto\"
DEBUG_CFLAGS=\"-g\"
DEBUG_CXXFLAGS=\"$DEBUG_CFLAGS\"
";

/// clang's flag set: the same policy expressed with flags clang actually
/// accepts — no `-fipa-pta`-class GCC-only switches and no
/// `-fprefetch-loop-arrays` (clang accepts that spelling only to ignore it).
/// `RUSTFLAGS` is NOT here: rustc's target belongs to both families, so it
/// lives in [`UNIVERSAL`]; `FFLAGS` is GCC's because clang has no Fortran
/// driver, and the split is asserted by `compiler()`'s tests.
pub const CLANG: &str = "\
# gsa clang makepkg settings (built-in — override in /etc/gsa/clang-makepkg.conf)
CFLAGS=\"-march=native -mtune=native -O3 -pipe -fno-plt -fno-semantic-interposition \\
        -fstrict-aliasing -funroll-loops -falign-functions=32 -falign-loops=32 \\
        -ffp-contract=fast -mprefer-vector-width=256 -fcf-protection=none \\
        -fno-math-errno -fno-trapping-math -Wp,-D_FORTIFY_SOURCE=3 \\
        -Wno-ignored-attributes\"
# `-fvisibility-inlines-hidden` is C++-only: clang warns about it in C.
CXXFLAGS=\"$CFLAGS -fvisibility-inlines-hidden\"
LDFLAGS=\"-fuse-ld=mold -Wl,-O1 -Wl,--sort-common -Wl,--as-needed \\
         -Wl,-z,relro -Wl,-z,now -Wl,-z,pack-relative-relocs\"
LTOFLAGS=\"-flto=thin\"
DEBUG_CFLAGS=\"-g\"
DEBUG_CXXFLAGS=\"$DEBUG_CFLAGS\"
";

/// The built-in per-compiler body.
pub fn compiler(toolchain: Toolchain) -> &'static str {
    match toolchain {
        Toolchain::Gcc => GCC,
        Toolchain::Clang => CLANG,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_engine_never_sets_the_paths_it_owns() {
        // BUILDDIR/PKGDIR/PKGDEST/SRCDEST are re-asserted from the engine's
        // own environment; a built-in body that set them would make a config
        // file the owner of the build cache again (rule 73).
        for body in [UNIVERSAL, GCC, CLANG] {
            for owned in ["BUILDDIR=", "PKGDIR=", "PKGDEST=", "SRCDEST="] {
                assert!(
                    !body.lines().any(|l| l.starts_with(owned)),
                    "built-in body sets {owned}: {body}"
                );
            }
        }
    }

    #[test]
    fn gcc_carries_fortran_and_the_universal_body_carries_rust() {
        // rustc is not a compiler family: its target lives where both
        // families read it. Fortran is gcc's alone (clang has no driver).
        assert!(GCC.contains("FFLAGS="));
        assert!(!GCC.contains("RUSTFLAGS="));
        assert!(!CLANG.contains("RUSTFLAGS="));
        assert!(!CLANG.contains("FFLAGS="));
        assert!(UNIVERSAL.contains("RUSTFLAGS="));
        assert!(UNIVERSAL.contains("-C target-cpu=native"));
    }

    #[test]
    fn the_rust_linker_tracks_the_c_bodies_linker() {
        // cargo never reads LDFLAGS, so a recipe that only runs `cargo` used
        // to link with the default bfd while every C object went through
        // mold. The universal RUSTFLAGS carries the same `-fuse-ld=` the
        // family bodies ship, so one body decides the linker for both
        // languages and a body edit cannot leave Rust behind.
        let rustflags = UNIVERSAL
            .lines()
            .find(|line| line.starts_with("RUSTFLAGS=\""))
            .expect("the universal body assigns RUSTFLAGS");
        for body in [GCC, CLANG] {
            let ldf = body
                .lines()
                .find(|line| line.starts_with("LDFLAGS=\""))
                .expect("the family body assigns LDFLAGS");
            let linker = ldf
                .trim_start_matches("LDFLAGS=\"")
                .split_whitespace()
                .find_map(|token| token.strip_prefix("-fuse-ld="))
                .expect("the family body names a linker");
            let rust_arg = format!("-C link-arg=-fuse-ld={linker}");
            assert!(
                rustflags.contains(&rust_arg),
                "RUSTFLAGS does not link with {linker}: {rustflags}"
            );
        }
    }

    #[test]
    fn no_body_pins_one_machines_isa() {
        // `-march=native` keeps today's codegen (znver5 here) while a reader's
        // machine is tuned for itself; a literal target in a shipped body is
        // exactly the promise docs/portability.md makes.
        for body in [UNIVERSAL, GCC, CLANG] {
            assert!(!body.contains("znver"), "{body}");
            assert!(!body.contains("march=x86-64"), "{body}");
        }
        assert!(GCC.contains("-march=native -mtune=native"));
        assert!(CLANG.contains("-march=native -mtune=native"));
    }

    #[test]
    fn flags_clang_rejects_stay_out_of_the_clang_body() {
        // `-fipa-pta` is a GCC-only switch; a clang lane inheriting it dies
        // at the first translation unit. `-fprefetch-loop-arrays` is worse:
        // clang accepts the spelling and silently ignores it, so shipping it
        // there is a lie about the codegen.
        for gcc_only in [
            "-fipa-pta",
            "-fira-hoist-pressure",
            "-fstack-reuse",
            "-fprofile-",
            "-fgraphite-identity",
            "-floop-nest-optimize",
        ] {
            assert!(!CLANG.contains(gcc_only), "clang body carries {gcc_only}");
        }
        // The GCC body is allowed both real passes; the defaults it must NOT
        // name are asserted separately.
        assert!(GCC.contains("-fipa-pta"));
        assert!(GCC.contains("-fprefetch-loop-arrays"));
        for already_default in ["-fira-hoist-pressure", "-fstack-reuse"] {
            assert!(
                !GCC.contains(already_default),
                "GCC body ships {already_default}"
            );
        }
        assert!(compiler(Toolchain::Clang) == CLANG);
        assert!(compiler(Toolchain::Gcc) == GCC);
    }
}

/// The generated composite's file name inside the build-cache root. One per
/// toolchain, content independent of jobs and recipe, so concurrent lanes
/// cannot race its content (they write the same bytes).
pub fn lane_conf_name(toolchain: Toolchain) -> String {
    format!("lane-makepkg-{toolchain}.conf")
}

/// Render the composite makepkg is handed via `--config` (contract §B.11).
///
/// Order, lowest precedence first:
///
/// 1. the built-in universal body,
/// 2. the built-in per-compiler body,
/// 3. every site file in `sources`, in source order (baseline, then the
///    build user's clone) — an assignment in a later file wins,
/// 4. the engine-owned paths and job flags, re-asserted from the `GSA_LANE_*`
///    environment so no config file can re-point the build cache.
///
/// `gsa.conf` is deliberately NOT sourced: it is the engine's strict
/// `key = value` file, not shell. Universal makepkg settings are overridden in
/// the per-compiler body, which every lane sources.
pub fn render(toolchain: Toolchain, sources: &[std::path::PathBuf]) -> String {
    let mut body = String::new();
    body.push_str("# gsa lane makepkg.conf (generated — do not edit; contract §B.11)\n");
    body.push_str("# Replaces makepkg's own config layering: the engine owns the flags.\n");
    body.push_str(UNIVERSAL);
    body.push('\n');
    body.push_str(compiler(toolchain));
    for source in sources {
        // A site file is optional by design: a half-populated directory is a
        // legal site (only gcc tuned, say).
        body.push_str(&format!(
            "[ -r '{path}' ] && source '{path}'\n",
            path = shell_single_quote(&source.display().to_string())
        ));
    }
    body.push_str(
        "\
# engine-owned, re-asserted AFTER any site file:
BUILDDIR=\"${GSA_LANE_BUILDDIR:-$BUILDDIR}\"
PKGDIR=\"${GSA_LANE_PKGDIR:-$PKGDIR}\"
PKGDEST=\"${GSA_LANE_PKGDEST:-$PKGDEST}\"
SRCDEST=\"${GSA_LANE_SRCDEST:-$SRCDEST}\"
MAKEFLAGS=\"${GSA_LANE_MAKEFLAGS:-$MAKEFLAGS}\"
NINJAFLAGS=\"${GSA_LANE_NINJAFLAGS:-$NINJAFLAGS}\"
# makepkg exports its buildenv list (CPPFLAGS/CFLAGS/CXXFLAGS/LDFLAGS, plus
# FFLAGS for Fortran) but never RUSTFLAGS, so a `RUSTFLAGS=` assignment in a
# config file would reach build() and stop there. Export it here or cargo — a
# child process — never sees the native codegen the body asked for.
export RUSTFLAGS
",
    );
    body
}

/// Quote a path for the generated shell. Paths are engine-resolved, but a
/// build-directory name can legitimately contain a quote, and a broken
/// generated file would fail every lane with a shell syntax error instead of
/// a named refusal.
fn shell_single_quote(value: &str) -> String {
    value.replace('\'', "'\\''")
}

/// Write the composite for one toolchain under `root` via temp + rename and
/// return its path. Idempotent: concurrent lanes write identical bytes.
pub fn install(root: &std::path::Path, toolchain: Toolchain) -> Result<std::path::PathBuf, String> {
    let (_, sources) = crate::config::makepkg_conf_sources(toolchain)?;
    let body = render(toolchain, &sources);
    // The fetch path installs the composite BEFORE any lane creates the
    // cache, so the root is materialized here — with the ownership handoff,
    // or the build-user's makepkg could not read its own config.
    crate::config::create_owned_dir(root)?;
    let path = root.join(lane_conf_name(toolchain));
    let tmp = root.join(format!(
        ".{}.tmp-{}",
        lane_conf_name(toolchain),
        std::process::id()
    ));
    std::fs::write(&tmp, body).map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("cannot install {}: {e}", path.display()))?;
    Ok(path)
}

#[cfg(test)]
mod render_tests {
    use super::*;

    #[test]
    fn the_composite_layers_builtins_then_site_files_then_the_engine_paths() {
        let sources = vec![
            std::path::PathBuf::from("/etc/gsa/gcc-makepkg.conf"),
            std::path::PathBuf::from("/home/u/.config/gsa/gcc-makepkg.conf"),
        ];
        let body = render(Toolchain::Gcc, &sources);
        let builtin = body.find("gsa universal makepkg settings").unwrap();
        let baseline = body.find("/etc/gsa/gcc-makepkg.conf").unwrap();
        let user = body.find("/home/u/.config/gsa/gcc-makepkg.conf").unwrap();
        let paths = body.find("BUILDDIR=\"${GSA_LANE_BUILDDIR").unwrap();
        assert!(
            builtin < baseline && baseline < user && user < paths,
            "{body}"
        );
        // The host's config is never sourced.
        assert!(!body.contains("/etc/makepkg.conf"));
        assert!(!body.contains(".makepkg.conf"));
    }

    #[test]
    fn a_missing_site_file_is_guarded_not_fatal() {
        let body = render(
            Toolchain::Clang,
            &[std::path::PathBuf::from("/nope/x.conf")],
        );
        assert!(body.contains("[ -r '/nope/x.conf' ] && source '/nope/x.conf'"));
    }

    #[test]
    fn the_composite_never_sources_the_engine_key_file() {
        // `gsa.conf` is key = value; sourcing it would print
        // "build_dir: command not found" into every lane log.
        let body = render(Toolchain::Gcc, &[]);
        assert!(!body.contains("gsa.conf"));
    }

    #[test]
    fn the_composite_exports_rustflags_after_every_assignment() {
        // makepkg exports its buildenv list and nothing else; without this
        // line a config-file RUSTFLAGS reaches build() and stops there, so
        // cargo keeps its generic target — the whole point of the universal
        // body would be lost for every recipe that does not prefix cargo.
        let sources = vec![std::path::PathBuf::from("/etc/gsa/gcc-makepkg.conf")];
        let body = render(Toolchain::Gcc, &sources);
        let set = body
            .find("\nRUSTFLAGS=\"")
            .expect("the universal body assigns RUSTFLAGS");
        let site = body.find("/etc/gsa/gcc-makepkg.conf").unwrap();
        let export = body.find("\nexport RUSTFLAGS\n").unwrap();
        assert!(set < site && site < export, "{body}");
        assert!(body.ends_with("export RUSTFLAGS\n"), "{body}");
    }
}
