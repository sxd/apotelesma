export function patchAuthors(commit) {
  const authors = [commit.trailer_author, commit.co_authored_by]
    .flatMap((values) => Array.isArray(values) ? values : [])
    .filter((value) => typeof value === "string")
    .map((value) => value.trim())
    .filter(Boolean);
  return [...new Set(authors)];
}

export function renderPatchAuthors(commit) {
  const authors = patchAuthors(commit);
  if (authors.length === 0) return "—";

  const escaped = authors.map((value) => value.replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;"));
  return `<ul class="patch-authors">${escaped.map((value) => `<li>${value}</li>`).join("")}</ul>`;
}
