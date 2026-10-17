/**
 * 【文件职责】Cloud DB 模型基类 CloudDbModel 与图片记录 CardMedia 模型（字段与 clouddb/objecttype/CardMedia.json 一致），供图片读取与媒体函数共用。
 */
'use strict';
// Cloud DB 模型基类（AGC 服务端 SDK 通过这些方法获取字段类型、类名、主键与索引）。
class CloudDbModel {
  getFieldTypeMap() { return new Map(Object.entries(this.constructor.fieldTypes)); }
  getClassName() { return this.constructor.name; }
  getPrimaryKeyList() { return [...this.constructor.primaryKeys]; }
  getIndexList() { return [...this.constructor.indexes]; }
  getEncryptedFieldList() { return []; }
}

// 图片记录模型。
class CardMedia extends CloudDbModel {}
CardMedia.fieldTypes = Object.freeze({
  id: 'String', cardId: 'String', ownerUid: 'String', storageUid: 'String',
  objectKey: 'String', sha256: 'String', preparedSha256: 'String', mimeType: 'String', byteSize: 'Integer',
  width: 'Integer', height: 'Integer', status: 'String', createdAt: 'Long',
  coverSha256: 'String', coverByteSize: 'Integer', coverWidth: 'Integer', coverHeight: 'Integer', coverSourceSha256: 'String', coverRecipeVersion: 'Integer'
});
CardMedia.primaryKeys = Object.freeze(['id']);
CardMedia.indexes = Object.freeze(['cardId', 'cardId,createdAt', 'ownerUid,createdAt']);


module.exports = { CloudDbModel, CardMedia };
