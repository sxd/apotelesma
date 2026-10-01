const nonblank = (value) => typeof value === "string" ? value.trim() : "";

// Keep in sync with primary_author_source in author_company_history.py.
// Shared regression cases exercise both implementations.
export function primaryAuthorSource(commit) {
  if (Array.isArray(commit.trailer_author) && commit.trailer_author.some(nonblank)) return "trailer_author";
  if (typeof commit.message !== "string") return "missing_message";
  if (/^[ \t]*Author[ \t]*:/im.test(commit.message)) return "unextracted_author";
  if (nonblank(commit.author_name) || nonblank(commit.author_email)) return "git_author_fallback";
  return "missing_git_author";
}

export function gitAuthorCredit(commit) {
  const name = nonblank(commit.author_name);
  const email = nonblank(commit.author_email);
  return email ? `${name ? `${name} ` : ""}<${email}>` : name;
}

export function patchAuthors(commit) {
  const primary = primaryAuthorSource(commit) === "git_author_fallback" ? [gitAuthorCredit(commit)] : commit.trailer_author;
  const authors = [primary, commit.co_authored_by]
    .flatMap((values) => Array.isArray(values) ? values : [])
    .filter((value) => typeof value === "string")
    .map((value) => value.trim())
    .filter(Boolean);
  return [...new Set(authors)];
}

export function renderPatchAuthors(commit) {
  const authors = patchAuthors(commit);
  if (authors.length === 0) return "—";

  const fallback = primaryAuthorSource(commit) === "git_author_fallback" ? gitAuthorCredit(commit) : null;
  const escaped = authors.map((value) => value.replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;") + (value === fallback ? " <small>(commit-author fallback)</small>" : ""));
  return `<ul class="patch-authors">${escaped.map((value) => `<li>${value}</li>`).join("")}</ul>`;
}
