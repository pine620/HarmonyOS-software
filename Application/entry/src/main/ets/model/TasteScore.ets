/**
 * 【文件职责】口味评分（1–10 分）的展示文案。
 */
// 评分对应的短标签。
export function tasteScoreLabel(score: number): string {
  if (score === 1) return '难吃';
  if (score === 2) return '很差';
  if (score === 3) return '较差';
  if (score === 4) return '欠佳';
  if (score === 5) return '一般';
  if (score === 6) return '尚可';
  if (score === 7) return '不错';
  if (score === 8) return '好吃';
  if (score === 9) return '美味';
  if (score === 10) return '惊艳';
  return '未评分';
}

// 评分对应的说明文字。
export function tasteScoreReason(score: number): string {
  if (score === 1) return '味道或品质明显不合预期。';
  if (score === 2) return '整体体验不理想，记下最主要的问题。';
  if (score === 3) return '有明显短板，分享它哪里需要改进。';
  if (score === 4) return '表现偏弱，说说还差在哪一点。';
  if (score === 5) return '普通的一餐，谈不上惊喜。';
  if (score === 6) return '整体尚可，也许有一处小亮点。';
  if (score === 7) return '表现不错，值得告诉朋友。';
  if (score === 8) return '味道出色，值得再来一次。';
  if (score === 9) return '非常美味，值得专程再吃。';
  if (score === 10) return '记忆点十足，想强烈推荐给大家。';
  return '';
}

// “x 分 · 标签”形式的完整文本。
export function tasteScoreText(score: number): string {
  if (!Number.isInteger(score) || score < 1 || score > 10) return '';
  return `${score}/10 · ${tasteScoreLabel(score)}`;
}
