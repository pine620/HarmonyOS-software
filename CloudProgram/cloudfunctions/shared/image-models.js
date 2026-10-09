'use strict';
class CloudDbModel {
  getFieldTypeMap() { return new Map(Object.entries(this.constructor.fieldTypes)); }
  getClassName() { return this.constructor.name; }
  getPrimaryKeyList() { return [...this.constructor.primaryKeys]; }
  getIndexList() { return [...this.constructor.indexes]; }
  getEncryptedFieldList() { return []; }
}

class CardMedia extends CloudDbModel {}
CardMedia.fieldTypes = Object.freeze({
  id: 'String', cardId: 'String', ownerUid: 'String', storageUid: 'String',
  objectKey: 'String', sha256: 'String', preparedSha256: 'String', mimeType: 'String', byteSize: 'Integer',
  width: 'Integer', height: 'Integer', status: 'String', createdAt: 'Long',
  coverSha256: 'String', coverByteSize: 'Integer', coverWidth: 'Integer', coverHeight: 'Integer', coverSourceSha256: 'String', coverRecipeVersion: 'Integer'
});
CardMedia.primaryKeys = Object.freeze(['id']);
CardMedia.indexes = Object.freeze(['cardId', 'cardId,createdAt', 'ownerUid,createdAt']);


module.exports = { CardMedia };
