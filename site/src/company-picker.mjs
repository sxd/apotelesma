// Compact native-checkbox picker. Selections survive search and scope changes;
// selecting a zero-count company must never silently broaden the results.
export function createCompanyPicker({ document, selected, onChange }) {
  const find = (id) => document.querySelector(`#company-${id}`);
  const picker = find("picker"), search = find("search"), popup = find("popup");
  const list = find("filter"), chips = find("selected"), clear = find("clear-selection");
  const clearSearch = find("clear-search"), done = find("done"), count = find("suggestion-count");
  let options = [], visible = [], suppressOpen = false;
  const label = (id) => options.find((item) => item.company_id === id)?.name ?? id;
  const node = (tag, className, text) => {
    const element = document.createElement(tag);
    element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  };
  function renderSelection() {
    chips.replaceChildren();
    if (!selected.size) chips.appendChild(node("span", "author-all", "All companies"));
    for (const id of selected) {
      const chip = node("span", "author-chip");
      const remove = node("button", "", "×");
      remove.type = "button";
      remove.setAttribute("aria-label", `Remove company ${label(id)}`);
      remove.addEventListener("click", () => { toggle(id); search.focus(); });
      chip.append(node("span", "author-chip-label", label(id)), remove);
      chips.appendChild(chip);
    }
    clear.disabled = selected.size === 0;
  }
  function syncOptions() {
    for (const input of list.querySelectorAll("input")) {
      input.checked = selected.has(input.value);
      input.parentElement.classList.toggle("chosen", input.checked);
    }
  }
  function toggle(id) {
    if (selected.has(id)) selected.delete(id); else selected.add(id);
    renderSelection();
    syncOptions();
    onChange();
  }
  function renderOptions() {
    const focused = list.contains(document.activeElement) ? document.activeElement.value : null;
    const scroll = list.scrollTop;
    const terms = search.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    const matches = options.filter((item) => terms.every((term) => item.searchText.includes(term)));
    visible = matches.slice(0, 8);
    clearSearch.hidden = search.value.length === 0;
    count.textContent = `${visible.length} of ${matches.length}`;
    list.replaceChildren();
    if (!visible.length) list.appendChild(node("p", "author-empty", options.length ? "No matching companies." : "No usable company affiliations in this snapshot yet."));
    for (const item of visible) {
      const row = node("label", "author-option");
      const input = node("input", "");
      input.type = "checkbox";
      input.name = "company";
      input.value = item.company_id;
      input.addEventListener("change", () => toggle(item.company_id));
      const total = node("span", "author-count", `${item.count.toLocaleString("en-US")} commit${item.count === 1 ? "" : "s"}`);
      total.setAttribute("aria-hidden", "true");
      row.append(input, node("span", "author-option-name", item.name), total);
      list.appendChild(row);
    }
    syncOptions();
    if (focused) [...list.querySelectorAll("input")].find((input) => input.value === focused)?.focus({ preventScroll: true });
    list.scrollTop = scroll;
  }
  function open() {
    if (search.disabled) return;
    popup.hidden = false;
    search.setAttribute("aria-expanded", "true");
    renderOptions();
  }
  function close(returnFocus = false) {
    popup.hidden = true;
    search.setAttribute("aria-expanded", "false");
    if (returnFocus) {
      suppressOpen = true;
      search.focus({ preventScroll: true });
      suppressOpen = false;
    }
  }
  search.addEventListener("focus", () => { if (!suppressOpen) open(); });
  search.addEventListener("click", open);
  search.addEventListener("input", () => { list.scrollTop = 0; open(); });
  search.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") { event.preventDefault(); open(); list.querySelector("input")?.focus(); }
    if (event.key === "Enter") {
      event.preventDefault();
      if (popup.hidden) open(); else if (visible[0]) toggle(visible[0].company_id);
    }
    if (event.key === "Escape") { event.preventDefault(); close(); }
  });
  popup.addEventListener("keydown", (event) => {
    if (event.key === "Escape") { event.preventDefault(); close(true); return; }
    const inputs = [...list.querySelectorAll("input")];
    if (event.target === done && event.key === "ArrowUp") { event.preventDefault(); inputs.at(-1)?.focus(); return; }
    if (event.target.type !== "checkbox" || !["ArrowDown", "ArrowUp"].includes(event.key)) return;
    event.preventDefault();
    const index = inputs.indexOf(event.target) + (event.key === "ArrowDown" ? 1 : -1);
    if (index < 0) search.focus(); else (inputs[index] ?? done).focus();
  });
  clearSearch.addEventListener("click", () => { search.value = ""; list.scrollTop = 0; open(); search.focus(); });
  clear.addEventListener("click", () => { selected.clear(); renderSelection(); syncOptions(); onChange(); search.focus(); });
  done.addEventListener("click", () => close(true));
  document.addEventListener("pointerdown", (event) => { if (!picker.contains(event.target)) close(); });
  picker.addEventListener("focusout", (event) => {
    if (event.relatedTarget && picker.contains(event.relatedTarget)) return;
    setTimeout(() => { if (!picker.contains(document.activeElement)) close(); }, 0);
  });
  return {
    update(nextOptions, available) {
      options = nextOptions;
      search.disabled = !available;
      if (!available) close();
      renderSelection();
      renderOptions();
    },
  };
}
