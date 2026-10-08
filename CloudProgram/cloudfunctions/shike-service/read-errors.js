'use strict';
const crypto = require('crypto');
const READ_OPT_VERSION = 'stages89-20261007-v1';
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
    stage: error && ['assembly', 'final-check', 'candidate-permissions'].includes(error.readStage) ? error.readStage : 'cloud-operation', functionVersion: READ_OPT_VERSION };
}
module.exports = { requestId, errorCode, errorResponse, READ_OPT_VERSION };
