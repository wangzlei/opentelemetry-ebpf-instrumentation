'use strict';
// Real CPU work for the response time -- port of app/cpuwork.py.
//
// Node serves on one event loop, so CPU work there would serialize every request (the GIL trap
// cpuwork.py avoids). The burn therefore runs in a pool of worker threads: each compute takes one
// worker (grown on demand up to MAX_WORKERS, so a burn never queues behind another), and the worker
// bounds it by ITS OWN thread's CPU time (process.threadCpuUsage), never by wall clock -- so the same
// budget takes proportionally longer when something else on the host wants the core.
//
// This file is both the module (main thread) and the worker entry.

const { Worker, isMainThread, parentPort } = require('worker_threads');
const crypto = require('crypto');

const CHUNK_ITERATIONS = 512; // pbkdf2 iterations per pass, as in cpuwork.py
const DEFAULT_WALL_CAP_SECONDS = 3.0; // wall-clock ceiling on one compute, as in cpuwork.py
const PASSWORD = 'obi-ping-demo-cpu-work';
const SALT = 'obi-ping-demo-salt';
const MAX_WORKERS = 16; // gunicorn's 2 workers x 8 threads

function threadCpuSeconds() {
  const u = process.threadCpuUsage(); // microseconds, this thread only
  return (u.user + u.system) / 1e6;
}

function burnChunk() {
  crypto.pbkdf2Sync(PASSWORD, SALT, CHUNK_ITERATIONS, 32, 'sha256');
}

// Synchronous; runs inside a worker thread.
function spendCpuSync(budget, wallCap) {
  if (budget <= 0) return { cpuSeconds: 0, wallSeconds: 0, capped: false };
  const cpuStart = threadCpuSeconds();
  const wallStart = performance.now();
  for (;;) {
    const cpu = threadCpuSeconds() - cpuStart;
    const wall = (performance.now() - wallStart) / 1000;
    if (cpu >= budget) return { cpuSeconds: cpu, wallSeconds: wall, capped: false };
    if (wall >= wallCap) return { cpuSeconds: cpu, wallSeconds: wall, capped: true };
    burnChunk();
  }
}

if (!isMainThread) {
  parentPort.on('message', ({ budget, wallCap }) => parentPort.postMessage(spendCpuSync(budget, wallCap)));
} else {
  const idle = [];
  let size = 0;
  const waiting = [];

  function acquire() {
    if (idle.length) return Promise.resolve(idle.pop());
    if (size < MAX_WORKERS) {
      size++;
      const w = new Worker(__filename);
      w.unref();
      return Promise.resolve(w);
    }
    return new Promise((resolve) => waiting.push(resolve));
  }

  function release(w) {
    const next = waiting.shift();
    if (next) next(w);
    else idle.push(w);
  }

  // -> Promise<{cpuSeconds, wallSeconds, capped}>
  async function spendCpu(budget, wallCap = DEFAULT_WALL_CAP_SECONDS) {
    if (budget <= 0) return { cpuSeconds: 0, wallSeconds: 0, capped: false };
    const w = await acquire();
    try {
      return await new Promise((resolve, reject) => {
        w.once('message', resolve);
        w.once('error', reject);
        w.postMessage({ budget, wallCap });
      });
    } finally {
      w.removeAllListeners('message');
      w.removeAllListeners('error');
      release(w);
    }
  }

  // Both halves are fixed proportions of the target; the sleep is never `target - elapsed`.
  function splitDuration(target, share) {
    const t = Math.max(0, target);
    return { cpuBudgetSeconds: t * share, sleepSeconds: t * (1 - share) };
  }

  // Coerce an operator-supplied share to [0,1]; anything unparseable or non-finite resolves to 0.
  function resolveShare(s) {
    const str = String(s ?? '').trim();
    if (!/^[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?$/i.test(str)) return 0;
    const v = Number(str);
    if (!Number.isFinite(v)) return 0;
    return Math.min(1, Math.max(0, v));
  }

  module.exports = { spendCpu, splitDuration, resolveShare, spendCpuSync, DEFAULT_WALL_CAP_SECONDS };
}
