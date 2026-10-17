/**
 * 【文件职责】云函数统一的错误响应与请求号：把任意错误转换成 { ok:false, code, message, retryable, stage, requestId }，并决定是否记录读取指标。
 */
'use strict';
const crypto = require('crypto');
const { buildInfo } = require('./release-info');
// 响应中的函数版本（等于构建 id）与已知的读取阶段名称。
const READ_OPT_VERSION = buildInfo.buildId;
const READ_STAGES = new Set(['authentication', 'preferences', 'capabilities', 'candidates',
  'content-state', 'assembly', 'final-check', 'storage', 'cloud-operation']);
// 本次请求是否记录读取指标（受环境变量控制，可抽样）。
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
// 错误发生的阶段（默认 handler）。
function readStage(error) {
  return error && READ_STAGES.has(error.readStage) ? error.readStage : 'cloud-operation';
}
// 取请求中的 readRequestId，没有则生成新的 UUID。
function requestId(input) {
  const value = input && input.readRequestId;
  return typeof value === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(value) ? value : crypto.randomUUID();
}
// 只允许安全字符的错误码。
function safeCode(value) { return /^[A-Za-z0-9_-]{1,64}$/.test(String(value)) ? String(value) : 'REQUEST_FAILED'; }
// 提取错误码（兼容 AGC SDK 的 getCode()）。
function errorCode(error) {
  if (error && (typeof error.code === 'string' || typeof error.code === 'number')) return safeCode(error.code);
  // 已安装的 cloud-server SDK 中 AGCError 通过 getCode() 提供错误码，没有公开的 code 字段。
  if (error && typeof error.getCode === 'function') {
    try { const code = error.getCode(); if (typeof code === 'string' || typeof code === 'number') return safeCode(code); } catch (_) { }
  }
  const message = error && typeof error.message === 'string' ? error.message : '';
  const match = message.match(/^(3007009):\s/);
  return match ? match[1] : 'REQUEST_FAILED';
}
// 生成失败响应：3007009（数据库繁忙）标记为可重试。
function errorResponse(error, operation, id) {
  const code = errorCode(error), busy = code === '3007009';
  return { ok: false, data: {}, code,
    message: busy ? '云数据库暂时繁忙，请稍后重试。' : (error && typeof error.message === 'string' ? error.message : '云端请求失败。'),
    retryable: busy, retryAfterMs: busy ? 2000 : 0, requestId: id, operation,
    stage: readStage(error), functionVersion: READ_OPT_VERSION, ...buildInfo };
}
module.exports = { requestId, errorCode, errorResponse, readStage, READ_OPT_VERSION, shouldReadMetrics };
