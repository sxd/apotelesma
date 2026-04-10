const DATA_FILES = {
  branches: "./data/branches.json",
  commits: "./data/commits.json",
};

const BRANCH_COLORS = [
  "#d16a3b",
  "#20504b",
  "#74503d",
  "#4a6a8a",
  "#8b3b56",
  "#5d7a31",
  "#9f6d1a",
  "#4d4f8a",
];

const state = {
  data: null,
  filteredCommits: [],
  filteredAuthors: [],
  filters: {
    branches: new Set(),
    authors: new Set(),
    startDate: "",
    endDate: "",
    metric: "commit_count",
  },
};

const branchFilter = document.querySelector("#branch-filter");
const authorFilter = document.querySelector("#author-filter");
const authorSearch = document.querySelector("#author-search");
const startDateInput = document.querySelector("#start-date");
const endDateInput = document.querySelector("#end-date");
const metricSelect = document.querySelector("#metric-select");
const branchPresetButtons = Array.from(document.querySelectorAll("[data-branch-preset]"));
const authorPresetButtons = Array.from(document.querySelectorAll("[data-author-preset]"));
const statsGrid = document.querySelector("#stats-grid");
const branchSummaryBody = document.querySelector("#branch-summary-body");
const authorActivityBody = document.querySelector("#author-activity-body");
const recentCommitsBody = document.querySelector("#recent-commits-body");
const dailyChart = document.querySelector("#daily-chart");
const authorChart = document.querySelector("#author-chart");
const branchChart = document.querySelector("#branch-chart");
const dailyActivityCaption = document.querySelector("#daily-activity-caption");
const activeFilters = document.querySelector("#active-filters");
const selectionSummary = document.querySelector("#selection-summary");

async function loadJson(path) {
  const response = await fetch(path);
  if (!response.ok) {
    throw new Error(`Failed to load ${path}`);
  }
  return response.json();
}

function formatNumber(value) {
  return new Intl.NumberFormat("en-US").format(value ?? 0);
}

function formatDate(value) {
  if (!value) {
    return "n/a";
  }
  return new Intl.DateTimeFormat("en-US", {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: "UTC",
  }).format(new Date(value));
}

function escapeHtml(value) {
  return String(value ?? "").replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function clearElement(element) {
  while (element.firstChild) {
    element.removeChild(element.firstChild);
  }
}

function getBranchColor(branch) {
  const branches = state.data.branches.branches;
  const index = branches.indexOf(branch);
  return BRANCH_COLORS[index % BRANCH_COLORS.length];
}

function toDayString(value) {
  return value.slice(0, 10);
}

function getCommitDay(commit) {
  return toDayString(commit.author_date);
}

function commitMatchesFilters(commit) {
  const day = getCommitDay(commit);
  const branchMatch = state.filters.branches.has(commit.branch);
  const authorMatch = state.filters.authors.size === 0 || state.filters.authors.has(commit.author_email);
  const startMatch = !state.filters.startDate || day >= state.filters.startDate;
  const endMatch = !state.filters.endDate || day <= state.filters.endDate;

  return branchMatch && authorMatch && startMatch && endMatch;
}

function buildAuthorSummaries(commits) {
  const byAuthor = new Map();

  commits.forEach((commit) => {
    const key = `${commit.author_email}::${commit.author_name}`;
    const existing = byAuthor.get(key) ?? {
      author_name: commit.author_name,
      author_email: commit.author_email,
      commit_count: 0,
      total_insertions: 0,
      total_deletions: 0,
      total_changed_files: 0,
      last_commit_at: commit.author_date,
      branches: new Set(),
    };

    existing.commit_count += 1;
    existing.total_insertions += commit.insertions ?? 0;
    existing.total_deletions += commit.deletions ?? 0;
    existing.total_changed_files += commit.changed_files ?? 0;
    if (commit.author_date > existing.last_commit_at) {
      existing.last_commit_at = commit.author_date;
    }
    existing.branches.add(commit.branch);
    byAuthor.set(key, existing);
  });

  return Array.from(byAuthor.values()).sort((left, right) => {
    if (right.commit_count !== left.commit_count) {
      return right.commit_count - left.commit_count;
    }
    return right.last_commit_at.localeCompare(left.last_commit_at);
  });
}

function buildBranchSummaries(commits) {
  const byBranch = new Map();

  commits.forEach((commit) => {
    const existing = byBranch.get(commit.branch) ?? {
      branch: commit.branch,
      commit_count: 0,
      author_emails: new Set(),
      total_insertions: 0,
      total_deletions: 0,
      total_changed_files: 0,
      first_commit_at: commit.author_date,
      last_commit_at: commit.author_date,
    };

    existing.commit_count += 1;
    existing.author_emails.add(commit.author_email);
    existing.total_insertions += commit.insertions ?? 0;
    existing.total_deletions += commit.deletions ?? 0;
    existing.total_changed_files += commit.changed_files ?? 0;
    if (commit.author_date < existing.first_commit_at) {
      existing.first_commit_at = commit.author_date;
    }
    if (commit.author_date > existing.last_commit_at) {
      existing.last_commit_at = commit.author_date;
    }
    byBranch.set(commit.branch, existing);
  });

  return Array.from(byBranch.values())
    .map((item) => ({
      ...item,
      author_count: item.author_emails.size,
    }))
    .sort((left, right) => {
      const leftIndex = state.data.branches.branches.indexOf(left.branch);
      const rightIndex = state.data.branches.branches.indexOf(right.branch);
      return leftIndex - rightIndex;
    });
}

function buildDailySeries(commits) {
  const byDayAndBranch = new Map();

  commits.forEach((commit) => {
    const day = getCommitDay(commit);
    const key = `${commit.branch}::${day}`;
    const existing = byDayAndBranch.get(key) ?? {
      branch: commit.branch,
      commit_day: day,
      commit_count: 0,
      total_insertions: 0,
      total_deletions: 0,
      total_changed_files: 0,
    };

    existing.commit_count += 1;
    existing.total_insertions += commit.insertions ?? 0;
    existing.total_deletions += commit.deletions ?? 0;
    existing.total_changed_files += commit.changed_files ?? 0;
    byDayAndBranch.set(key, existing);
  });

  return Array.from(byDayAndBranch.values()).sort((left, right) => {
    if (left.commit_day === right.commit_day) {
      return left.branch.localeCompare(right.branch);
    }
    return left.commit_day.localeCompare(right.commit_day);
  });
}

function getRecentCommits(commits) {
  return [...commits].sort((left, right) => right.author_date.localeCompare(left.author_date)).slice(0, 25);
}

function getFilterScopeAuthors() {
  const search = authorSearch.value.trim().toLowerCase();
  const commits = state.data.commits.filter((commit) => {
    const day = getCommitDay(commit);
    const branchMatch = state.filters.branches.has(commit.branch);
    const startMatch = !state.filters.startDate || day >= state.filters.startDate;
    const endMatch = !state.filters.endDate || day <= state.filters.endDate;
    return branchMatch && startMatch && endMatch;
  });

  return buildAuthorSummaries(commits).filter((author) => {
    if (!search) {
      return true;
    }
    return (
      author.author_name.toLowerCase().includes(search) ||
      author.author_email.toLowerCase().includes(search)
    );
  });
}

function updateDerivedState() {
  state.filteredCommits = state.data.commits.filter(commitMatchesFilters);
  state.filteredAuthors = buildAuthorSummaries(state.filteredCommits);
  state.filteredBranchSummaries = buildBranchSummaries(state.filteredCommits);
  state.filteredDailySeries = buildDailySeries(state.filteredCommits);
  state.filteredRecentCommits = getRecentCommits(state.filteredCommits);
}

function renderStats() {
  clearElement(statsGrid);

  const commitCount = state.filteredCommits.length;
  const authorCount = state.filteredAuthors.length;
  const branchCount = state.filters.branches.size;
  const totalInsertions = state.filteredCommits.reduce((sum, item) => sum + (item.insertions ?? 0), 0);
  const totalDeletions = state.filteredCommits.reduce((sum, item) => sum + (item.deletions ?? 0), 0);
  const totalChangedFiles = state.filteredCommits.reduce((sum, item) => sum + (item.changed_files ?? 0), 0);
  const latestCommit = state.filteredRecentCommits[0]?.author_date ?? null;

  const cards = [
    {
      label: "Filtered commits",
      value: formatNumber(commitCount),
      detail: `branches: ${formatNumber(branchCount)}`,
    },
    {
      label: "Active authors",
      value: formatNumber(authorCount),
      detail: `author filter: ${state.filters.authors.size === 0 ? "all" : formatNumber(state.filters.authors.size)}`,
    },
    {
      label: "Lines added / removed",
      value: `${formatNumber(totalInsertions)} / ${formatNumber(totalDeletions)}`,
      detail: `files changed: ${formatNumber(totalChangedFiles)}`,
    },
    {
      label: "Visible branches",
      value: formatNumber(branchCount),
      detail: `latest commit: ${formatDate(latestCommit)}`,
    },
  ];

  cards.forEach((card) => {
    const article = document.createElement("article");
    article.innerHTML = `
      <h3>${card.label}</h3>
      <strong>${card.value}</strong>
      <span>${card.detail}</span>
    `;
    statsGrid.appendChild(article);
  });
}

function renderActiveFilters() {
  clearElement(activeFilters);

  const chips = [];
  chips.push(`${state.filters.branches.size} branch${state.filters.branches.size === 1 ? "" : "es"}`);
  chips.push(state.filters.authors.size === 0 ? "all authors" : `${state.filters.authors.size} authors`);
  chips.push(state.filters.startDate ? `from ${state.filters.startDate}` : "from start");
  chips.push(state.filters.endDate ? `to ${state.filters.endDate}` : "to latest");
  chips.push(`metric: ${metricSelect.selectedOptions[0].textContent}`);

  chips.forEach((label) => {
    const span = document.createElement("span");
    span.className = "pill";
    span.textContent = label;
    activeFilters.appendChild(span);
  });

  selectionSummary.textContent = `${formatNumber(state.filteredCommits.length)} commits match the current filters.`;
}

function renderBranchSummary() {
  clearElement(branchSummaryBody);

  if (state.filteredBranchSummaries.length === 0) {
    const row = document.createElement("tr");
    row.innerHTML = `<td colspan="7" class="empty-state">No matching branch records.</td>`;
    branchSummaryBody.appendChild(row);
    return;
  }

  state.filteredBranchSummaries.forEach((item) => {
    const row = document.createElement("tr");
    row.innerHTML = `
      <td data-label="Branch"><span class="pill" style="--pill-color:${getBranchColor(item.branch)}">${escapeHtml(item.branch)}</span></td>
      <td data-label="Commits">${formatNumber(item.commit_count)}</td>
      <td data-label="Authors">${formatNumber(item.author_count)}</td>
      <td data-label="Insertions">${formatNumber(item.total_insertions)}</td>
      <td data-label="Deletions">${formatNumber(item.total_deletions)}</td>
      <td data-label="Changed files">${formatNumber(item.total_changed_files)}</td>
      <td data-label="Last commit">${formatDate(item.last_commit_at)}</td>
    `;
    branchSummaryBody.appendChild(row);
  });
}

function fillTable(body, rows, renderRow, colspan, emptyMessage) {
  clearElement(body);

  if (rows.length === 0) {
    const row = document.createElement("tr");
    row.innerHTML = `<td colspan="${colspan}" class="empty-state">${emptyMessage}</td>`;
    body.appendChild(row);
    return;
  }

  rows.forEach((item) => body.appendChild(renderRow(item)));
}

function renderAuthorActivity() {
  fillTable(
    authorActivityBody,
    state.filteredAuthors.slice(0, 15),
    (item) => {
      const row = document.createElement("tr");
      row.innerHTML = `
        <td data-label="Author">
          <strong>${escapeHtml(item.author_name)}</strong><br>
          <span class="metric-trend">${escapeHtml(item.author_email)}</span>
        </td>
        <td data-label="Commits">${formatNumber(item.commit_count)}</td>
        <td data-label="Insertions">${formatNumber(item.total_insertions)}</td>
        <td data-label="Deletions">${formatNumber(item.total_deletions)}</td>
        <td data-label="Files">${formatNumber(item.total_changed_files)}</td>
        <td data-label="Last commit">${formatDate(item.last_commit_at)}</td>
      `;
      return row;
    },
    6,
    "No authors match the current filters.",
  );
}

function renderRecentCommits() {
  fillTable(
    recentCommitsBody,
    state.filteredRecentCommits,
    (item) => {
      const row = document.createElement("tr");
      row.innerHTML = `
        <td data-label="When">${formatDate(item.author_date)}</td>
        <td data-label="Branch"><span class="pill" style="--pill-color:${getBranchColor(item.branch)}">${escapeHtml(item.branch)}</span></td>
        <td data-label="Author">${escapeHtml(item.author_name)}</td>
        <td data-label="Summary">${escapeHtml(item.summary)}</td>
      `;
      return row;
    },
    4,
    "No commits match the current filters.",
  );
}

function appendSvg(parent, name, attributes = {}) {
  const element = document.createElementNS("http://www.w3.org/2000/svg", name);
  Object.entries(attributes).forEach(([key, value]) => element.setAttribute(key, String(value)));
  parent.appendChild(element);
  return element;
}

function renderDailyChart() {
  const width = 960;
  const height = 320;
  const padding = { top: 36, right: 26, bottom: 44, left: 52 };
  const chartWidth = width - padding.left - padding.right;
  const chartHeight = height - padding.top - padding.bottom;
  const metric = state.filters.metric;
  const metricLabel = metricSelect.selectedOptions[0].textContent;
  const selectedBranches = state.data.branches.branches.filter((branch) => state.filters.branches.has(branch));
  const byBranch = new Map(selectedBranches.map((branch) => [branch, []]));

  state.filteredDailySeries.forEach((item) => {
    if (byBranch.has(item.branch)) {
      byBranch.get(item.branch).push(item);
    }
  });

  const daySet = new Set(state.filteredDailySeries.map((item) => item.commit_day));
  const days = Array.from(daySet).sort();
  const maxValue = Math.max(
    ...Array.from(byBranch.values()).flat().map((item) => item[metric] ?? 0),
    1,
  );

  clearElement(dailyChart);
  dailyChart.setAttribute("viewBox", `0 0 ${width} ${height}`);
  const previousLegend = dailyChart.parentElement.querySelector(".chart-legend");
  if (previousLegend) {
    previousLegend.remove();
  }

  appendSvg(dailyChart, "title", { id: "daily-chart-title" }).textContent = `Time series for ${metricLabel}`;

  for (let tick = 0; tick <= 4; tick += 1) {
    const y = padding.top + (chartHeight * tick) / 4;
    const value = Math.round(maxValue - (maxValue * tick) / 4);
    appendSvg(dailyChart, "line", {
      x1: padding.left,
      x2: width - padding.right,
      y1: y,
      y2: y,
      stroke: "rgba(31, 37, 33, 0.14)",
    });
    const label = appendSvg(dailyChart, "text", {
      x: padding.left - 10,
      y: y + 4,
      "text-anchor": "end",
      fill: "#5b635d",
      "font-size": "12",
    });
    label.textContent = String(value);
  }

  if (days.length === 0) {
    const label = appendSvg(dailyChart, "text", {
      x: width / 2,
      y: height / 2,
      "text-anchor": "middle",
      fill: "#5b635d",
      "font-size": "16",
    });
    label.textContent = "No daily activity for the current filters.";
    dailyActivityCaption.textContent = "Adjust branches, authors, or date range to populate the timeline.";
    return;
  }

  selectedBranches.forEach((branch) => {
    const points = days.map((day, index) => {
      const point = byBranch.get(branch).find((item) => item.commit_day === day);
      const value = point?.[metric] ?? 0;
      const x = padding.left + (days.length === 1 ? chartWidth / 2 : (chartWidth * index) / (days.length - 1));
      const y = padding.top + chartHeight - (value / maxValue) * chartHeight;
      return { day, value, x, y };
    });

    const pathData = points.map((point, index) => `${index === 0 ? "M" : "L"} ${point.x} ${point.y}`).join(" ");
    appendSvg(dailyChart, "path", {
      d: pathData,
      fill: "none",
      stroke: getBranchColor(branch),
      "stroke-width": 3,
      "stroke-linecap": "round",
      "stroke-linejoin": "round",
    });

    points.forEach((point) => {
      appendSvg(dailyChart, "circle", {
        cx: point.x,
        cy: point.y,
        r: 3.5,
        fill: getBranchColor(branch),
      });
    });
  });

  days.forEach((day, index) => {
    if (index !== 0 && index !== days.length - 1 && index % Math.ceil(days.length / 5) !== 0) {
      return;
    }

    const x = padding.left + (days.length === 1 ? chartWidth / 2 : (chartWidth * index) / (days.length - 1));
    const label = appendSvg(dailyChart, "text", {
      x,
      y: height - 14,
      "text-anchor": "middle",
      fill: "#5b635d",
      "font-size": "12",
    });
    label.textContent = day;
  });

  const legend = document.createElement("div");
  legend.className = "chart-legend";
  selectedBranches.forEach((branch) => {
    const item = document.createElement("span");
    item.className = "legend-item";
    const marker = document.createElement("i");
    marker.style.background = getBranchColor(branch);
    const label = document.createElement("span");
    label.textContent = branch;
    item.append(marker, label);
    legend.appendChild(item);
  });

  dailyChart.parentElement.appendChild(legend);

  dailyActivityCaption.textContent = `${metricLabel} over ${days.length} day${days.length === 1 ? "" : "s"} across ${selectedBranches.length} branch${selectedBranches.length === 1 ? "" : "es"}.`;
}

function renderAuthorChart() {
  const width = 960;
  const height = 320;
  const padding = { top: 24, right: 24, bottom: 24, left: 220 };
  const chartWidth = width - padding.left - padding.right;
  const topAuthors = state.filteredAuthors.slice(0, 10);
  const maxValue = Math.max(...topAuthors.map((item) => item.commit_count), 1);
  const rowHeight = topAuthors.length > 0 ? (height - padding.top - padding.bottom) / topAuthors.length : 24;

  clearElement(authorChart);
  authorChart.setAttribute("viewBox", `0 0 ${width} ${height}`);

  if (topAuthors.length === 0) {
    const label = appendSvg(authorChart, "text", {
      x: width / 2,
      y: height / 2,
      "text-anchor": "middle",
      fill: "#5b635d",
      "font-size": "16",
    });
    label.textContent = "No authors match the current filters.";
    return;
  }

  topAuthors.forEach((author, index) => {
    const y = padding.top + index * rowHeight;
    const barWidth = (author.commit_count / maxValue) * chartWidth;
    appendSvg(authorChart, "rect", {
      x: padding.left,
      y: y + 4,
      width: barWidth,
      height: Math.max(rowHeight - 10, 12),
      rx: 8,
      fill: "#20504b",
    });
    const label = appendSvg(authorChart, "text", {
      x: padding.left - 12,
      y: y + rowHeight / 2 + 4,
      "text-anchor": "end",
      fill: "#1f2521",
      "font-size": "13",
    });
    label.textContent = `${author.author_name} (${author.commit_count})`;
  });
}

function renderBranchChart() {
  const width = 960;
  const height = 300;
  const padding = { top: 24, right: 24, bottom: 56, left: 48 };
  const chartWidth = width - padding.left - padding.right;
  const chartHeight = height - padding.top - padding.bottom;
  const summaries = state.filteredBranchSummaries;
  const maxValue = Math.max(...summaries.map((item) => item.commit_count), 1);
  const barWidth = summaries.length > 0 ? chartWidth / summaries.length : chartWidth;

  clearElement(branchChart);
  branchChart.setAttribute("viewBox", `0 0 ${width} ${height}`);

  if (summaries.length === 0) {
    const label = appendSvg(branchChart, "text", {
      x: width / 2,
      y: height / 2,
      "text-anchor": "middle",
      fill: "#5b635d",
      "font-size": "16",
    });
    label.textContent = "No branches match the current filters.";
    return;
  }

  for (let tick = 0; tick <= 4; tick += 1) {
    const y = padding.top + (chartHeight * tick) / 4;
    appendSvg(branchChart, "line", {
      x1: padding.left,
      x2: width - padding.right,
      y1: y,
      y2: y,
      stroke: "rgba(31, 37, 33, 0.12)",
    });
  }

  summaries.forEach((item, index) => {
    const heightValue = (item.commit_count / maxValue) * chartHeight;
    const x = padding.left + index * barWidth + 10;
    const y = padding.top + chartHeight - heightValue;
    appendSvg(branchChart, "rect", {
      x,
      y,
      width: Math.max(barWidth - 20, 18),
      height: heightValue,
      rx: 10,
      fill: getBranchColor(item.branch),
    });
    const label = appendSvg(branchChart, "text", {
      x: x + Math.max(barWidth - 20, 18) / 2,
      y: height - 22,
      "text-anchor": "middle",
      fill: "#5b635d",
      "font-size": "12",
    });
    label.textContent = item.branch.replace("REL_", "R").replace("_STABLE", "");
  });
}

function createCheckbox({ label, value, checked, name, onChange, color }) {
  const wrapper = document.createElement("label");
  wrapper.className = "toggle";
  if (color) {
    wrapper.style.setProperty("--toggle-accent", color);
  }

  const input = document.createElement("input");
  input.type = "checkbox";
  input.name = name;
  input.value = value;
  input.checked = checked;
  input.addEventListener("change", onChange);

  const text = document.createElement("span");
  text.textContent = label;

  wrapper.append(input, text);
  return wrapper;
}

function renderBranchFilter() {
  clearElement(branchFilter);

  state.data.branches.branches.forEach((branch) => {
    branchFilter.appendChild(
      createCheckbox({
        label: branch,
        value: branch,
        checked: state.filters.branches.has(branch),
        name: "branch",
        color: getBranchColor(branch),
        onChange: (event) => {
          if (event.target.checked) {
            state.filters.branches.add(branch);
          } else {
            state.filters.branches.delete(branch);
          }
          if (state.filters.branches.size === 0) {
            state.filters.branches.add(state.data.branches.root_branch);
          }
          syncAuthorSelection();
          renderDashboard();
        },
      }),
    );
  });
}

function syncAuthorSelection() {
  const validAuthors = new Set(getFilterScopeAuthors().map((item) => item.author_email));
  state.filters.authors = new Set(
    Array.from(state.filters.authors).filter((authorEmail) => validAuthors.has(authorEmail)),
  );
}

function renderAuthorFilter() {
  clearElement(authorFilter);
  const authors = getFilterScopeAuthors().slice(0, 60);

  if (authors.length === 0) {
    const empty = document.createElement("p");
    empty.className = "filter-empty";
    empty.textContent = "No authors in the current branch/date scope.";
    authorFilter.appendChild(empty);
    return;
  }

  authors.forEach((author) => {
    authorFilter.appendChild(
      createCheckbox({
        label: `${author.author_name} (${author.commit_count})`,
        value: author.author_email,
        checked: state.filters.authors.has(author.author_email),
        name: "author",
        onChange: (event) => {
          if (event.target.checked) {
            state.filters.authors.add(author.author_email);
          } else {
            state.filters.authors.delete(author.author_email);
          }
          renderDashboard();
        },
      }),
    );
  });
}

function initializeDateInputs() {
  const days = state.data.commits.map((commit) => getCommitDay(commit)).sort();
  const minDay = days[0];
  const maxDay = days[days.length - 1];

  startDateInput.min = minDay;
  startDateInput.max = maxDay;
  endDateInput.min = minDay;
  endDateInput.max = maxDay;
  startDateInput.value = "";
  endDateInput.value = "";
}

function renderDashboard() {
  updateDerivedState();
  renderBranchFilter();
  renderAuthorFilter();
  renderActiveFilters();
  renderStats();
  renderBranchSummary();
  renderAuthorActivity();
  renderRecentCommits();
  renderDailyChart();
  renderAuthorChart();
  renderBranchChart();
}

function initializeControls() {
  branchPresetButtons.forEach((button) => {
    button.addEventListener("click", () => {
      const preset = button.dataset.branchPreset;
      if (preset === "all") {
        state.filters.branches = new Set(state.data.branches.branches);
      } else if (preset === "stable") {
        state.filters.branches = new Set(state.data.branches.branches.filter((branch) => branch !== state.data.branches.root_branch));
      } else {
        state.filters.branches = new Set([state.data.branches.root_branch]);
      }
      syncAuthorSelection();
      renderDashboard();
    });
  });

  authorPresetButtons.forEach((button) => {
    button.addEventListener("click", () => {
      if (button.dataset.authorPreset === "clear") {
        state.filters.authors = new Set();
      } else {
        state.filters.authors = new Set(
          getFilterScopeAuthors().slice(0, 60).map((item) => item.author_email),
        );
      }
      renderDashboard();
    });
  });

  authorSearch.addEventListener("input", () => {
    renderAuthorFilter();
  });

  startDateInput.addEventListener("change", () => {
    state.filters.startDate = startDateInput.value;
    if (state.filters.endDate && state.filters.startDate && state.filters.startDate > state.filters.endDate) {
      state.filters.endDate = state.filters.startDate;
      endDateInput.value = state.filters.endDate;
    }
    syncAuthorSelection();
    renderDashboard();
  });

  endDateInput.addEventListener("change", () => {
    state.filters.endDate = endDateInput.value;
    if (state.filters.startDate && state.filters.endDate && state.filters.endDate < state.filters.startDate) {
      state.filters.startDate = state.filters.endDate;
      startDateInput.value = state.filters.startDate;
    }
    syncAuthorSelection();
    renderDashboard();
  });

  metricSelect.addEventListener("change", () => {
    state.filters.metric = metricSelect.value;
    renderDashboard();
  });
}

async function main() {
  const [branches, commits] = await Promise.all(
    Object.values(DATA_FILES).map((path) => loadJson(path)),
  );

  state.data = { branches, commits };
  state.filters.branches = new Set(branches.branches);
  initializeDateInputs();
  initializeControls();
  renderDashboard();
}

main().catch((error) => {
  document.body.innerHTML = `
    <div class="page-shell">
      <section class="panel">
        <p class="section-label">Load failure</p>
        <h2>Static data is missing or incomplete.</h2>
        <p class="section-copy">${error.message}</p>
      </section>
    </div>
  `;
});
