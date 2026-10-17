/**
 * 【文件职责】npm run package:cloud -- <云对象名> / package:cloud:all：为 7 个云对象调用统一打包器 packageFunction 生成独立 ZIP。
 */
import { packageFunction } from './package-functions.mjs';
const names = ['shike-auth', 'shike-media', 'shike-service',
  'shike-content', 'shike-social', 'shike-account', 'shike-governance'];
try {
  const name = process.argv[2];
  if (process.argv.length !== 3 || name !== '--all' && !names.includes(name)) throw new Error('Usage: npm run package:cloud:all, or npm run package:cloud -- <cloud-object-name>');
  for (const item of name === '--all' ? names : [name]) packageFunction(item);
} catch (error) { console.error(error.message); process.exitCode = 1; }
