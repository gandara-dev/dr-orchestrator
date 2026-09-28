import {
  executionOrder,
  formatDuration,
  normalizeRunbook,
  recoveryPlan,
  simulate,
} from './lib/dr-engine.js';

const NODE_W = 196;
const NODE_H = 60;
const GAP_X = 58;
const GAP_Y = 16;
const PAD = 16;
const SVG_NS = 'http://www.w3.org/2000/svg';

const $ = (selector) => document.querySelector(selector);

const state = {
  runbook: null,
  plan: null,
  failures: new Set(),
  results: new Map(),
  runningId: null,
  selectedId: null,
  clock: 0,
  runToken: 0,
  lastRun: null,
  actualStart: new Map(),
};

const key = (id) => String(id).toLowerCase();

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function svg(tag, attributes = {}, parent = null) {
  const element = document.createElementNS(SVG_NS, tag);
  for (const [name, value] of Object.entries(attributes)) {
    element.setAttribute(name, value);
  }
  if (parent) parent.append(element);
  return element;
}

function truncate(value, length) {
  return value.length > length ? `${value.slice(0, length - 1)}…` : value;
}

function stepById(id) {
  return state.runbook.steps.find((step) => key(step.id) === key(id));
}

function planStep(id) {
  return state.plan.steps.find((step) => key(step.id) === key(id));
}

// --------------------------------------------------------------- loading

function loadRunbook(source) {
  const runbook = normalizeRunbook(source);
  executionOrder(runbook);
  state.runbook = runbook;
  state.plan = recoveryPlan(runbook);
  state.failures = new Set();
  state.selectedId = null;
  resetRun();
  $('#load-error').classList.remove('show');
}

async function loadSample(name) {
  const response = await fetch(`./runbooks/${name}.json`);
  if (!response.ok) throw new Error(`${name}: HTTP ${response.status}`);
  loadRunbook(await response.json());
}

function showError(message) {
  const box = $('#load-error');
  box.textContent = message;
  box.classList.add('show');
}

// ----------------------------------------------------------------- graph

function layout() {
  const columns = new Map();
  for (const step of state.plan.steps) {
    if (!columns.has(step.level)) columns.set(step.level, []);
    columns.get(step.level).push(step.id);
  }
  const positions = new Map();
  let rows = 0;
  for (const [level, ids] of columns) {
    ids.forEach((id, row) => {
      positions.set(key(id), { x: PAD + level * (NODE_W + GAP_X), y: PAD + row * (NODE_H + GAP_Y) });
    });
    rows = Math.max(rows, ids.length);
  }
  const levels = Math.max(...columns.keys()) + 1;
  return {
    positions,
    width: PAD * 2 + levels * NODE_W + (levels - 1) * GAP_X,
    height: PAD * 2 + rows * NODE_H + (rows - 1) * GAP_Y,
  };
}

function edgeClass(from, to) {
  const path = state.plan.criticalPath.map(key);
  const index = path.indexOf(key(to));
  const classes = ['edge'];
  if (index > 0 && path[index - 1] === key(from)) classes.push('critical');
  const fromStatus = state.results.get(key(from))?.status;
  const toStatus = state.results.get(key(to))?.status;
  if (fromStatus === 'Succeeded' && toStatus === 'Succeeded') classes.push('done');
  if (toStatus === 'Blocked' && fromStatus !== 'Succeeded') classes.push('stopped');
  return classes.join(' ');
}

function renderGraph() {
  const graph = $('#graph');
  graph.replaceChildren();
  const { positions, width, height } = layout();
  graph.setAttribute('width', width);
  graph.setAttribute('height', height);
  graph.setAttribute('viewBox', `0 0 ${width} ${height}`);

  const edges = svg('g', {}, graph);
  for (const step of state.runbook.steps) {
    const to = positions.get(key(step.id));
    for (const dependency of step.dependsOn) {
      const from = positions.get(key(dependency));
      const x1 = from.x + NODE_W;
      const y1 = from.y + NODE_H / 2;
      const x2 = to.x;
      const y2 = to.y + NODE_H / 2;
      const dx = Math.max(24, (x2 - x1) / 2);
      svg('path', {
        d: `M${x1},${y1} C${x1 + dx},${y1} ${x2 - dx},${y2} ${x2},${y2}`,
        class: edgeClass(dependency, step.id),
      }, edges);
    }
  }

  const critical = new Set(state.plan.criticalPath.map(key));
  for (const step of state.runbook.steps) {
    const position = positions.get(key(step.id));
    const result = state.results.get(key(step.id));
    const classes = ['node'];
    if (critical.has(key(step.id))) classes.push('critical');
    if (state.failures.has(key(step.id))) classes.push('inject');
    if (state.selectedId && key(state.selectedId) === key(step.id)) classes.push('selected');
    if (state.runningId && key(state.runningId) === key(step.id)) classes.push('running');
    if (result) classes.push(result.status);

    const group = svg('g', {
      class: classes.join(' '),
      transform: `translate(${position.x},${position.y})`,
      tabindex: '0',
      role: 'button',
      'aria-label': `${step.name}${result ? `, ${result.status}` : ''}${state.failures.has(key(step.id)) ? ', set to fail' : ''}`,
      'data-id': step.id,
    }, graph);
    svg('rect', { class: 'box', width: NODE_W, height: NODE_H, rx: 8 }, group);
    svg('title', {}, group).textContent = `${step.name} (${step.id})`;
    svg('text', { class: 'title', x: 10, y: 20 }, group).textContent = truncate(step.name, 25);
    svg('text', { class: 'meta', x: 10, y: 38 }, group).textContent = truncate(`${step.provider} · ${step.action}`, 28);
    const duration = step.expectedDurationSeconds ? formatDuration(step.expectedDurationSeconds) : 'no estimate';
    svg('text', { class: 'meta', x: 10, y: 53 }, group).textContent = duration;
    svg('circle', { class: 'status-dot', cx: NODE_W - 14, cy: 14, r: 5 }, group);
    if (state.failures.has(key(step.id))) {
      const badge = svg('text', { class: 'badge', x: NODE_W - 10, y: 53, 'text-anchor': 'end', fill: 'var(--fail)' }, group);
      badge.textContent = 'WILL FAIL';
    }
  }
}

// -------------------------------------------------------------- timeline

function renderTimeline() {
  const scale = Math.max(state.plan.sequentialEstimateSeconds, state.plan.criticalPathSeconds, 1);
  const percent = (value) => `${(value / scale) * 100}%`;
  const rows = state.plan.steps.map((step) => {
    const result = state.results.get(key(step.id));
    const running = state.runningId && key(state.runningId) === key(step.id);
    const duration = step.expectedDurationSeconds || 0;
    const planBar = `<span class="plan${step.onCriticalPath ? '' : ' off'}" style="left:${percent(step.earliestStartSeconds)};width:max(3px, ${percent(duration)})"></span>`;
    let actual = '';
    if (state.actualStart.has(key(step.id)) && (result || running)) {
      const start = state.actualStart.get(key(step.id));
      const length = result?.status === 'Blocked' ? 0 : duration;
      actual = `<span class="actual ${running ? 'running' : result.status}" style="left:${percent(start)};width:max(3px, ${percent(length)})"></span>`;
    }
    const status = running ? 'Running' : result?.status || '';
    return `<div class="row-name" title="${escapeHtml(step.name)}">${escapeHtml(step.name)} <small>${escapeHtml(formatDuration(duration))}</small></div>
      <div class="track">${planBar}${actual}</div>
      <div class="row-status ${escapeHtml(result?.status || '')}">${escapeHtml(status)}</div>`;
  });
  $('#timeline').innerHTML = rows.join('');
}

// ----------------------------------------------------------------- stats

function renderStats() {
  const plan = state.plan;
  const counts = { Succeeded: 0, Failed: 0, Blocked: 0 };
  for (const result of state.results.values()) counts[result.status] += 1;
  const done = state.results.size;
  const outcome = state.lastRun
    ? `${state.lastRun.status}<div class="sub">${counts.Succeeded} ok · ${counts.Failed} failed · ${counts.Blocked} blocked</div>`
    : state.runningId ? 'Running…' : '—<div class="sub">Run the simulation</div>';
  const missing = plan.missingDurations.length
    ? `<div class="sub">${plan.missingDurations.length} step(s) without an estimate</div>` : '';
  const items = [
    ['Steps', `${plan.steps.length}<div class="sub">${state.failures.size} set to fail</div>`],
    ['Sequential estimate', `${formatDuration(plan.sequentialEstimateSeconds)}<div class="sub">one step at a time, as the engine runs</div>${missing}`],
    ['Critical path', `${formatDuration(plan.criticalPathSeconds)}<div class="sub">lower bound with parallel branches</div>`],
    ['Simulated clock', `${formatDuration(state.clock)}<div class="sub">${done} of ${plan.steps.length} steps processed</div>`],
    ['Result', outcome],
  ];
  $('#stats').innerHTML = items
    .map(([label, value]) => `<div class="stat"><dt>${escapeHtml(label)}</dt><dd>${value}</dd></div>`)
    .join('');
}

// ---------------------------------------------------------------- detail

function renderDetail() {
  const container = $('#detail');
  if (!state.selectedId) {
    container.innerHTML = '<p class="hint">Select a step in the graph.</p>';
    return;
  }
  const step = stepById(state.selectedId);
  const plan = planStep(step.id);
  const result = state.results.get(key(step.id));
  const injected = state.failures.has(key(step.id));
  const running = state.runningId !== null;
  container.innerHTML = `
    <dl>
      <dt>Step</dt><dd><strong>${escapeHtml(step.name)}</strong><br><code>${escapeHtml(step.id)}</code></dd>
      <dt>Provider</dt><dd>${escapeHtml(step.provider)} · ${escapeHtml(step.action)}</dd>
      <dt>Depends on</dt><dd>${step.dependsOn.length ? step.dependsOn.map((id) => `<code>${escapeHtml(id)}</code>`).join(', ') : 'Nothing (starts immediately)'}</dd>
      <dt>Estimate</dt><dd>${step.expectedDurationSeconds ? escapeHtml(formatDuration(step.expectedDurationSeconds)) : 'Not set'}</dd>
      <dt>Earliest start</dt><dd>${escapeHtml(formatDuration(plan.earliestStartSeconds))} (level ${plan.level})${plan.onCriticalPath ? ' · on the critical path' : ''}</dd>
      <dt>Parameters</dt><dd><pre>${escapeHtml(JSON.stringify(step.parameters, null, 2))}</pre></dd>
    </dl>
    ${result ? `<p class="message ${escapeHtml(result.status)}">${escapeHtml(result.status)}: ${escapeHtml(result.message)}</p>` : ''}
    <div class="actions">
      <button type="button" id="toggle-failure"${running ? ' disabled' : ''}>${injected ? 'Do not fail this step' : 'Make this step fail'}</button>
    </div>`;
  $('#toggle-failure').addEventListener('click', () => {
    const id = key(step.id);
    if (state.failures.has(id)) state.failures.delete(id);
    else state.failures.add(id);
    resetRun();
  });
}

function render() {
  renderGraph();
  renderTimeline();
  renderStats();
  renderDetail();
  $('#download-report').disabled = !state.lastRun;
}

// ------------------------------------------------------------ simulation

function resetRun() {
  state.runToken += 1;
  state.results = new Map();
  state.actualStart = new Map();
  state.runningId = null;
  state.clock = 0;
  state.lastRun = null;
  setControls(false);
  render();
}

function setControls(running) {
  for (const id of ['#run', '#runbook-select', '#clear-failures', '#speed']) {
    $(id).disabled = running;
  }
  $('label[for="open-file"]').style.pointerEvents = running ? 'none' : '';
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function run() {
  resetRun();
  const token = state.runToken;
  const msPerMinute = Number($('#speed').value);
  const execution = simulate(state.runbook, [...state.failures]);
  setControls(true);

  for (const result of execution.steps) {
    const step = stepById(result.id);
    const duration = step.expectedDurationSeconds || 0;
    state.actualStart.set(key(result.id), state.clock);
    if (result.status !== 'Blocked' && msPerMinute > 0) {
      state.runningId = result.id;
      render();
      await wait(Math.max(120, (duration / 60) * msPerMinute));
      if (token !== state.runToken) return;
    } else if (msPerMinute > 0) {
      await wait(90);
      if (token !== state.runToken) return;
    }
    state.runningId = null;
    state.results.set(key(result.id), result);
    if (result.status !== 'Blocked') state.clock += duration;
    render();
  }
  state.lastRun = execution;
  setControls(false);
  render();
}

function reportMarkdown() {
  const execution = state.lastRun;
  const lines = [
    `# Disaster Recovery Report: ${execution.runbookName}`,
    '',
    `- **Status:** ${execution.status}`,
    '- **Mode:** Simulation (Runbook Viewer)',
    `- **Generated (UTC):** ${new Date().toISOString().replace('T', ' ').replace('Z', '')}`,
    `- **Simulated elapsed time (planned durations):** ${formatDuration(state.clock)}`,
    `- **Critical path (parallel lower bound):** ${formatDuration(state.plan.criticalPathSeconds)}`,
    '',
    '| Step | Name | Provider | Status | Planned duration | Details |',
    '| --- | --- | --- | --- | ---: | --- |',
  ];
  const clean = (value) => String(value).replace(/\|/g, '\\|').replace(/[\r\n]+/g, ' ');
  for (const result of execution.steps) {
    const step = stepById(result.id);
    const duration = result.status === 'Blocked' ? '0s' : formatDuration(step.expectedDurationSeconds || 0);
    lines.push(`| ${clean(result.id)} | ${clean(result.name)} | ${clean(result.provider)} | ${result.status} | ${duration} | ${clean(result.message)} |`);
  }
  return `${lines.join('\n')}\n`;
}

// ---------------------------------------------------------------- events

function bind() {
  $('#graph').addEventListener('click', (event) => {
    const node = event.target.closest('.node');
    if (!node) return;
    state.selectedId = node.dataset.id;
    render();
  });
  $('#graph').addEventListener('keydown', (event) => {
    const node = event.target.closest('.node');
    if (!node || (event.key !== 'Enter' && event.key !== ' ')) return;
    event.preventDefault();
    state.selectedId = node.dataset.id;
    render();
    document.querySelector(`.node[data-id="${CSS.escape(node.dataset.id)}"]`)?.focus();
  });
  $('#run').addEventListener('click', run);
  $('#reset').addEventListener('click', resetRun);
  $('#clear-failures').addEventListener('click', () => {
    state.failures.clear();
    resetRun();
  });
  $('#runbook-select').addEventListener('change', async (event) => {
    try {
      await loadSample(event.target.value);
    } catch (error) {
      showError(`Could not load the runbook: ${error.message}`);
    }
  });
  $('#open-file').addEventListener('change', async (event) => {
    const [file] = event.target.files;
    event.target.value = '';
    if (!file) return;
    try {
      loadRunbook(JSON.parse(await file.text()));
      const select = $('#runbook-select');
      let custom = select.querySelector('option[value="custom"]');
      if (!custom) {
        custom = new Option('', 'custom');
        select.add(custom);
      }
      custom.textContent = `${state.runbook.name} (from file)`;
      select.value = 'custom';
    } catch (error) {
      showError(`${file.name}: ${error.message}`);
    }
  });
  $('#download-report').addEventListener('click', () => {
    const url = URL.createObjectURL(new Blob([reportMarkdown()], { type: 'text/markdown' }));
    const link = Object.assign(document.createElement('a'), { href: url, download: 'report.md' });
    document.body.append(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  });
}

bind();
loadSample('citrix-site-recovery').catch((error) => showError(`Could not load the runbook: ${error.message}`));
