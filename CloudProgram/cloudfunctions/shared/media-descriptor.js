/**
 * 【文件职责】图片描述符的生成与字节校验（sha256、大小、尺寸、变体），客户端缓存与服务端读图都以它为准。
 */
'use strict';
const crypto = require('crypto');
const { accessError } = require('./content-policy');
const MAX_PHOTO_BYTES = 2 * 1024 * 1024;

// 计算 sha256（十六进制）。
function digest(value) {
  return typeof value === 'string' && /^[a-f0-9]{64}$/i.test(value) ? value.toLowerCase() : undefined;
}

// 原图的 sha256：优先使用 sha256 字段，缺失时使用上传时校验过的 preparedSha256。
function originalSha256(media) {
  // Cloud DB 可能不返回敏感字段 sha256；preparedSha256 是上传时校验过的普通字段，coverSourceSha256 由封面生成器计算。
  return digest(media.preparedSha256) || digest(media.sha256) ||
    (media.coverRecipeVersion === 1 ? digest(media.coverSourceSha256) : undefined);
}

// 生成某个变体（原图 / 480px 封面）的描述符；封面尚未生成时抛错。
function mediaVariant(media, variant = 'ORIGINAL') {
  if (!['ORIGINAL', 'COVER_480'].includes(variant)) throw accessError('图片规格无效。', 'VALIDATION_ERROR');
  const cover = variant === 'COVER_480', original = originalSha256(media);
  if (cover && !(media.coverRecipeVersion === 1 && original && digest(media.coverSourceSha256) === original &&
      digest(media.coverSha256) && Number.isSafeInteger(media.coverByteSize) && media.coverByteSize > 3 &&
      media.coverByteSize <= MAX_PHOTO_BYTES && Number.isSafeInteger(media.coverWidth) && media.coverWidth > 0 &&
      Number.isSafeInteger(media.coverHeight) && media.coverHeight > 0 && Math.max(media.coverWidth, media.coverHeight) <= 480)) {
    throw accessError('封面尚未生成，请刷新内容。', 'MEDIA_VARIANT_UNAVAILABLE');
  }
  // 未知的旧摘要必须在 JSON 序列化时省略，而不是返回空串：这样客户端会下载原图并自行校验字节。
  return { variant, sha256: cover ? digest(media.coverSha256) : original,
    byteSize: Number(cover ? media.coverByteSize : media.byteSize || 0),
    width: Number(cover ? media.coverWidth : media.width), height: Number(cover ? media.coverHeight : media.height) };
}

// 两条记录是否指向同一份源图片（防止并发替换）。
function sameMediaSource(current, original) {
  return !!current && ['id', 'cardId', 'ownerUid', 'storageUid', 'status', 'createdAt', 'byteSize', 'width', 'height']
    .every(field => current[field] === original[field]) && originalSha256(current) === originalSha256(original);
}

// 构造完整性校验失败的错误。
function integrityFailure(check) {
  const error = accessError('图片内容不匹配。', 'MEDIA_INTEGRITY_FAILED');
  // 只在云端边界记录日志；不暴露字节、摘要或密钥。
  error.integrityCheck = check;
  return error;
}

// 校验字节：类型、大小上限、实际大小、JPEG 标记与 sha256。
function verifyMediaBytes(bytes, descriptor, version) {
  if (!Buffer.isBuffer(bytes)) throw integrityFailure('NOT_BINARY');
  if (bytes.length < 4 || bytes.length > MAX_PHOTO_BYTES) throw integrityFailure('BYTE_BUDGET');
  if (bytes.length !== descriptor.byteSize) throw integrityFailure('SIZE_MISMATCH');
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff ||
      bytes[bytes.length - 2] !== 0xff || bytes[bytes.length - 1] !== 0xd9) throw integrityFailure('JPEG_MARKERS');
  const actual = crypto.createHash('sha256').update(bytes).digest('hex');
  if (descriptor.sha256 && actual !== descriptor.sha256) throw integrityFailure('SHA256_MISMATCH');
  if (version && actual !== version) throw accessError('图片版本已变化。', 'MEDIA_VERSION_STALE');
  return actual;
}

module.exports = { originalSha256, mediaVariant, sameMediaSource, verifyMediaBytes };
