import assert from "node:assert/strict";
import test from "node:test";
import { parsePatchIdentity, buildAuthorIndex, summarizeParticipants, matchesSelectedAuthors, authorOptionLabel, authorOptionDescription } from "../site/src/author-identities.mjs";

const key = (email) => JSON.stringify(["email", email]);
const unresolved = (text) => JSON.stringify(["unresolved", text]);
const row = (fields = {}) => ({ author_date: "2026-01-01T00:00:00Z", branch: "master", ...fields });

test("complete supported mailboxes, conservative normalization and preserved names", () => {
  for (const [input, email, name] of [
    ["  Bare+tag@EXAMPLE.test  ", "Bare+tag@example.test", ""],
    ['"Surname, Given" <person@example.test>', "person@example.test", "Surname, Given"],
    ["  Áda  O'Neil <a.b+tag@EXAMPLE.test> ", "a.b+tag@example.test", "Áda  O'Neil"],
    ["Name<person@example.test>", "person@example.test", "Name"],
  ]) {
    const parsed = parsePatchIdentity(input);
    assert.equal(parsed.key, key(email));
    assert.equal(parsed.email, email);
    assert.equal(parsed.name, name);
    assert.equal(parsed.raw, input);
  }
});

test("opaque prose, unsupported RFC forms and hostile values stay whole", () => {
  for (const value of ["Adam Lee, Jeff Davis", "A and B", "Name <a@b> (editor)",
    "a@b,c@d", "a@b;c@d", "a@@b", "a@", "@b", "a b@c", "a\u0000@b", "a@b\nc",
    '"quoted local"@example.test', "a(comment)@b", "a@[127.0.0.1]", "<a@b>", "A <<a@b>>",
    "A < a@b>", "a..b@c", '<script>alert("x")</script>', '["email","a@b"]']) {
    assert.equal(parsePatchIdentity(` ${value} `).key, unresolved(value), value);
  }
  for (const value of [undefined, null, {}, [], 42, "", " \t\n"]) assert.equal(parsePatchIdentity(value), null);
});

test("an invalid mailbox list or unbalanced name is never partially resolved", () => {
  for (const value of ['bare@x, Name <person@x>', 'One, Two <person@x>',
    'One; Two <person@x>', '"Unclosed <person@x>', '" " <person@x>',
    'First <first@x>, Last <last@x>']) {
    assert.equal(parsePatchIdentity(value).key, unresolved(value));
  }
});

test("Git and patch labels, shared email across roles, once per branch/commit row", () => {
  const commits = [
    row({ author_name: "Git Only", author_email: "git@EXAMPLE.test" }),
    row({ author_name: "Git Alias", author_email: "same@example.test", commit_id: "same",
      trailer_author: ["Patch Name <same@EXAMPLE.test>", "Patch Name <same@example.test>"],
      co_authored_by: ["Co Name <same@example.test>", "Patch Only <patch@example.test>"] }),
  ];
  commits.push({ ...commits[1], branch: "stable" });
  const before = JSON.stringify(commits);
  const index = buildAuthorIndex(commits);
  assert.equal(index.identities.size, 3);
  assert.equal(authorOptionLabel(index.identities.get(key("git@example.test"))), "Git Only");
  assert.equal(authorOptionLabel(index.identities.get(key("patch@example.test"))), "Patch Only <patch@example.test>");
  const shared = index.identities.get(key("same@example.test"));
  assert.equal(authorOptionLabel(shared), "Co Name <same@example.test>");
  assert.deepEqual(shared.roles, ["git", "author", "coauthor"]);
  assert.deepEqual(shared.names, ["Co Name", "Git Alias", "Patch Name"]);
  assert.ok(shared.aliases.includes("Patch Name <same@EXAMPLE.test>"));
  assert.deepEqual([...index.participation.get(commits[1]).get(shared.key)], ["git", "author", "coauthor"]);
  const summary = summarizeParticipants(commits, index).find((item) => item.key === shared.key);
  assert.equal(summary.key, shared.key);
  assert.equal(summary.count, 2);
  assert.deepEqual(summary.roles, shared.roles);
  assert.equal(JSON.stringify(commits), before);
});

test("deterministic global labels, scoped roles, lexical ties and all alias search evidence", () => {
  const commits = [
    row({ author_name: "AAA Git", author_email: "same@example.test" }),
    row({ trailer_author: ["Zulu <same@example.test>", "Áda <same@example.test>"] }),
    row({ co_authored_by: ["Beta <same@example.test>"] }),
  ];
  const index = buildAuthorIndex(commits);
  const reversed = buildAuthorIndex([...commits].reverse());
  assert.deepEqual(index.identities.get(key("same@example.test")), reversed.identities.get(key("same@example.test")));
  for (const scope of [commits, [commits[0]], [commits[2]]]) {
    assert.equal(authorOptionLabel(summarizeParticipants(scope, index)[0].identity), "Beta <same@example.test>");
  }
  const description = authorOptionDescription(index.identities.get(key("same@example.test")), ["git"]);
  assert.match(description, /Roles in this scope: Git author\./);
  assert.doesNotMatch(description, /Global recorded/);
  assert.doesNotMatch(description, /Email identity|shared mailboxes/);
  assert.match(index.identities.get(key("same@example.test")).searchText, /aaa git/);
  assert.deepEqual(summarizeParticipants(commits, index)[0].roles, ["git", "author", "coauthor"]);
});

test("summaries sort by count, latest date, then key; primary names use Unicode code points", () => {
  const commits = [row({ trailer_author: ["b@x", "a@x", "c@x"] }),
    row({ author_date: "2026-02-01", trailer_author: ["c@x", "d@x"] }),
    row({ trailer_author: ["\u{10000} Name <unicode@x>", "\uE000 Name <unicode@x>"] })];
  const index = buildAuthorIndex(commits);
  assert.deepEqual(summarizeParticipants(commits, index).map((summary) => summary.key),
    [key("c@x"), key("d@x"), key("a@x"), key("b@x"), key("unicode@x")]);
  assert.equal(authorOptionLabel(index.identities.get(key("unicode@x"))), "\uE000 Name <unicode@x>");
  assert.deepEqual(summarizeParticipants([], index), []);
  const reverseIndex = buildAuthorIndex([...commits].reverse());
  for (const [identityKey, identity] of index.identities) assert.deepEqual(identity, reverseIndex.identities.get(identityKey));
});

test("malformed patch arrays are ignored independently", () => {
  for (const value of [undefined, null, {}, "Unexpected <unexpected@x>", 3, [null, {}, 7, "", " \t\n"]]) {
    const index = buildAuthorIndex([row({ trailer_author: value, co_authored_by: ["Expected <expected@x>"] })]);
    assert.deepEqual([...index.identities.keys()], [key("expected@x")]);
  }
});

test("local case, distinct addresses, exact unresolved grouping and no name-based joins", () => {
  const commits = [row({ author_name: "Same", author_email: "A@EXAMPLE.test",
    trailer_author: ["Same <A@example.test>", "Same <a@example.test>", "Same <other@example.test>", " Same "],
    co_authored_by: ["Same"] }), row({ author_name: "Same", author_email: "invalid" })];
  const index = buildAuthorIndex(commits);
  assert.deepEqual([...index.identities.keys()].sort(), [key("A@example.test"), key("a@example.test"), key("other@example.test"), unresolved("Same")].sort());
  const identity = index.identities.get(unresolved("Same"));
  assert.equal(authorOptionLabel(identity), "Same");
  assert.deepEqual(identity.roles, ["git", "author", "coauthor"]);
  assert.equal(summarizeParticipants(commits, index)[0].count, 2);
  assert.match(authorOptionDescription(identity, identity.roles), /Grouped by exact recorded text\./);
  assert.ok(identity.aliases.includes("invalid"));
});

test("Git fields are normalized directly; malformed fields cannot invent identities", () => {
  const commits = [row({ author_email: "only@EXAMPLE.test" }),
    row({ author_name: null, author_email: "Name <not-a-git-mailbox@example.test>" }),
    row({ author_name: "Fallback", author_email: "bad@" }),
    row({ author_name: {}, author_email: null }),
    row({ author_name: " ", author_email: "", trailer_author: "Ignore <ignore@x>", co_authored_by: [null, 1, "", " \n"] }),
    row({ reviewed_by: ["Reviewer <review@x>"], reported_by: ["Reporter <report@x>"], mentioned_people: ["Mention <mention@x>"] }),
  ];
  const index = buildAuthorIndex(commits);
  assert.equal(index.identities.size, 3);
  assert.equal(authorOptionLabel(index.identities.get(key("only@example.test"))), "Unnamed Git author");
  assert.doesNotMatch(authorOptionDescription(index.identities.get(key("only@example.test")), ["git"]), /Email identity|only@example.test/);
  assert.ok(index.identities.has(unresolved("Name <not-a-git-mailbox@example.test>")));
  assert.ok(index.identities.has(unresolved("Fallback")));
});

test("per-row matching uses OR across roles and empty selection is unrestricted", () => {
  const commits = [row({ author_email: "a@b" }), row({ trailer_author: ["a@b"] }),
    row({ co_authored_by: ["a@b"] }), row({ trailer_author: ["c@d"] }), row()];
  const index = buildAuthorIndex(commits);
  assert.deepEqual(commits.map((commit) => matchesSelectedAuthors(commit, new Set([key("a@b")]), index)), [true, true, true, false, false]);
  assert.deepEqual(commits.map((commit) => matchesSelectedAuthors(commit, new Set([key("a@b"), key("c@d")]), index)), [true, true, true, true, false]);
  assert.ok(commits.every((commit) => matchesSelectedAuthors(commit, new Set(), index)));
});
