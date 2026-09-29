import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { renderPatchAuthors } from "../../site/src/patch-authors.mjs";
import * as identities from "../../site/src/author-identities.mjs";

// Deliberately small DOM sink. Browser verification is still required for layout,
// accessibility and native keyboard behavior; all filter logic comes from app.js.
export function dashboard(commits = []) {
  let document;
  class Element {
    constructor(tag = "div") { this.tagName = tag; }
    children = [];
    innerHTML = "";
    value = "";
    name = "";
    dataset = {};
    attributes = {};
    listeners = {};
    style = { setProperty() {} };
    scrollTop = 0;
    scrollLeft = 0;
    selectedOptions = [{ textContent: "Commits" }];
    get textContent() { return (this.text ?? "") + this.children.map((child) => child.textContent).join(""); }
    set textContent(value) { this.text = value; this.children = []; }
    get firstChild() { return this.children[0]; }
    appendChild(child) { child.parentElement = this; this.children.push(child); return child; }
    append(...children) { children.forEach((child) => this.appendChild(child)); }
    removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
    remove() { this.parentElement.removeChild(this); }
    setAttribute(name, value) { this.attributes[name] = value; }
    getAttribute(name) { return this.attributes[name]; }
    addEventListener(event, callback) { (this.listeners[event] ??= []).push(callback); }
    dispatch(event) { for (const listener of this.listeners[event] ?? []) listener({ target: this }); }
    focus(options) { document.activeElement = this; this.focusOptions = options; }
    querySelectorAll(selector) {
      return this.children.flatMap((child) => [
        ...(child.tagName === selector || (selector.startsWith(".") && child.className === selector.slice(1)) ? [child] : []),
        ...child.querySelectorAll(selector),
      ]);
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
  }
  const elements = new Map();
  const presets = (kind, values) => values.map((value) => {
    const button = new Element("button");
    button.dataset[`${kind}Preset`] = value;
    return button;
  });
  const branchPresets = presets("branch", ["all", "stable", "root"]);
  const authorPresets = presets("author", ["visible", "clear"]);
  document = {
    activeElement: null,
    querySelector(selector) {
      if (!elements.has(selector)) {
        const element = new Element();
        new Element().appendChild(element);
        elements.set(selector, element);
      }
      return elements.get(selector);
    },
    querySelectorAll: (selector) => selector === "[data-branch-preset]" ? branchPresets : authorPresets,
    createElement: (tag) => new Element(tag),
    createElementNS: (_, tag) => new Element(tag),
  };
  const context = vm.createContext({ ...identities, renderPatchAuthors, document,
    fetch: () => new Promise(() => {}),
  });
  let source = readFileSync(new URL("../../site/src/app.js", import.meta.url), "utf8");
  for (const declaration of [
    'import { renderPatchAuthors } from "./patch-authors.mjs";',
    'import { buildAuthorIndex, summarizeParticipants, matchesSelectedAuthors, authorOptionLabel, authorOptionDescription } from "./author-identities.mjs";',
  ]) {
    assert.ok(source.includes(declaration), `Missing known import: ${declaration}`);
    source = source.replace(declaration, "");
  }
  assert.doesNotMatch(source, /\bimport\s*(?:[({*"']|\w)/, "Unexpected import: update the harness explicitly");
  vm.runInContext(source + `\nglobalThis.dashboard = { state, updateDerivedState, renderRecentCommits,
    renderDashboard, renderAuthorFilter, syncAuthorSelection, getFilterScopeAuthors,
    getMatchingAuthorOptions, initializeControls, initializeDateInputs };`, context);
  const api = context.dashboard;
  api.state.data = { branches: { branches: ["master", "stable"], root_branch: "master" }, commits };
  api.state.filters.branches = new Set(["master", "stable"]);
  function reindex() {
    api.state.authorIndex = identities.buildAuthorIndex(api.state.data.commits);
    api.state.authorScope = null;
  }
  reindex();
  api.initializeControls();
  return { ...api, document, elements, branchPresets, authorPresets, reindex,
    element: (selector) => document.querySelector(selector),
    render() {
      reindex();
      api.updateDerivedState();
      api.renderRecentCommits();
      return Array.from(elements.get("#recent-commits-body").children, (row) => row.innerHTML);
    },
  };
}
