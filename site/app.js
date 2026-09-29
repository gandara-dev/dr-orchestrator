import {
  formatDuration,
  normalizeRunbook,
  recoveryPlan,
  simulate,
} from './lib/dr-engine.js';

const $ = (selector) => document.querySelector(selector);
const key = (id) => String(id).toLowerCase();

const state = {
  runbook: null,
  plan: null,
  failures: new Set(),
  results: new Map(),
  actualStart: new Map(),
  runningId: null,
  clock: 0,
  log: [],
  lastRun: null,
  runToken: 0,
};

// ------------------------------------------------------------------ helpers

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

const wait = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });
const pad = (value) => String(value).padStart(2, '0');
const clockText = (seconds) => `T+${pad(Math.floor(seconds / 60))}:${pad(Math.round(seconds % 60))}`;
const stepNumber = (id) => pad(state.plan.steps.findIndex((step) => key(step.id) === key(id)) + 1);
const stepById = (id) => state.runbook.steps.find((step) => key(step.id) === key(id));

// A short, human description of what a step touches, taken from its parameters.
function target(step) {
  const parameters = step.parameters || {};
  const parts = [];
  for (const [name, value] of Object.entries(parameters)) {
    if (name === 'port' || /timeout/i.test(name)) continue;
    if (Array.isArray(value)) {
      parts.push(value.join(', '));
    } else if (name === 'computerName' && parameters.port !== undefined) {
      parts.push(`${value}:${parameters.port}`);
    } else if (typeof value !== 'object') {
      parts.push(String(value));
    }
  }
  return parts.join(' · ');
}

function showError(message) {
  const box = $('#load-error');
  box.textContent = message;
  box.classList.toggle('show', Boolean(message));
}

// ------------------------------------------------------------------ loading

function loadRunbook(source) {
  const runbook = normalizeRunbook(source);
  state.runbook = runbook;
  state.plan = recoveryPlan(runbook);
  state.failures.clear();
  resetRun();
  showError('');
}

async function loadSample(name) {
  const response = await fetch(`./runbooks/${name}.json`);
  if (!response.ok) throw new Error(`Could not load ${name}.json (${response.status}).`);
  loadRunbook(await response.json());
}

// ------------------------------------------------------------------ rendering

function renderHead() {
  const { runbook, plan } = state;
  $('#title').textContent = runbook.name;
  $('#description').textContent = runbook.description || '';
  document.title = `${runbook.name} | DR Orchestrator`;
  const status = state.runningId ? 'Running' : state.lastRun ? state.lastRun.status : 'Not run';
  const fields = [
    ['Revision', runbook.version ?? '—'],
    ['Steps', runbook.steps.length],
    ['Planned, one at a time', formatDuration(plan.sequentialEstimateSeconds)],
    ['Critical path', formatDuration(plan.criticalPathSeconds)],
    ['Drill', status],
  ];
  $('#fields').innerHTML = fields.map(([label, value]) => `<div><dt>${label}</dt><dd class="${escapeHtml(value)}">${escapeHtml(value)}</dd></div>`).join('');
}

function resultCell(id) {
  const result = state.results.get(key(id));
  if (state.runningId && key(state.runningId) === key(id)) {
    return `<td class="result"><b>running</b><small>${clockText(state.clock)}</small></td>`;
  }
  if (result) {
    const started = state.actualStart.get(key(id));
    const detail = result.status === 'Blocked' ? 'not started' : clockText(started);
    return `<td class="result ${result.status}"><b>${result.status.toLowerCase()}</b><small>${detail}</small></td>`;
  }
  if (state.failures.has(key(id))) return '<td class="result"><b>will fail</b><small>injected</small></td>';
  return '<td class="result"><small>—</small></td>';
}

function renderProcedure() {
  const rows = state.plan.steps.map((planStep, index) => {
    const step = stepById(planStep.id);
    const classes = [
      planStep.onCriticalPath ? 'critical' : '',
      state.failures.has(key(step.id)) ? 'inject' : '',
      state.runningId && key(state.runningId) === key(step.id) ? 'running' : '',
    ].join(' ');
    const after = step.dependsOn.length ? step.dependsOn.map(stepNumber).join(', ') : '—';
    const planned = step.expectedDurationSeconds === null ? '—' : formatDuration(step.expectedDurationSeconds);
    return `<tr class="${classes}" data-id="${escapeHtml(step.id)}" tabindex="0" aria-label="Step ${index + 1}: ${escapeHtml(step.name)}">
      <td class="no">${pad(index + 1)}</td>
      <td class="step"><b>${escapeHtml(step.name)}</b><code>${escapeHtml(step.id)}</code></td>
      <td class="target">${escapeHtml(target(step)) || '—'}</td>
      <td class="how">${escapeHtml(step.provider)}<span>${escapeHtml(step.action)}</span></td>
      <td class="after">${after}</td>
      <td class="plan">${planned}</td>
      ${resultCell(step.id)}
    </tr>`;
  });
  $('#procedure').innerHTML = `<thead><tr><th>#</th><th>Step</th><th class="target">Target</th><th class="how">Provider</th><th>After</th><th>Planned</th><th>Result</th></tr></thead>
    <tbody>${rows.join('')}</tbody>`;
}

function renderSchedule() {
  const { plan } = state;
  const total = Math.max(plan.sequentialEstimateSeconds, plan.criticalPathSeconds, 1);
  const percent = (seconds) => `${(seconds / total) * 100}%`;
  const cells = plan.steps.map((planStep, index) => {
    const duration = planStep.expectedDurationSeconds || 0;
    const result = state.results.get(key(planStep.id));
    const started = state.actualStart.get(key(planStep.id));
    const actual = result && result.status !== 'Blocked'
      ? `<span class="actual ${result.status}" style="left:${percent(started)};width:${percent(duration)}"></span>`
      : '';
    return `<div class="no">${pad(index + 1)}</div>
      <div class="track" title="${escapeHtml(planStep.name)}">
        <span class="plan ${planStep.onCriticalPath ? 'critical' : ''}" style="left:${percent(planStep.earliestStartSeconds)};width:${percent(duration)}"></span>
        ${actual}
      </div>`;
  });
  const ticks = [0, 0.25, 0.5, 0.75].map((fraction) => {
    const seconds = Math.round((total * fraction) / 60) * 60;
    return `<span style="left:${percent(seconds)}">${formatDuration(seconds)}</span>`;
  });
  ticks.push(`<span class="end">${formatDuration(total)}</span>`);
  $('#schedule').innerHTML = `${cells.join('')}<div class="axis">${ticks.join('')}</div>`;
}

function renderLog() {
  if (!state.log.length) {
    $('#log').innerHTML = '<span class="t">No drill has run yet.</span>';
    return;
  }
  $('#log').innerHTML = state.log.map((entry) => `<span class="t">${entry.time}</span>  ${entry.no}  ${escapeHtml(entry.name).padEnd(46, ' ')} <span class="${entry.status}">${entry.status.toLowerCase()}</span>${entry.note ? `  <span class="t">${escapeHtml(entry.note)}</span>` : ''}`).join('\n');
}

function render() {
  renderHead();
  renderProcedure();
  renderSchedule();
  renderLog();
  $('#download-report').disabled = !state.lastRun;
}

// ------------------------------------------------------------------ drill

function resetRun() {
  state.runToken += 1;
  state.results.clear();
  state.actualStart.clear();
  state.runningId = null;
  state.clock = 0;
  state.log = [];
  state.lastRun = null;
  setControls(false);
  render();
}

function setControls(running) {
  for (const id of ['#run', '#runbook-select', '#clear-failures']) $(id).disabled = running;
}

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
      await wait(Math.max(150, (duration / 60) * msPerMinute));
      if (token !== state.runToken) return;
    } else if (msPerMinute > 0) {
      await wait(80);
      if (token !== state.runToken) return;
    }
    state.runningId = null;
    state.results.set(key(result.id), result);
    state.log.push({
      time: clockText(state.clock),
      no: stepNumber(result.id),
      name: result.name,
      status: result.status,
      note: result.status === 'Blocked'
        ? `waits for ${step.dependsOn.filter((id) => state.results.get(key(id))?.status !== 'Succeeded').map(stepNumber).join(', ')}`
        : result.status === 'Failed' ? 'injected failure' : formatDuration(duration),
    });
    if (result.status !== 'Blocked') state.clock += duration;
    render();
  }
  state.lastRun = execution;
  state.log.push({ time: clockText(state.clock), no: '--', name: `Drill finished: ${execution.status.toLowerCase()}`, status: execution.status, note: '' });
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

// ------------------------------------------------------------------ events

function toggleFailure(row) {
  if (!row || $('#run').disabled) return;
  const id = key(row.dataset.id);
  if (state.failures.has(id)) state.failures.delete(id);
  else state.failures.add(id);
  resetRun();
}

function bind() {
  $('#procedure').addEventListener('click', (event) => toggleFailure(event.target.closest('tr[data-id]')));
  $('#procedure').addEventListener('keydown', (event) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      toggleFailure(event.target.closest('tr[data-id]'));
    }
  });
  $('#run').addEventListener('click', run);
  $('#reset').addEventListener('click', resetRun);
  $('#clear-failures').addEventListener('click', () => {
    state.failures.clear();
    resetRun();
  });
  $('#print').addEventListener('click', () => window.print());
  $('#runbook-select').addEventListener('change', async (event) => {
    try {
      await loadSample(event.target.value);
    } catch (error) {
      showError(error.message);
    }
  });
  $('#open-file').addEventListener('change', async (event) => {
    const [file] = event.target.files;
    event.target.value = '';
    if (!file) return;
    try {
      loadRunbook(JSON.parse(await file.text()));
    } catch (error) {
      showError(`${file.name}: ${error.message}`);
    }
  });
  $('#download-report').addEventListener('click', () => {
    const blob = new Blob([reportMarkdown()], { type: 'text/markdown' });
    const link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = 'report.md';
    link.click();
    URL.revokeObjectURL(link.href);
  });
}

bind();
loadSample($('#runbook-select').value).catch((error) => showError(error.message));
