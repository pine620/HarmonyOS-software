'use strict';
/**
 * 【文件职责】事件函数 shike-prefetch（handler：shikePrefetch.handler）：Cloud Foundation 预取的目标函数（安装预取与周期预取在 AGC 控制台配置）。
 * 只从 Cloud Storage 读取已发布的首页快照并返回：不读 Cloud DB、不校验身份、不写入，所以大量设备的预取请求不会消耗 Cloud DB 读额度。
 */
const { readSnapshot } = require('./shared/public-snapshot');
const { buildInfo } = require('./shared/release-info');

// 预取入口：成功返回快照数据，失败返回 SNAPSHOT_UNAVAILABLE（客户端随后改为正常查询）。
exports.handler = async (event, context, callback) => {
  let response;
  try {
    response = { ok: true, data: await readSnapshot(process.env), message: '', ...buildInfo };
  } catch (error) {
    console.error('prefetch.snapshot failed: ' + String(error && error.message || error).slice(0, 200));
    response = { ok: false, code: 'SNAPSHOT_UNAVAILABLE', message: '首页快照暂不可用。', ...buildInfo };
  }
  if (typeof callback === 'function') return callback(response);
  return response;
};
