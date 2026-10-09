'use strict';
const crypto = require('crypto');
const { accessError } = require('./content-policy');
const MAX_PHOTO_BYTES = 2 * 1024 * 1024;

function digest(value) {
  return typeof value === 'string' && /^[a-f0-9]{64}$/i.test(value) ? value.toLowerCase() : undefined;
}

function originalSha256(media) {
  // Cloud DB may omit sensitive sha256. preparedSha256 is an existing ordinary
  // field verified on upload; coverSourceSha256 is computed by the cover worker.
  return digest(media.preparedSha256) || digest(media.sha256) ||
    (media.coverRecipeVersion === 1 ? digest(media.coverSourceSha256) : undefined);
}

function mediaVariant(media, variant = 'ORIGINAL') {
  if (!['ORIGINAL', 'COVER_480'].includes(variant)) throw accessError('图片规格无效。', 'VALIDATION_ERROR');
  const cover = variant === 'COVER_480', original = originalSha256(media);
  if (cover && !(media.coverRecipeVersion === 1 && original && digest(media.coverSourceSha256) === original &&
      digest(media.coverSha256) && Number.isSafeInteger(media.coverByteSize) && media.coverByteSize > 3 &&
      media.coverByteSize <= MAX_PHOTO_BYTES && Number.isSafeInteger(media.coverWidth) && media.coverWidth > 0 &&
      Number.isSafeInteger(media.coverHeight) && media.coverHeight > 0 && Math.max(media.coverWidth, media.coverHeight) <= 480)) {
    throw accessError('封面尚未生成，请刷新内容。', 'MEDIA_VARIANT_UNAVAILABLE');
  }
  // Unknown legacy digests must be omitted by JSON serialization, not returned
  // as an empty string: clients then download and validate the original bytes.
  return { variant, sha256: cover ? digest(media.coverSha256) : original,
    byteSize: Number(cover ? media.coverByteSize : media.byteSize || 0),
    width: Number(cover ? media.coverWidth : media.width), height: Number(cover ? media.coverHeight : media.height) };
}

function sameMediaSource(current, original) {
  return !!current && ['id', 'cardId', 'ownerUid', 'storageUid', 'status', 'createdAt', 'byteSize', 'width', 'height']
    .every(field => current[field] === original[field]) && originalSha256(current) === originalSha256(original);
}

function integrityFailure(check) {
  const error = accessError('图片内容不匹配。', 'MEDIA_INTEGRITY_FAILED');
  // Logged only at the cloud boundary; do not expose bytes, digests or keys.
  error.integrityCheck = check;
  return error;
}

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
