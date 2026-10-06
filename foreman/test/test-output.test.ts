import { expect, it } from 'vitest';
import { parseTestOutput } from '../src/repos.js';

it('recognizes Node TAP and Node 24 spec reporter summaries', () => {
  expect(parseTestOutput('# tests 2\n# pass 1\n# fail 1\nnot ok 2 - broken')).toEqual({ summary: 'tests 2, pass 1, fail 1', failures: ['broken'] });
  expect(parseTestOutput('\u001b[34mℹ tests 2\u001b[39m\nℹ pass 2\nℹ fail 0')).toEqual({ summary: 'tests 2, pass 2, fail 0', failures: [] });
});
