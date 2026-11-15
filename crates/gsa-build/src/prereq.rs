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
}

/// The tools every build the engine issues requires from the host.
pub const REQUIRED_HOST_TOOLS: [HostTool; 1] = [HostTool {
    program: "fakeroot",
    package: "fakeroot",
}];

/// The first required tool absent from this process's PATH — the PATH a lane
/// inherits, because the build-user drop preserves it. `None` when all are
/// present; the ONE lookup is `gsa_recipe::toolchain::on_path` (`type -p`
/// semantics), never a second copy.
pub fn missing() -> Option<&'static HostTool> {
    REQUIRED_HOST_TOOLS
        .iter()
        .find(|tool| !gsa_recipe::toolchain::on_path(tool.program))
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
        with_path(|_| assert_eq!(missing(), Some(&REQUIRED_HOST_TOOLS[0])));
    }

    #[test]
    fn a_non_executable_file_of_the_right_name_is_not_a_tool() {
        with_path(|dir| {
            // A 0644 file is not `type -p`-visible: the probe must never be
            // satisfied by a name it could not run.
            std::fs::write(dir.join("fakeroot"), b"#!/bin/sh\n").unwrap();
            assert!(missing().is_some(), "a 0644 file is not a tool");
            std::fs::set_permissions(dir.join("fakeroot"), std::fs::Permissions::from_mode(0o755))
                .unwrap();
            assert_eq!(missing(), None);
        });
    }
}
