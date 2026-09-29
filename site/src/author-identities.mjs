// Deliberately supports ASCII dot-atom mailboxes and DNS-style domains only.
// Quoted locals, comments, lists and other RFC forms remain opaque evidence.
const atom = "[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+";
const mailbox = new RegExp(`^${atom}(?:\\.${atom})*@(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*$`);
const roleNames = { git: "Git author", author: "Author trailer", coauthor: "Co-authored-by trailer" };
const roleOrder = Object.keys(roleNames);
const nonblank = (value) => typeof value === "string" ? value.trim() : "";

// Unicode code-point order, independent of locale and input order.
function lexical(left, right) {
  const a = Array.from(left, (character) => character.codePointAt(0));
  const b = Array.from(right, (character) => character.codePointAt(0));
  for (let i = 0; i < Math.min(a.length, b.length); i += 1) {
    if (a[i] !== b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

function normalizeEmail(value) {
  const email = nonblank(value);
  if (!mailbox.test(email)) return null;
  const at = email.indexOf("@");
  return email.slice(0, at + 1) + email.slice(at + 1).toLowerCase();
}

function displayName(value) {
  const name = nonblank(value);
  return /^"[^"\r\n]*"$/.test(name) ? name.slice(1, -1) : name;
}

function identityParts(raw, email = null, name = "") {
  return {
    key: JSON.stringify([email ? "email" : "unresolved", email ?? raw.trim()]),
    resolution: email ? "email" : "unresolved", email, name, raw,
  };
}

export function parsePatchIdentity(value) {
  const raw = nonblank(value);
  if (!raw) return null;
  const bareEmail = normalizeEmail(raw);
  if (bareEmail) return identityParts(value, bareEmail);
  const match = raw.match(/^([^<>]+)<([^<>]+)>$/);
  if (match && !/[\x00-\x1f\x7f-\x9f]/.test(match[1])) {
    const recordedName = match[1].trim();
    // A quoted display name can contain list punctuation; an unquoted list or
    // unbalanced quote must not turn its final mailbox into a resolved identity.
    const supportedName = /^"[^"\r\n]+"$/.test(recordedName) || !/[,;"@]/.test(recordedName);
    const email = normalizeEmail(match[2]);
    // Whitespace inside the angle pair is unsupported, not silently repaired.
    if (supportedName && email && match[2] === match[2].trim()) {
      const name = displayName(match[1]);
      if (name.trim()) return identityParts(value, email, name);
    }
  }
  return identityParts(value);
}

export function buildAuthorIndex(commits) {
  const identities = new Map();
  const participation = new WeakMap();
  for (const commit of commits) {
    const row = new Map();
    const add = (parsed, role, evidence = []) => {
      if (!parsed) return;
      let identity = identities.get(parsed.key);
      if (!identity) {
        identity = { key: parsed.key, resolution: parsed.resolution, email: parsed.email,
          raw: parsed.raw.trim(), aliases: new Set(), names: new Set(), emails: new Set(),
          roles: new Set(), patchNames: new Set(), gitNames: new Set() };
        identities.set(parsed.key, identity);
      }
      for (const alias of [parsed.raw, ...evidence]) {
        if (nonblank(alias)) identity.aliases.add(alias);
      }
      if (parsed.name) {
        identity.names.add(parsed.name);
        identity[role === "git" ? "gitNames" : "patchNames"].add(parsed.name);
      }
      if (parsed.email) identity.emails.add(parsed.email);
      identity.roles.add(role);
      if (!row.has(parsed.key)) row.set(parsed.key, new Set());
      row.get(parsed.key).add(role);
    };
    const name = nonblank(commit.author_name);
    const rawEmail = nonblank(commit.author_email);
    const email = normalizeEmail(commit.author_email);
    if (email || name || rawEmail) {
      add(identityParts(name || rawEmail, email, email ? displayName(name) : ""), "git",
        [commit.author_name, commit.author_email]);
    }
    for (const [field, role] of [["trailer_author", "author"], ["co_authored_by", "coauthor"]]) {
      if (Array.isArray(commit[field])) {
        for (const value of commit[field]) add(parsePatchIdentity(value), role);
      }
    }
    participation.set(commit, row);
  }
  for (const identity of identities.values()) {
    for (const field of ["aliases", "names", "emails", "patchNames", "gitNames"]) {
      identity[field] = [...identity[field]].sort(lexical);
    }
    identity.roles = roleOrder.filter((role) => identity.roles.has(role));
    if (identity.resolution === "email") identity.raw = identity.aliases[0].trim();
    identity.name = identity.patchNames[0] ?? identity.gitNames[0] ?? "";
    identity.searchText = [...identity.aliases, ...identity.names, ...identity.emails].join("\n").toLowerCase();
  }
  return { identities, participation };
}

export function authorOptionLabel(identity) {
  if (identity.resolution === "unresolved") return identity.raw;
  if (identity.roles.some((role) => role !== "git")) {
    return identity.name ? `${identity.name} <${identity.email}>` : identity.email;
  }
  return identity.name || "Unnamed Git author";
}

export function authorOptionDescription(identity, scopedRoles) {
  const roles = (values) => roleOrder.filter((role) => values.includes(role)).map((role) => roleNames[role]).join(", ");
  const resolution = identity.resolution === "unresolved"
    ? "Grouped by exact recorded text; no verified email identity."
    : `Email identity: ${identity.email}. Grouped by shared email; shared mailboxes and conflicting names do not prove one person.`;
  return `${resolution} Global recorded roles: ${roles(identity.roles)}. Roles in this scope: ${roles(scopedRoles)}.`;
}

export function summarizeParticipants(scopedCommits, index) {
  const summaries = new Map();
  for (const commit of scopedCommits) {
    for (const [key, roles] of index.participation.get(commit) ?? []) {
      let summary = summaries.get(key);
      if (!summary) {
        summary = { key, identity: index.identities.get(key), count: 0, latestDate: "", roles: new Set() };
        summaries.set(key, summary);
      }
      summary.count += 1;
      if (commit.author_date > summary.latestDate) summary.latestDate = commit.author_date;
      for (const role of roles) summary.roles.add(role);
    }
  }
  return [...summaries.values()].map((summary) => ({ ...summary,
    roles: roleOrder.filter((role) => summary.roles.has(role)),
  })).sort((a, b) => b.count - a.count || lexical(b.latestDate, a.latestDate) || lexical(a.key, b.key));
}

export function matchesSelectedAuthors(commit, selectedKeys, index) {
  if (selectedKeys.size === 0) return true;
  for (const key of index.participation.get(commit)?.keys() ?? []) {
    if (selectedKeys.has(key)) return true;
  }
  return false;
}
