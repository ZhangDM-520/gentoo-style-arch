//! Source candidacy for the v1 fetch-ahead (owner decision 3): classify a
//! recipe's `source=()` entries with `gsa-recipe`'s classifier — never
//! grep — and decide what fetch-ahead may touch.
//!
//! v1 prefetches plain-URL sources only:
//! - a recipe with ≥1 plain-URL (non-VCS) source is a candidate; mixed
//!   recipes (tarball + VCS source) ARE prefetched — their plain sources at
//!   least, and a VCS side effect of `makepkg --verifysource` is acceptable
//!   (plan.md Q3),
//! - a pure-VCS recipe is `skipped vcs-only` (its mirrors come from the
//!   build itself / `-Mm`),
//! - a recipe with no fetchable source (none at all, or local files only)
//!   is `skipped not-a-candidate`.

use gsa_recipe::{RecipeMeta, SourceKind};

use crate::verdict::{FetchResult, FetchVerdict, REASON_NOT_A_CANDIDATE, REASON_VCS_ONLY};

/// What fetch-ahead may do for one recipe.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FetchCandidacy {
    /// At least one plain-URL source: prefetch target. The field lists the
    /// download names makepkg will place in SRCDEST (alias name when the
    /// entry uses `name::location`, else the URL basename).
    Plain(Vec<String>),
    /// Every source is a VCS checkout (git/svn/bzr/hg).
    VcsOnly,
    /// Nothing to fetch: no sources, or local files only.
    NoFetchable,
}

impl FetchCandidacy {
    /// The skip verdict for a non-candidate, if any (own vocabulary).
    pub fn skip_verdict(&self, pkg: &str) -> Option<FetchResult> {
        let reason = match self {
            FetchCandidacy::Plain(_) => return None,
            FetchCandidacy::VcsOnly => REASON_VCS_ONLY,
            FetchCandidacy::NoFetchable => REASON_NOT_A_CANDIDATE,
        };
        FetchResult::new(pkg, FetchVerdict::Skipped, 0, reason).ok()
    }
}

/// The download name makepkg uses for one source entry: the `name::` alias
/// when present, else the URL basename without query/fragment.
pub fn source_filename(source: &gsa_recipe::ClassifiedSource) -> String {
    if let Some(name) = &source.name {
        return name.clone();
    }
    let location = source
        .location
        .split_once('?')
        .map(|(before, _)| before)
        .unwrap_or(&source.location);
    let location = location
        .split_once('#')
        .map(|(before, _)| before)
        .unwrap_or(location);
    location.rsplit('/').next().unwrap_or(location).to_string()
}

/// Classify one recipe's sources (contract §D owner decision 3: the
/// `gsa-recipe` source classification, never grep).
pub fn classify(meta: &RecipeMeta) -> FetchCandidacy {
    let mut plain: Vec<String> = Vec::new();
    let mut vcs = 0usize;
    for source in meta.sources() {
        match source.kind {
            SourceKind::Vcs(_) => vcs += 1,
            SourceKind::Remote => plain.push(source_filename(&source)),
            SourceKind::Local => {}
        }
    }
    if !plain.is_empty() {
        FetchCandidacy::Plain(plain)
    } else if vcs > 0 {
        FetchCandidacy::VcsOnly
    } else {
        FetchCandidacy::NoFetchable
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gsa_recipe::{parse_srcinfo, MetaSource, RecipeMeta};

    fn meta_from_srcinfo(content: &str) -> RecipeMeta {
        let info = parse_srcinfo(content, "test").unwrap();
        RecipeMeta {
            id: gsa_model::RecipeId::new("pkg").unwrap(),
            path: "packages/git/pkg".to_string(),
            srcinfo: Some(info),
            scanned: None,
            source: MetaSource::Srcinfo,
        }
    }

    #[test]
    fn pure_vcs_recipes_are_vcs_only() {
        let meta = meta_from_srcinfo(
            "pkgbase = pkg\npkgname = pkg\nsource = git+https://example.com/x.git\n",
        );
        assert_eq!(classify(&meta), FetchCandidacy::VcsOnly);
        let verdict = classify(&meta).skip_verdict("pkg").unwrap();
        assert_eq!(verdict.verdict, FetchVerdict::Skipped);
        assert_eq!(verdict.reason, "vcs-only");
    }

    #[test]
    fn mixed_recipes_are_candidates_with_their_plain_sources() {
        let meta = meta_from_srcinfo(
            "pkgbase = pkg\npkgname = pkg\nsource = https://example.com/a-1.0.tar.gz\nsource = git+https://example.com/x.git\nsource = fix.patch\n",
        );
        assert_eq!(
            classify(&meta),
            FetchCandidacy::Plain(vec!["a-1.0.tar.gz".to_string()])
        );
        assert!(classify(&meta).skip_verdict("pkg").is_none());
    }

    #[test]
    fn local_only_or_empty_recipes_are_not_a_candidate() {
        let meta = meta_from_srcinfo("pkgbase = pkg\npkgname = pkg\nsource = fix.patch\n");
        assert_eq!(classify(&meta), FetchCandidacy::NoFetchable);
        assert_eq!(
            classify(&meta).skip_verdict("pkg").unwrap().reason,
            "not-a-candidate"
        );
        let meta = meta_from_srcinfo("pkgbase = pkg\npkgname = pkg\n");
        assert_eq!(classify(&meta), FetchCandidacy::NoFetchable);
    }

    #[test]
    fn filenames_use_the_alias_or_the_url_basename() {
        assert_eq!(
            source_filename(&gsa_recipe::classify_source(
                "foo.tar.gz::https://h/a/b.tar.gz"
            )),
            "foo.tar.gz"
        );
        assert_eq!(
            source_filename(&gsa_recipe::classify_source(
                "https://h/a/b-1.0.tar.gz?download=1"
            )),
            "b-1.0.tar.gz"
        );
        assert_eq!(
            source_filename(&gsa_recipe::classify_source("git+https://h/a/b.git#tag")),
            "b.git"
        );
    }
}
