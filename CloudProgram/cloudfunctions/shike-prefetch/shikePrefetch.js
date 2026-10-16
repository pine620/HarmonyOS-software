'use strict';
// Pack 4.1 (2026-10-15): Cloud Foundation Kit prefetch target (install + periodic prefetch, configured in AGC).
// It only returns the published home snapshot from Cloud Storage: no Cloud DB reads, no identity, no writes,
// so prefetch traffic from many devices does not consume the Cloud DB quota.
const { readSnapshot } = require('./shared/public-snapshot');
const { buildInfo } = require('./shared/release-info');

exports.handler = async (event, context, callback) => {
  let response;
  try {
    response = { ok: true, data: await readSnapshot(process.env), message: '', ...buildInfo };
  } catch (error) {
    console.error('prefetch.snapshot failed: ' + String(error && error.message || error).slice(0, 200));
    response = { ok: false, code: 'SNAPSHOT_UNAVAILABLE', message: '首页快照暂不可用。', ...buildInfo };
  }
  if (typeof callback === 'function') return callback(response);
  return response;
};
