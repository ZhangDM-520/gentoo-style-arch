//! The build toolchain a recipe compiles with (contract §B.11).
//!
//! One type, one spelling: the topology tag (`toolchain=clang`), the
//! `--toolchain` flag and the generated makepkg configs all name the same two
//! values, so a typo is a usage error naming the alternatives rather than a
//! second vocabulary drifting from the first.
//!
//! Resolution order lives with the caller that can see all three inputs
//! (`gsa-recipe::toolchain::resolve`): the per-run flag beats the topology
//! record's tag, which beats the PKGBUILD scan's inference, which beats the
//! set's `gcc` default.

use serde::{Deserialize, Serialize};
use std::fmt;
use std::sync::OnceLock;

/// The compiler family a recipe builds with.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Toolchain {
    Gcc,
    Clang,
}

impl Toolchain {
    /// Both members, in report order.
    pub const ALL: [Toolchain; 2] = [Toolchain::Gcc, Toolchain::Clang];

    /// The set's default when no rung answers (`docs/portability.md`).
    pub const DEFAULT: Toolchain = Toolchain::Gcc;

    /// The spelling used by the flag, the tag and the config file names.
    pub fn as_str(self) -> &'static str {
        match self {
            Toolchain::Gcc => "gcc",
            Toolchain::Clang => "clang",
        }
    }

    /// The per-compiler makepkg config's file name inside a config directory.
    pub fn conf_name(self) -> &'static str {
        match self {
            Toolchain::Gcc => "gcc-makepkg.conf",
            Toolchain::Clang => "clang-makepkg.conf",
        }
    }

    /// The compiler executable the identity probe runs, when the recipe's own
    /// build does not name a different driver.
    pub fn compiler(self) -> &'static str {
        self.as_str()
    }

    /// Strict parse for a user-supplied value (`--toolchain`): the two
    /// spellings only, with the alternatives named on a miss.
    pub fn parse(value: &str) -> Result<Toolchain, String> {
        match value {
            "gcc" => Ok(Toolchain::Gcc),
            "clang" => Ok(Toolchain::Clang),
            other => Err(format!(
                "unknown toolchain '{other}' (expected one of: gcc, clang)"
            )),
        }
    }

    /// Recognize a topology tag, if it is one: `toolchain=<value>`.
    ///
    /// `None` means "not this tag family" (the loader keeps walking);
    /// `Some(Err(..))` means the family matched but the value is invalid and
    /// must be reported with the record it came from.
    pub fn parse_tag(tag: &str) -> Option<Result<Toolchain, String>> {
        tag.strip_prefix("toolchain=").map(Toolchain::parse)
    }
}

/// The run-scoped `--toolchain` choice. Set once, before dispatch, by the CLI
/// (a malformed value is refused there, so this only stores a decision); the
/// supervisor exports it to every lane child as `GSA_LANE_TOOLCHAIN`, and a
/// later call is ignored — a lane child can never re-point the run's compiler
/// mid-build, exactly like the build-root override.
static OVERRIDE: OnceLock<Toolchain> = OnceLock::new();

/// Pin the run's compiler family (`--toolchain gcc|clang`).
pub fn set_override(toolchain: Toolchain) {
    let _ = OVERRIDE.set(toolchain);
}

/// The run's pinned family, when `--toolchain` named one.
pub fn override_value() -> Option<Toolchain> {
    OVERRIDE.get().copied()
}

impl fmt::Display for Toolchain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_two_spellings_round_trip() {
        for toolchain in Toolchain::ALL {
            assert_eq!(Toolchain::parse(toolchain.as_str()), Ok(toolchain));
            assert_eq!(toolchain.conf_name(), format!("{}-makepkg.conf", toolchain));
        }
    }

    #[test]
    fn an_unknown_value_names_both_alternatives() {
        let err = Toolchain::parse("icx").unwrap_err();
        assert!(err.contains("icx"), "{err}");
        assert!(err.contains("gcc"), "{err}");
        assert!(err.contains("clang"), "{err}");
    }

    #[test]
    fn only_the_tag_family_is_recognized() {
        assert_eq!(Toolchain::parse_tag("abi=must"), None);
        assert_eq!(
            Toolchain::parse_tag("toolchain=clang"),
            Some(Ok(Toolchain::Clang))
        );
        assert!(Toolchain::parse_tag("toolchain=").unwrap().is_err());
        assert!(Toolchain::parse_tag("toolchain=GCC").unwrap().is_err());
    }
}
