'use strict';
const crypto = require('crypto');
const { buildInfo } = require('./release-info');
const READ_OPT_VERSION = buildInfo.buildId;
const READ_STAGES = new Set(['authentication', 'preferences', 'capabilities', 'candidates',
  'candidate-permissions', 'assembly', 'final-check', 'media-permissions', 'storage', 'cloud-operation']);
function shouldReadMetrics(env, id) {
  const source = env || process.env;
  const enabled = source.SHIKE_READ_METRICS_ENABLED === undefined ? process.env.SHIKE_READ_METRICS_ENABLED : source.SHIKE_READ_METRICS_ENABLED;
  if (String(enabled || '').trim().toLowerCase() !== 'true') return false;
  const configured = source.SHIKE_READ_METRICS_SAMPLE_RATE === undefined ? process.env.SHIKE_READ_METRICS_SAMPLE_RATE : source.SHIKE_READ_METRICS_SAMPLE_RATE;
  const rate = configured === undefined || configured === '' ? 1 : Number(configured);
  if (!Number.isFinite(rate) || rate < 0 || rate > 1) return false;
  const sample = crypto.createHash('sha256').update(String(id || '')).digest().readUInt32BE(0) / 0x100000000;
  return sample < rate;
}
function readStage(error) {
  return error && READ_STAGES.has(error.readStage) ? error.readStage : 'cloud-operation';
}
function requestId(input) {
  const value = input && input.readRequestId;
  return typeof value === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(value) ? value : crypto.randomUUID();
}
function safeCode(value) { return /^[A-Za-z0-9_-]{1,64}$/.test(String(value)) ? String(value) : 'REQUEST_FAILED'; }
function errorCode(error) {
  if (error && (typeof error.code === 'string' || typeof error.code === 'number')) return safeCode(error.code);
  // Installed cloud-server AGCError exposes getCode(), not a public code field.
  if (error && typeof error.getCode === 'function') {
    try { const code = error.getCode(); if (typeof code === 'string' || typeof code === 'number') return safeCode(code); } catch (_) { }
  }
  const message = error && typeof error.message === 'string' ? error.message : '';
  const match = message.match(/^(3007009):\s/);
  return match ? match[1] : 'REQUEST_FAILED';
}
function errorResponse(error, operation, id) {
  const code = errorCode(error), busy = code === '3007009';
  return { ok: false, data: {}, code,
    message: busy ? '云数据库暂时繁忙，请稍后重试。' : (error && typeof error.message === 'string' ? error.message : '云端请求失败。'),
    retryable: busy, retryAfterMs: busy ? 2000 : 0, requestId: id, operation,
    stage: readStage(error), functionVersion: READ_OPT_VERSION, ...buildInfo };
}
module.exports = { requestId, errorCode, errorResponse, readStage, READ_OPT_VERSION, shouldReadMetrics };
