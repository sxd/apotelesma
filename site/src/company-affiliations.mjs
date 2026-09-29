// Only accepted, dated matches are exported. A missing row means no usable
// affiliation evidence, never "unaffiliated" or "independent".
export const companyCommitKey = (commit) => JSON.stringify([commit.branch, commit.commit_id]);

export function buildCompanyIndex(snapshot, commits) {
  const invalid = () => { throw new Error("Invalid company affiliation snapshot"); };
  if (snapshot?.schema_version !== 1 || !["committer", "author"].includes(snapshot.provenance?.timestamp_basis)
      || !Array.isArray(snapshot.companies) || !Array.isArray(snapshot.matches)
      || snapshot.coverage?.total_commits !== commits.length
      || snapshot.coverage?.matched_commits !== snapshot.matches.length
      || !Number.isSafeInteger(snapshot.coverage?.researched_people) || snapshot.coverage.researched_people < 0) invalid();
  const companies = new Map();
  for (const company of snapshot.companies) {
    if (typeof company.company_id !== "string" || !company.company_id || typeof company.name !== "string" || !company.name
        || !Array.isArray(company.aliases) || company.aliases.some((alias) => typeof alias !== "string")
        || companies.has(company.company_id)) invalid();
    companies.set(company.company_id, { ...company, searchText: [company.name, ...company.aliases].join("\n").toLowerCase() });
  }
  const keys = new Set(commits.map(companyCommitKey));
  const matches = new Map();
  for (const row of snapshot.matches) {
    const key = companyCommitKey(row);
    if (!keys.has(key) || matches.has(key) || !Array.isArray(row.companies) || !row.companies.length) invalid();
    const seen = new Set();
    for (const item of row.companies) {
      if (!companies.has(item.company_id) || !["supported", "estimated"].includes(item.status) || seen.has(item.company_id)) invalid();
      seen.add(item.company_id);
    }
    matches.set(key, row.companies);
  }
  return { companies, matches, coverage: snapshot.coverage, provenance: snapshot.provenance };
}

export function commitCompanies(commit, index, includeEstimated = true) {
  return (index?.matches.get(companyCommitKey(commit)) ?? [])
    .filter((item) => includeEstimated || item.status === "supported");
}

export function matchesSelectedCompanies(commit, selected, index, includeEstimated = true) {
  return selected.size === 0 || commitCompanies(commit, index, includeEstimated).some((item) => selected.has(item.company_id));
}

export function summarizeCompanies(commits, index, includeEstimated = true) {
  if (!index) return { options: [], matched: 0, total: commits.length };
  const counts = new Map([...index.companies.keys()].map((id) => [id, 0]));
  let matched = 0;
  for (const commit of commits) {
    const affiliations = commitCompanies(commit, index, includeEstimated);
    if (affiliations.length) matched += 1;
    for (const item of affiliations) counts.set(item.company_id, counts.get(item.company_id) + 1);
  }
  const options = [...index.companies.values()].map((company) => ({ ...company, count: counts.get(company.company_id) }))
    .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
  return { options, matched, total: commits.length };
}

export async function verifyCompanySnapshot(snapshot, commitText) {
  const expected = snapshot?.provenance?.input_sha256?.commit_snapshot_sha256;
  const digest = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(commitText));
  const actual = [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  if (expected !== actual) throw new Error("Company affiliations belong to a different commit snapshot");
}
