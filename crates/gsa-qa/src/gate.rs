//! The install-seam hook (contract §E.1/E.4, `docs/MEMORY.md` rule 20):
//! the ONE decision seam's row stream gains `refuse <keyword> …` rows from
//! the registry's install-refusing checks — never a second seam, never a
//! re-decision.
//!
//! Severity enforcement lives in the TYPES here: [`refuse_rows`] accepts a
//! `Check<MayRefuse>` and nothing else. A report-only check (`Check<ReportOnly>`,
//! the five audit lints) cannot be passed to it — there is no conversion
//! from a report finding to a decision row anywhere in this crate — so
//! CONTEXT.md's "Audit lint is report-only by contract" is un-representable
//! to violate.

use gsa_model::{Decision, DecisionRow};

use crate::{registry, Check, MayRefuse, QaInput};

/// The ONLY construction of a `refuse` decision row from QA findings
/// (contract §E.3: a `refuse` row's reason is `any severity: refuse QA
/// keyword` + detail). The `Check<MayRefuse>` parameter is the enforcement:
/// the five lints are `Check<ReportOnly>` and cannot reach this function.
fn refuse_rows(check: &Check<MayRefuse>, input: &QaInput<'_>) -> Vec<DecisionRow> {
    check
        .run(input)
        .findings
        .iter()
        .map(|finding| DecisionRow {
            subject: finding.subject.clone(),
            decision: Decision::Refuse,
            reason: format!("{} {}", finding.check, finding.detail),
        })
        .collect()
}

/// Every install-refusing check's rows for this input, in registry order.
/// `gsa-install`'s `plan()` splices these into its decision rows at the QA
/// gate (after the fail-closed gates it already owns, before the force/
/// checked branch — force bypasses only the same-version skip, never a
/// gate); `--install-decide` prints them like any other row (§E.5 rc 1).
pub fn install_refusals(input: &QaInput<'_>) -> Vec<DecisionRow> {
    registry()
        .refusing_checks()
        .iter()
        .flat_map(|check| refuse_rows(check, input))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::{QaArchive, QaRecipe};
    use gsa_recipe::parse_srcinfo_rows;

    fn recipe(id: &str, srcinfo: &str) -> QaRecipe {
        QaRecipe {
            id: id.to_string(),
            dir: std::path::PathBuf::from(format!("/w/{id}")),
            rows: parse_srcinfo_rows(srcinfo, "test").unwrap(),
        }
    }

    /// A stale archive: its `.PKGINFO` names a pkgbase the recipe never
    /// declares. `Pkginfo` fields are public (gsa-recipe).
    fn stale_archive(recipe_id: &str) -> QaArchive {
        QaArchive {
            recipe_id: recipe_id.to_string(),
            path: std::path::PathBuf::from(format!("/w/{recipe_id}/x.pkg.tar.zst")),
            pkginfo: Some(gsa_recipe::pkginfo::Pkginfo {
                pkgbase: "ghost-old".to_string(),
                pkgname: recipe_id.to_string(),
                version: "1.0.0-1".to_string(),
                arch: "any".to_string(),
                provides: Vec::new(),
                depends: Vec::new(),
            }),
        }
    }

    #[test]
    fn the_refusing_check_emits_refuse_rows_with_the_keyword_first() {
        let recipes = vec![recipe("foo", "pkgbase = foo\npkgname = foo\n")];
        let archives = vec![stale_archive("foo")];
        let input = QaInput {
            recipes: &recipes,
            targets: &[],
            archives: &archives,
            installed: &[],
            exclusions: &[],
        };
        let rows = install_refusals(&input);
        assert_eq!(
            rows.len(),
            1,
            "exactly the undeclared name refuses: {rows:?}"
        );
        assert_eq!(rows[0].decision, Decision::Refuse);
        assert_eq!(rows[0].subject, "ghost-old");
        assert!(
            rows[0].reason.starts_with("stale-ignorepkg "),
            "the §E.4 keyword must lead the reason: {}",
            rows[0].reason
        );
        assert!(
            rows[0].reason.ends_with("not-declared"),
            "{}",
            rows[0].reason
        );
    }

    #[test]
    fn report_findings_never_become_decision_rows() {
        // A recipe breaking THREE report lints (purged tool, versioned
        // soname provide, unversioned mapped swap provide) and an
        // inconsistent archive: the lints produce findings, yet the only
        // refuse rows come from the refusing check.
        let recipes = vec![recipe(
            "foo",
            "pkgbase = foo\npkgname = foo\nprovides = libx.so.1\nmakedepends = cuda\n",
        )];
        let archives = vec![stale_archive("foo")];
        let input = QaInput {
            recipes: &recipes,
            targets: &[],
            archives: &archives,
            installed: &[],
            exclusions: &[],
        };
        let report: Vec<_> = crate::report::report_findings(&input)
            .into_iter()
            .map(|f| f.check.to_string())
            .collect();
        assert!(
            report.contains(&"purged-tools".to_string()),
            "the staged violation must be seen: {report:?}"
        );
        assert!(
            report.contains(&"provides-versioning".to_string()),
            "the staged violation must be seen: {report:?}"
        );
        let rows = install_refusals(&input);
        assert_eq!(
            rows.len(),
            1,
            "report findings must never add decision rows: {rows:?}"
        );
        assert!(rows[0].reason.starts_with("stale-ignorepkg "));
    }
}
