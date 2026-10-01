import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { renderPatchAuthors, patchAuthorsText } from "../../site/src/patch-authors.mjs";
import * as identities from "../../site/src/author-identities.mjs";
import * as companies from "../../site/src/company-affiliations.mjs";
import { createCompanyPicker } from "../../site/src/company-picker.mjs";

// Deliberately small DOM sink. Browser verification is still required for layout,
// accessibility and native keyboard behavior; all filter logic comes from app.js.
export function dashboard(commits = []) {
  let document;
  const downloads = [];
  const objectUrls = new Map();
  const revokedUrls = [];
  let nextUrl = 0;
  class Element {
    constructor(tag = "div") { this.tagName = tag; }
    children = [];
    className = "";
    innerHTML = "";
    value = "";
    name = "";
    hidden = false;
    disabled = false;
    dataset = {};
    attributes = {};
    listeners = {};
    style = { setProperty() {} };
    scrollTop = 0;
    scrollLeft = 0;
    selectedOptions = [{ textContent: "Commits" }];
    classList = {
      toggle: (name, force) => {
        const names = new Set(this.className.split(/\s+/).filter(Boolean));
        const enabled = force ?? !names.has(name);
        if (enabled) names.add(name); else names.delete(name);
        this.className = [...names].join(" ");
        return enabled;
      },
      contains: (name) => this.className.split(/\s+/).includes(name),
    };
    get textContent() { return (this.text ?? "") + this.children.map((child) => child.textContent).join(""); }
    set textContent(value) { this.text = value; this.children = []; }
    get firstChild() { return this.children[0]; }
    appendChild(child) { child.parentElement = this; this.children.push(child); return child; }
    append(...children) { children.forEach((child) => this.appendChild(child)); }
    replaceChildren(...children) { this.children = []; this.append(...children); }
    removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
    remove() { this.parentElement.removeChild(this); }
    setAttribute(name, value) { this.attributes[name] = value; }
    getAttribute(name) { return this.attributes[name]; }
    addEventListener(event, callback) { (this.listeners[event] ??= []).push(callback); }
    dispatch(event, details = {}) {
      const value = { target: this, preventDefault() { this.defaultPrevented = true; }, ...details };
      for (const listener of this.listeners[event] ?? []) listener(value);
      return value;
    }
    focus(options) { document.activeElement = this; this.focusOptions = options; }
    click() {
      if (this.tagName === "a") downloads.push({ filename: this.download, blob: objectUrls.get(this.href), url: this.href });
      this.dispatch("click");
    }
    contains(element) { return element === this || this.children.some((child) => child.contains(element)); }
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
  document = {
    body: new Element("body"),
    activeElement: null,
    listeners: {},
    querySelector(selector) {
      if (!elements.has(selector)) {
        const element = new Element();
        if (selector === "#author-popup" || selector === "#author-clear-search") element.hidden = true;
        new Element().appendChild(element);
        elements.set(selector, element);
      }
      return elements.get(selector);
    },
    querySelectorAll: (selector) => selector === "[data-branch-preset]" ? branchPresets : [],
    createElement: (tag) => new Element(tag),
    createElementNS: (_, tag) => new Element(tag),
    addEventListener(event, callback) { (this.listeners[event] ??= []).push(callback); },
  };
  const context = vm.createContext({ ...identities, ...companies, createCompanyPicker, renderPatchAuthors, patchAuthorsText, document,
    fetch: () => new Promise(() => {}), setTimeout, Blob,
    URL: {
      createObjectURL(blob) { const url = `blob:test-${nextUrl++}`; objectUrls.set(url, blob); return url; },
      revokeObjectURL(url) { objectUrls.delete(url); revokedUrls.push(url); },
    },
  });
  let source = readFileSync(new URL("../../site/src/app.js", import.meta.url), "utf8");
  for (const declaration of [
    'import { renderPatchAuthors, patchAuthorsText } from "./patch-authors.mjs";',
    'import { buildAuthorIndex, summarizeParticipants, matchesSelectedAuthors, authorOptionLabel } from "./author-identities.mjs";',
    'import { buildCompanyIndex, commitCompanies, matchesSelectedCompanies, summarizeCompanies, verifyCompanySnapshot } from "./company-affiliations.mjs";',
    'import { createCompanyPicker } from "./company-picker.mjs";',
  ]) {
    assert.ok(source.includes(declaration), `Missing known import: ${declaration}`);
    source = source.replace(declaration, "");
  }
  assert.doesNotMatch(source, /\bimport\s*(?:[({*"']|\w)/, "Unexpected import: update the harness explicitly");
  vm.runInContext(source + `\nglobalThis.dashboard = { state, updateDerivedState, renderRecentCommits,
    renderDashboard, renderAuthorFilter, syncAuthorSelection, getFilterScopeAuthors,
    getMatchingAuthorOptions, renderAuthorSelection, updateFromAuthorSelection,
    openAuthorPopup, closeAuthorPopup, initializeControls, initializeDateInputs,
    matchingCommitRows, downloadMatchingCommits };`, context);
  const api = context.dashboard;
  api.state.data = { branches: { branches: ["master", "stable"], root_branch: "master" }, commits };
  api.state.filters.branches = new Set(["master", "stable"]);
  function reindex() {
    api.state.authorIndex = identities.buildAuthorIndex(api.state.data.commits);
    api.state.authorScope = null;
  }
  reindex();
  api.initializeControls();
  return { ...api, document, elements, branchPresets, reindex, downloads, objectUrls, revokedUrls,
    element: (selector) => document.querySelector(selector),
    render() {
      reindex();
      api.updateDerivedState();
      api.renderRecentCommits();
      return Array.from(elements.get("#recent-commits-body").children, (row) => row.innerHTML);
    },
  };
}
