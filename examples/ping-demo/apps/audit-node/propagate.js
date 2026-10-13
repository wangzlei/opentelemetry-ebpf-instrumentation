'use strict';
// Which status a caller adopts when one of its dependencies failed -- port of app/propagate.py.
//
// `statuses` holds one entry per downstream call: its status code, or null when there was no call to
// make or the connection never got a response (not a failure). Returns null when no dependency
// failed. A fault outranks a throttle; a throttle passes through only when EVERY failure was one.
const THROTTLE = 429;
const FAULT = 500;
const FAILURE_THRESHOLD = 400;

function worstStatus(statuses) {
  const failures = statuses.filter((s) => s !== null && s !== undefined && s >= FAILURE_THRESHOLD);
  if (failures.length === 0) return null;
  return failures.every((s) => s === THROTTLE) ? THROTTLE : FAULT;
}

module.exports = { worstStatus };
