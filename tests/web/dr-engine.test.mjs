// Runs the fixtures generated from the PowerShell engine against the browser
// engine used by the Runbook Viewer.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

import {
  executionOrder,
  formatDuration,
  normalizeRunbook,
  recoveryPlan,
  simulate,
} from '../../site/lib/dr-engine.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const readJson = (relative) => JSON.parse(readFileSync(path.join(root, relative), 'utf8'));
const cases = readJson('tests/fixtures/viewer-cases.json');
const sample = (name) => normalizeRunbook(readJson(`site/runbooks/${name}.json`));

for (const testCase of cases.simulations) {
  test(`simulation: ${testCase.name}`, () => {
    const result = simulate(sample(testCase.runbook), testCase.failures);
    assert.equal(result.status, testCase.status);
    assert.deepEqual(
      result.steps.map(({ id, status, message }) => ({ id, status, message })),
      testCase.steps,
    );
  });
}

for (const expected of cases.plans) {
  test(`plan: ${expected.runbook}`, () => {
    const plan = recoveryPlan(sample(expected.runbook));
    assert.equal(plan.sequentialEstimateSeconds, expected.sequentialEstimateSeconds);
    assert.equal(plan.criticalPathSeconds, expected.criticalPathSeconds);
    assert.deepEqual(plan.criticalPath, expected.criticalPath);
    assert.deepEqual(plan.missingDurations, expected.missingDurations);
    assert.deepEqual(
      plan.steps.map(({ id, level, earliestStartSeconds, earliestFinishSeconds, onCriticalPath }) =>
        ({ id, level, earliestStartSeconds, earliestFinishSeconds, onCriticalPath })),
      expected.steps,
    );
  });
}

for (const testCase of cases.invalid) {
  test(`invalid: ${testCase.name}`, () => {
    assert.throws(() => executionOrder(normalizeRunbook(testCase.runbook)), { message: testCase.error });
  });
}

test('steps without a duration count as zero and are reported', () => {
  const runbook = normalizeRunbook({
    name: 'Partial',
    version: 1,
    steps: [
      { id: 'a', name: 'A', provider: 'VMware', action: 'StartVM', expectedDurationSeconds: 60, parameters: { vmNames: ['a'] } },
      { id: 'b', name: 'B', provider: 'VMware', action: 'StartVM', dependsOn: ['a'], parameters: { vmNames: ['b'] } },
    ],
  });
  const plan = recoveryPlan(runbook);
  assert.equal(plan.criticalPathSeconds, 60);
  assert.deepEqual(plan.missingDurations, ['b']);
});

test('durations are formatted for people', () => {
  assert.equal(formatDuration(45), '45s');
  assert.equal(formatDuration(1830), '30m 30s');
  assert.equal(formatDuration(3600), '1h 00m');
});
