/**
 * 【文件职责】npm run package:maintenance：打包 shike-maintenance。
 */
import { packageFunction } from './package-functions.mjs';
try { packageFunction('shike-maintenance'); } catch (error) { console.error(error.message); process.exitCode = 1; }
