'use strict';

const { cloud } = require('@hw-agconnect/cloud-server');

const MAX_DISTANCE_KM = 20.0;
const MAX_PAGE_SIZE = 20;

class CloudDbModel {
  getFieldTypeMap() {
    return new Map(Object.entries(this.constructor.fieldTypes));
  }

  getClassName() {
    return this.constructor.name;
  }

  getPrimaryKeyList() {
    return [...this.constructor.primaryKeys];
  }

  getIndexList() {
    return [...this.constructor.indexes];
  }

  getEncryptedFieldList() {
    return [];
  }
}

class FoodCard extends CloudDbModel {}
FoodCard.fieldTypes = Object.freeze({
  id: 'String',
  ownerUid: 'String',
  productName: 'String',
  brand: 'String',
  priceFen: 'Integer',
  priceLabel: 'String',
  originalPriceFen: 'Integer',
  specification: 'String',
  shop: 'String',
  sellingPointsJson: 'Text',
  publicOffersJson: 'Text',
  sourceLink: 'Text',
  category: 'String',
  mediaId: 'String',
  latE3: 'Integer',
  lonE3: 'Integer',
  district: 'String',
  geohash: 'String',
  status: 'String',
  createdAt: 'Long',
  updatedAt: 'Long'
});
FoodCard.primaryKeys = Object.freeze(['id']);
FoodCard.indexes = Object.freeze([
  'ownerUid,createdAt',
  'status,latE3,lonE3,createdAt',
  'status,createdAt'
]);

function safeLogError(error) {
  const name = error && error.name ? String(error.name) : 'Error';
  const code = error && error.code !== undefined ? ` code=${String(error.code).slice(0, 32)}` : '';
  const message = error && error.message ? String(error.message) : 'unknown';
  const redacted = message
    .replace(/https?:\/\/\S+/gi, '[url]')
    .replace(/(?:Bearer\s+)?[A-Za-z0-9_\-+/=]{48,}/g, '[credential]')
    .slice(0, 300);
  return `${name}${code}: ${redacted}`;
}

async function verifyAgcAccessToken(accessToken) {
  if (!accessToken || String(accessToken).length > 8192) {
    throw new Error('登录状态已失效，请重新登录。');
  }
  try {
    const verified = await cloud.auth().verifyAccessToken({
      accessToken: String(accessToken),
      checkRevoked: true
    });
    const uid = String(verified.getSub() || '');
    if (!uid) throw new Error('AGC 访问凭证未包含用户标识。');
    return uid;
  } catch (_error) {
    throw new Error('登录凭证无效或已撤销，请重新登录。');
  }
}

function roundedLocation(payload) {
  const latE3 = Number(payload.latE3);
  const lonE3 = Number(payload.lonE3);
  if (!Number.isInteger(latE3) || !Number.isInteger(lonE3) ||
    latE3 < -90000 || latE3 > 90000 || lonE3 < -180000 || lonE3 > 180000) {
    throw new Error('位置参数必须是三位小数舍入后的整数坐标。');
  }
  return { latE3, lonE3 };
}

function collection(env) {
  const zoneName = String(env.SHIKE_DB_ZONE || process.env.SHIKE_DB_ZONE || 'shike');
  return cloud.database({ zoneName }).collection(FoodCard);
}

function safeArray(value) {
  if (Array.isArray(value)) return value.map((item) => String(item)).slice(0, 8);
  if (typeof value !== 'string' || !value) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.map((item) => String(item)).slice(0, 8) : [];
  } catch (_error) {
    return [];
  }
}

function haversineKm(aLatE3, aLonE3, bLatE3, bLonE3) {
  const rad = Math.PI / 180;
  const lat1 = aLatE3 / 1000 * rad;
  const lat2 = bLatE3 / 1000 * rad;
  const dLat = lat2 - lat1;
  const dLon = (bLonE3 - aLonE3) / 1000 * rad;
  const value = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 6371.0088 * 2 * Math.atan2(Math.sqrt(value), Math.sqrt(1 - value));
}

function publicCard(row, distanceKm) {
  return {
    id: String(row.id || ''),
    productName: String(row.productName || ''),
    brand: String(row.brand || ''),
    priceFen: Number(row.priceFen || 0),
    priceLabel: String(row.priceLabel || ''),
    originalPriceFen: Number(row.originalPriceFen || 0),
    specification: String(row.specification || ''),
    shop: String(row.shop || ''),
    sellingPoints: safeArray(row.sellingPointsJson),
    publicOffers: safeArray(row.publicOffersJson),
    sourceLink: String(row.sourceLink || ''),
    category: String(row.category || 'other'),
    photoUrl: '',
    photoPath: '',
    photoBucket: '',
    district: String(row.district || '当前位置'),
    distanceKm,
    // Only explicitly approved rows are public. Legacy or retired rows are
    // never promoted by this test-mode query.
    status: row.status === 'APPROVED' ? 'APPROVED' : 'REMOVED',
    createdAt: Number(row.createdAt || 0)
  };
}

async function checkLocation(input, env) {
  await verifyAgcAccessToken(input.accessToken);
  roundedLocation(input.payload || {});
  return {
    authenticated: true,
    locationAccepted: true,
    expiresAt: Date.now() + 60000
  };
}

async function listNearbyCards(input, env) {
  await verifyAgcAccessToken(input.accessToken);
  const point = roundedLocation(input.payload || {});
  const latDelta = Math.ceil(MAX_DISTANCE_KM / 111.0 * 1000);
  const latitude = point.latE3 / 1000 * Math.PI / 180;
  const lonDelta = Math.ceil(MAX_DISTANCE_KM / Math.max(1, 111.0 * Math.cos(latitude)) * 1000);
  const approvedRows = await collection(env).query()
    .equalTo('status', 'APPROVED')
    .greaterThanOrEqualTo('latE3', point.latE3 - latDelta)
    .lessThanOrEqualTo('latE3', point.latE3 + latDelta)
    .greaterThanOrEqualTo('lonE3', point.lonE3 - lonDelta)
    .lessThanOrEqualTo('lonE3', point.lonE3 + lonDelta)
    .limit(200).get();
  const matched = approvedRows
    .map((row) => ({ row, distanceKm: haversineKm(point.latE3, point.lonE3, row.latE3, row.lonE3) }))
    .filter((item) => item.distanceKm <= MAX_DISTANCE_KM)
    .sort((a, b) => itemOrder(a, b));
  const payload = input.payload || {};
  const offset = Math.max(0, Number.parseInt(String(payload.pageToken || '0'), 10) || 0);
  const pageSize = Math.floor(Math.min(MAX_PAGE_SIZE, Math.max(1, Number(payload.pageSize || MAX_PAGE_SIZE))));
  const cards = matched.slice(offset, offset + pageSize)
    .map((item) => publicCard(item.row, Number(item.distanceKm.toFixed(3))));
  return {
    cards,
    nextPageToken: offset + pageSize < matched.length ? String(offset + pageSize) : '',
    district: String(payload.district || '')
  };
}

function itemOrder(a, b) {
  return a.distanceKm - b.distanceKm || Number(b.row.createdAt || 0) - Number(a.row.createdAt || 0);
}

const operations = {
  'check-location': checkLocation,
  'list-nearby-cards': listNearbyCards
};

async function executeOperation(operation, input, env = process.env) {
  if (!operations[operation]) throw new Error(`未知位置操作 ${operation}`);
  const safeInput = input && typeof input === 'object' ? input : { accessToken: '', payload: {} };
  return operations[operation]({
    accessToken: typeof safeInput.accessToken === 'string' ? safeInput.accessToken : '',
    payload: safeInput.payload && typeof safeInput.payload === 'object' ? safeInput.payload : {}
  }, env || {});
}

module.exports = { executeOperation, safeLogError };
