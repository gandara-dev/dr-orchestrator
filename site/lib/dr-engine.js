// Browser port of the DR Orchestrator engine used by the Runbook Viewer.
//
// It mirrors, message for message, the PowerShell functions
// ConvertTo-DrRunbookDefinition, Get-DrExecutionOrder, the simulation path of
// Invoke-DrRunbook, and Get-DrRecoveryPlan. Both implementations run the
// shared fixtures in tests/fixtures/viewer-cases.json.

export class RunbookError extends Error {}

const PROVIDERS = ['VMware', 'Windows'];
const ACTIONS = {
  vmware: ['StartVM', 'WaitForTools', 'TestVM'],
  windows: ['StartService', 'TestTcpPort', 'TestHttp'],
};
const MAX_DURATION = 604800;

const has = (object, name) => object !== null && typeof object === 'object' && Object.hasOwn(object, name);
const text = (value) => (value === null || value === undefined ? '' : String(value));
const blank = (value) => text(value).trim() === '';
const lower = (value) => text(value).toLowerCase();
const list = (value) => (value === null || value === undefined ? [] : Array.isArray(value) ? value : [value]);

// PowerShell's [int] cast: rounds to even, and null or empty becomes 0.
function toInt(value) {
  if (value === null || value === undefined || value === '') return 0;
  const number = Number(value);
  if (!Number.isFinite(number)) return NaN;
  const floor = Math.floor(number);
  const diff = number - floor;
  if (diff > 0.5) return floor + 1;
  if (diff < 0.5) return floor;
  return floor % 2 === 0 ? floor : floor + 1;
}

function confirmParameters(stepId, provider, action, parameters) {
  const supported = ACTIONS[lower(provider)];
  if (!supported.some((item) => lower(item) === lower(action))) {
    throw new RunbookError(`Step '${stepId}' has unsupported action '${action}' for provider '${provider}'.`);
  }
  const key = lower(action);
  if (['startvm', 'waitfortools', 'testvm'].includes(key)) {
    const names = list(parameters.vmNames).map(text).filter((name) => !blank(name));
    if (names.length === 0) {
      throw new RunbookError(`Step '${stepId}' action '${action}' requires parameters.vmNames.`);
    }
  } else if (key === 'startservice') {
    for (const name of ['computerName', 'serviceName']) {
      if (blank(parameters[name])) {
        throw new RunbookError(`Step '${stepId}' action '${action}' requires parameters.${name}.`);
      }
    }
  } else if (key === 'testtcpport') {
    const port = toInt(parameters.port);
    if (blank(parameters.computerName)) {
      throw new RunbookError(`Step '${stepId}' action '${action}' requires parameters.computerName.`);
    }
    if (!(port >= 1 && port <= 65535)) {
      throw new RunbookError(`Step '${stepId}' action '${action}' requires parameters.port between 1 and 65535.`);
    }
  } else if (key === 'testhttp') {
    let valid = false;
    try {
      const uri = new URL(text(parameters.uri));
      valid = ['http:', 'https:'].includes(uri.protocol);
    } catch {
      valid = false;
    }
    if (!valid) {
      throw new RunbookError(`Step '${stepId}' action '${action}' requires an absolute HTTP(S) parameters.uri.`);
    }
  }
  if (has(parameters, 'timeoutSeconds') && !(toInt(parameters.timeoutSeconds) >= 1)) {
    throw new RunbookError(`Step '${stepId}' parameters.timeoutSeconds must be greater than zero.`);
  }
}

export function normalizeRunbook(source) {
  for (const property of ['name', 'version', 'steps']) {
    if (!has(source, property)) {
      throw new RunbookError(`Runbook is missing required property '${property}'.`);
    }
  }
  if (blank(source.name)) {
    throw new RunbookError('Runbook name must not be empty.');
  }
  if (toInt(source.version) !== 1) {
    throw new RunbookError(`Unsupported runbook version '${text(source.version)}'; expected version 1.`);
  }
  const sourceSteps = list(source.steps);
  if (sourceSteps.length === 0) {
    throw new RunbookError('Runbook must define at least one step.');
  }

  const ids = new Set();
  const steps = [];
  for (const sourceStep of sourceSteps) {
    for (const property of ['id', 'name', 'provider', 'action']) {
      if (!has(sourceStep, property)) {
        throw new RunbookError(`A runbook step is missing required property '${property}'.`);
      }
    }
    const id = text(sourceStep.id);
    if (blank(id)) {
      throw new RunbookError('Step id must not be empty.');
    }
    if (ids.has(lower(id))) {
      throw new RunbookError(`Duplicate step id '${id}'.`);
    }
    ids.add(lower(id));
    if (blank(sourceStep.name)) {
      throw new RunbookError(`Step '${id}' name must not be empty.`);
    }
    const providerMatch = PROVIDERS.find((item) => lower(item) === lower(sourceStep.provider));
    if (!providerMatch) {
      throw new RunbookError(`Step '${id}' has unsupported provider '${text(sourceStep.provider)}'.`);
    }
    const provider = text(sourceStep.provider);
    const action = text(sourceStep.action);
    if (blank(action)) {
      throw new RunbookError(`Step '${id}' action must not be empty.`);
    }
    const dependsOn = has(sourceStep, 'dependsOn') ? list(sourceStep.dependsOn).map(text) : [];

    let parameters = sourceStep.parameters;
    if (parameters === null || parameters === undefined) {
      parameters = {};
    }
    if (typeof parameters !== 'object' || Array.isArray(parameters)) {
      throw new RunbookError(`Step '${id}' parameters must be a mapping/object.`);
    }
    confirmParameters(id, provider, action, parameters);

    let expectedDurationSeconds = null;
    if (has(sourceStep, 'expectedDurationSeconds')) {
      const raw = sourceStep.expectedDurationSeconds;
      if (!Number.isInteger(raw) || raw < 1 || raw > MAX_DURATION) {
        throw new RunbookError(`Step '${id}' expectedDurationSeconds must be a whole number from 1 to ${MAX_DURATION}.`);
      }
      expectedDurationSeconds = raw;
    }

    steps.push({ id, name: text(sourceStep.name), provider, action, dependsOn, expectedDurationSeconds, parameters });
  }

  for (const step of steps) {
    for (const dependency of step.dependsOn) {
      if (!ids.has(lower(dependency))) {
        throw new RunbookError(`Step '${step.id}' depends on unknown step '${dependency}'.`);
      }
      if (lower(dependency) === lower(step.id)) {
        throw new RunbookError(`Step '${step.id}' cannot depend on itself.`);
      }
    }
  }

  return {
    name: text(source.name),
    version: toInt(source.version),
    description: text(source.description),
    steps,
  };
}

export function executionOrder(runbook) {
  const remaining = [...runbook.steps];
  const completed = new Set();
  const ordered = [];
  while (remaining.length > 0) {
    const next = remaining.find((step) => step.dependsOn.every((dependency) => completed.has(lower(dependency))));
    if (!next) {
      throw new RunbookError(`Dependency cycle detected among steps: ${remaining.map((step) => step.id).join(', ')}.`);
    }
    ordered.push(next);
    completed.add(lower(next.id));
    remaining.splice(remaining.indexOf(next), 1);
  }
  return ordered;
}

export function simulate(runbook, injectedFailures = []) {
  const failures = new Set(injectedFailures.map(lower));
  const states = new Map();
  const steps = executionOrder(runbook).map((step) => {
    const blockedBy = step.dependsOn.filter((dependency) => states.get(lower(dependency)) !== 'Succeeded');
    let status;
    let message;
    if (blockedBy.length > 0) {
      status = 'Blocked';
      message = `Skipped because prerequisite step(s) did not succeed: ${blockedBy.join(', ')}.`;
    } else if (failures.has(lower(step.id))) {
      status = 'Failed';
      message = `Injected simulation failure at step '${step.id}'.`;
    } else {
      status = 'Succeeded';
      message = `Simulated '${step.action}' using the ${step.provider} provider.`;
    }
    states.set(lower(step.id), status);
    return { id: step.id, name: step.name, provider: step.provider, action: step.action, status, message };
  });
  return {
    runbookName: runbook.name,
    status: steps.some((step) => step.status === 'Failed') ? 'Failed' : 'Succeeded',
    steps,
  };
}

export function recoveryPlan(runbook) {
  const ordered = executionOrder(runbook);
  const byId = new Map();
  const level = new Map();
  const start = new Map();
  const finish = new Map();
  const predecessor = new Map();
  const missing = [];
  let sequential = 0;

  for (const step of ordered) {
    const key = lower(step.id);
    byId.set(key, step);
    let duration = 0;
    if (step.expectedDurationSeconds !== null) {
      duration = step.expectedDurationSeconds;
    } else {
      missing.push(step.id);
    }
    sequential += duration;

    let stepLevel = 0;
    let stepStart = 0;
    let stepPredecessor = null;
    for (const dependency of step.dependsOn) {
      const dependencyKey = lower(dependency);
      stepLevel = Math.max(stepLevel, level.get(dependencyKey) + 1);
      if (stepPredecessor === null || finish.get(dependencyKey) > stepStart) {
        stepStart = finish.get(dependencyKey);
        stepPredecessor = dependencyKey;
      }
    }
    level.set(key, stepLevel);
    start.set(key, stepStart);
    finish.set(key, stepStart + duration);
    predecessor.set(key, stepPredecessor);
  }

  let endKey = null;
  for (const step of ordered) {
    const key = lower(step.id);
    if (endKey === null || finish.get(key) > finish.get(endKey)) {
      endKey = key;
    }
  }

  const criticalPath = [];
  for (let cursor = endKey; cursor !== null; cursor = predecessor.get(cursor)) {
    criticalPath.unshift(byId.get(cursor).id);
  }
  const critical = new Set(criticalPath.map(lower));

  return {
    runbookName: runbook.name,
    steps: ordered.map((step) => {
      const key = lower(step.id);
      return {
        id: step.id,
        name: step.name,
        level: level.get(key),
        dependsOn: step.dependsOn,
        expectedDurationSeconds: step.expectedDurationSeconds,
        earliestStartSeconds: start.get(key),
        earliestFinishSeconds: finish.get(key),
        onCriticalPath: critical.has(key),
      };
    }),
    sequentialEstimateSeconds: sequential,
    criticalPathSeconds: finish.get(endKey),
    criticalPath,
    missingDurations: missing,
  };
}

export function formatDuration(seconds) {
  const total = Math.max(0, Math.round(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const rest = total % 60;
  if (hours > 0) return `${hours}h ${String(minutes).padStart(2, '0')}m`;
  if (minutes > 0) return rest ? `${minutes}m ${String(rest).padStart(2, '0')}s` : `${minutes}m`;
  return `${rest}s`;
}
