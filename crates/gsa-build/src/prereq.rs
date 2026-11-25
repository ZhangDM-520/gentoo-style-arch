//! The host binaries makepkg needs before it can START a build.
//!
//! makepkg's own `check_software` gate (`/usr/share/makepkg/executable/*.sh`)
//! refuses at setup with `E_MISSING_MAKEPKG_DEPS` (15) when a required host
//! binary is absent, printing `Cannot find the <tool> binary.` The build never
//! begins — yet a lane could only report that as a plain build failure, whose
//! rc 4 is the code for a real compile failure and whose cause survives only
//! in the package log. This module is the pre-dispatch half of the answer: the
//! engine asks the question makepkg asks, on the PATH a lane inherits (the
//! build-user drop preserves PATH — `gsa_model::privilege`), so the run is
//! refused naming the tool instead of blaming the recipe (R2-maya-2).
//!
//! The roster is deliberately ONE entry. `fakeroot` is the only
//! `check_software` guard that is unconditional: `executable_fakeroot` runs
//! whenever `BUILDPKG` is set, and every lane is spawned as `makepkg -sf`
//! (`MAKEPKG_BASE_ARGS`). The other guards follow configuration the engine
//! does not exclusively own — `strip`/`zipman` from `OPTIONS`, `<alg>sum` from
//! `INTEGRITY_CHECK`, `debugedit` behind `debug`, VCS clients per recipe — so
//! gating them here would refuse runs that legitimately never ask for them.
//! Those land as the lane's typed `host-prerequisite-missing` reason instead
//! (`lane::classify_build_exit`), where makepkg's own exit is the only truth
//! available.

/// One host binary a build cannot start without, and the package providing it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HostTool {
    /// The program name as makepkg's own `type -p` asks for it.
    pub program: &'static str,
    /// The Arch package that ships it (the remedy a refusal names).
    pub package: &'static str,
    /// Why the build cannot start without it, in one clause.
    pub why: &'static str,
}

/// The tools every build the engine issues requires from the host.
pub const REQUIRED_HOST_TOOLS: [HostTool; 2] = [
    HostTool {
        program: "fakeroot",
        package: "fakeroot",
        why: "makepkg's setup gate requires it",
    },
    HostTool {
        program: "mold",
        package: "mold",
        why: "the effective makepkg configuration links with it (-fuse-ld=mold)",
    },
];

/// The first required tool absent from this process's PATH — the PATH a lane
/// inherits, because the build-user drop preserves it. `None` when all are
/// present; the ONE lookup is `gsa_recipe::toolchain::on_path` (`type -p`
/// semantics), never a second copy.
///
/// `families` are the compiler families this run can actually build with
/// (the run override, each selected record's declared tag, the default). The
/// mold entry is required only when a family's EFFECTIVE configuration links
/// with it: the shipped body names it, but `LDFLAGS`/`RUSTFLAGS` in
/// `/etc/gsa/<family>-makepkg.conf` or `extra_ldflags` in `gsa.conf` decide,
/// and refusing a host that links with lld would be a false refusal. An
/// unreadable configuration resolves to "requires mold": fail-closed, because
/// the refusal names an installable package and a wrong silence costs a
/// build.
pub fn missing(families: &[gsa_model::toolchain::Toolchain]) -> Option<&'static HostTool> {
    REQUIRED_HOST_TOOLS
        .iter()
        .find(|tool| !gsa_recipe::toolchain::on_path(tool.program) && required(tool, families))
}

/// Is this tool required by the run? `fakeroot` always; `mold` when an
/// effective linker line names it.
fn required(tool: &HostTool, families: &[gsa_model::toolchain::Toolchain]) -> bool {
    if tool.program != "mold" {
        return true;
    }
    families.iter().any(|family| linker_names_mold(*family))
}

/// Does this family's effective build environment link with mold?
///
/// The composite [`gsa_model::makepkg_conf::render_with`] produces is what a
/// lane sources, so the probe sources the same bytes with the `GSA_LANE_*`
/// re-assertions unset and reads the resulting `LDFLAGS`/`RUSTFLAGS`. Taking
/// the composite apart textually would miss a site body that assigns rather
/// than extends; sourcing is the only faithful read, and every lane already
/// sources these files.
fn linker_names_mold(toolchain: gsa_model::toolchain::Toolchain) -> bool {
    let (_, sources) = match gsa_model::config::makepkg_conf_sources(toolchain) {
        Ok(resolved) => resolved,
        Err(_) => return true,
    };
    let flags = match gsa_model::config::extra_build_flags() {
        Ok(flags) => flags,
        Err(_) => return true,
    };
    let body = gsa_model::makepkg_conf::render_with(toolchain, &sources, &flags);
    let path = std::env::temp_dir().join(format!(
        "gsa-linker-probe-{}-{toolchain}.conf",
        std::process::id()
    ));
    if std::fs::write(&path, body).is_err() {
        return true;
    }
    let output = std::process::Command::new("bash")
        .env("LC_ALL", "C")
        .arg("-c")
        .arg("source \"$1\" >/dev/null 2>&1 || exit 3; printf '%s\\n%s\\n' \"$LDFLAGS\" \"$RUSTFLAGS\"")
        .arg("gsa-linker-probe")
        .arg(&path)
        .output();
    let _ = std::fs::remove_file(&path);
    let output = match output {
        Ok(output) if output.status.success() => output,
        _ => return true,
    };
    let text = String::from_utf8_lossy(&output.stdout);
    text.lines().any(|line| last_linker(line) == Some("mold"))
}

/// The linker the line ends up using: the LAST `-fuse-ld=` token wins, which
/// is how gcc and rustc read a repeated flag (an `extra_ldflags` appended
/// after the shipped `-fuse-ld=mold` replaces it).
fn last_linker(line: &str) -> Option<&str> {
    line.split_whitespace()
        .filter_map(|token| token.strip_prefix("-fuse-ld="))
        .next_back()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// PATH is process-global: these tests serialize.
    static ENV_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn with_path(f: impl FnOnce(&std::path::Path)) {
        let _guard = ENV_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = std::env::temp_dir().join(format!("gsa-prereq-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let saved = std::env::var_os("PATH");
        std::env::set_var("PATH", &dir);
        f(&dir);
        std::env::set_var("PATH", saved.unwrap_or_default());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_empty_path_reports_every_required_tool() {
        with_path(|_| {
            assert_eq!(
                missing(&[gsa_model::toolchain::Toolchain::Gcc]),
                Some(&REQUIRED_HOST_TOOLS[0])
            );
            assert_eq!(REQUIRED_HOST_TOOLS.len(), 2);
        });
    }

    #[test]
    fn the_shipped_body_links_with_mold() {
        assert!(linker_names_mold(gsa_model::toolchain::Toolchain::Gcc));
        assert!(linker_names_mold(gsa_model::toolchain::Toolchain::Clang));
    }

    #[test]
    fn a_site_config_that_links_elsewhere_does_not_require_mold() {
        let _guard = ENV_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = std::env::temp_dir().join(format!("gsa-prereq-conf-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // A site that replaces BOTH linker lines: gcc's C links and rustc's
        // link-arg. Refusing this host for a missing mold would be a false
        // refusal — it links with lld.
        for family in ["gcc", "clang"] {
            std::fs::write(
                dir.join(format!("{family}-makepkg.conf")),
                "LDFLAGS=\"-fuse-ld=lld\"\nRUSTFLAGS=\"-C link-arg=-fuse-ld=lld\"\n",
            )
            .unwrap();
        }
        let saved_conf = std::env::var_os("GSA_CONF_DIR");
        let saved_path = std::env::var_os("PATH");
        std::env::set_var("GSA_CONF_DIR", &dir);
        std::env::set_var("PATH", &dir);
        let answered = missing(&[gsa_model::toolchain::Toolchain::Gcc]);
        std::env::set_var("GSA_CONF_DIR", saved_conf.unwrap_or_default());
        std::env::set_var("PATH", saved_path.unwrap_or_default());
        let _ = std::fs::remove_dir_all(&dir);
        // fakeroot is still absent, but mold is not required by this config.
        assert_eq!(
            answered.map(|tool| tool.program),
            Some("fakeroot"),
            "mold was required from a host that links with lld"
        );
    }

    #[test]
    fn a_non_executable_file_of_the_right_name_is_not_a_tool() {
        with_path(|dir| {
            // A 0644 file is not `type -p`-visible: the probe must never be
            // satisfied by a name it could not run.
            for tool in ["fakeroot", "mold"] {
                std::fs::write(dir.join(tool), b"#!/bin/sh\n").unwrap();
            }
            assert!(
                missing(&[gsa_model::toolchain::Toolchain::Gcc]).is_some(),
                "a 0644 file is not a tool"
            );
            for tool in ["fakeroot", "mold"] {
                std::fs::set_permissions(dir.join(tool), std::fs::Permissions::from_mode(0o755))
                    .unwrap();
            }
            assert_eq!(missing(&[gsa_model::toolchain::Toolchain::Gcc]), None);
        });
    }
}
