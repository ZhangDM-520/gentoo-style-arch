//! The report surface (contract §E.4): `report`-severity findings appended
//! to the run record's prose summary.
//!
//! §H.2 choice (recorded per the deliverable): the machine block gains ONLY
//! the additive extension scalar `qa-findings: N` — the same "extension
//! scalar after the fixed set" precedent as `prefetch-warnings` — so
//! `format: 2` stays valid and no row grammar changes. The finding LINES
//! themselves live in the record structure (prose-only rendering), keeping
//! ADR 0003's "one record, three renderings" true.

use crate::{registry, Finding, QaInput};

/// Every report-severity check's findings over this input (registry order;
/// each check's findings are deduped and sorted). Install-refusing checks
/// never contribute here — they speak through decision rows at the install
/// seam ([`crate::gate`]).
pub fn report_findings(input: &QaInput<'_>) -> Vec<Finding> {
    registry()
        .report_checks()
        .iter()
        .flat_map(|check| check.run(input).findings)
        .collect()
}

/// The prose-summary lines of the report surface (rendered by `gsa-cli`'s
/// summary as its final block).
pub fn render_lines(findings: &[Finding]) -> Vec<String> {
    findings.iter().map(|finding| finding.render()).collect()
}
