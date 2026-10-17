/**
 * 【文件职责】五套页面色板（笔记 / 榜单 / 社交 / 发布 / 个人）及其颜色角色。
 * 页面通过 pageColor(色板, 角色) 取颜色资源，亮色/暗色由系统按 resources/base 与 resources/dark 自动选择。
 */
export type PagePaletteName = 'NOTE' | 'RANKING' | 'SOCIAL' | 'CREATE' | 'PERSONAL';
// 在页面之间传递色板的路由参数。
export interface PagePaletteRoute { palette: PagePaletteName; }

// 颜色角色：画布、表面、正文、次要文字、分隔线、强调色等。
export type PageColorRole = 'canvas' | 'surface' | 'ink' | 'muted' | 'line' | 'gold' | 'on_gold' |
  'soft' | 'header' | 'header_clear' | 'header_fade' | 'action' | 'error' | 'good' | 'glow' | 'scrim';

// 返回字面量资源引用（$r），以保留系统原生的亮/暗色资源切换。
export function pageColor(palette: PagePaletteName, role: PageColorRole): Resource {
  if (palette === 'RANKING') {
    switch (role) {
      case 'canvas': return $r('app.color.food_ranking_canvas');
      case 'surface': return $r('app.color.food_ranking_surface');
      case 'ink': return $r('app.color.food_ranking_ink');
      case 'muted': return $r('app.color.food_ranking_muted');
      case 'line': return $r('app.color.food_ranking_line');
      case 'gold': return $r('app.color.food_ranking_action');
      case 'on_gold': return $r('app.color.food_ranking_on_action');
      case 'soft': return $r('app.color.food_ranking_tab_track');
      case 'header': return $r('app.color.food_ranking_header');
      case 'header_clear': return $r('app.color.food_ranking_header_clear');
      case 'header_fade': return $r('app.color.food_ranking_canvas');
      case 'action': return $r('app.color.food_ranking_accent');
      case 'error': return $r('app.color.create_error');
      case 'good': return $r('app.color.create_good');
      case 'glow': return $r('app.color.food_ranking_rank_top');
      case 'scrim': return $r('app.color.create_scrim');
    }
  }
  switch (role) {
    case 'canvas': return palette === 'SOCIAL' ? $r('app.color.social_canvas') : palette === 'PERSONAL' ? $r('app.color.personal_canvas') : palette === 'CREATE' ? $r('app.color.create_canvas') : $r('app.color.note_canvas');
    case 'surface': return palette === 'SOCIAL' ? $r('app.color.social_surface') : palette === 'PERSONAL' ? $r('app.color.personal_surface') : palette === 'CREATE' ? $r('app.color.create_surface') : $r('app.color.note_surface');
    case 'ink': return palette === 'SOCIAL' ? $r('app.color.social_ink') : palette === 'PERSONAL' ? $r('app.color.personal_ink') : palette === 'CREATE' ? $r('app.color.create_ink') : $r('app.color.note_ink');
    case 'muted': return palette === 'SOCIAL' ? $r('app.color.social_muted') : palette === 'PERSONAL' ? $r('app.color.personal_muted') : palette === 'CREATE' ? $r('app.color.create_muted') : $r('app.color.note_muted');
    case 'line': return palette === 'SOCIAL' ? $r('app.color.social_line') : palette === 'PERSONAL' ? $r('app.color.personal_line') : palette === 'CREATE' ? $r('app.color.create_line') : $r('app.color.note_line');
    case 'gold': return palette === 'SOCIAL' ? $r('app.color.social_accent') : palette === 'PERSONAL' ? $r('app.color.personal_accent') : palette === 'CREATE' ? $r('app.color.create_gold') : $r('app.color.note_gold');
    case 'on_gold': return palette === 'SOCIAL' ? $r('app.color.social_on_accent') : palette === 'PERSONAL' ? $r('app.color.personal_on_accent') : palette === 'CREATE' ? $r('app.color.create_on_gold') : $r('app.color.note_on_gold');
    case 'soft': return palette === 'SOCIAL' ? $r('app.color.social_soft') : palette === 'PERSONAL' ? $r('app.color.personal_soft') : palette === 'CREATE' ? $r('app.color.create_soft') : $r('app.color.note_soft');
    case 'header': return palette === 'SOCIAL' ? $r('app.color.social_header') : palette === 'PERSONAL' ? $r('app.color.personal_header') : palette === 'CREATE' ? $r('app.color.create_header') : $r('app.color.note_header');
    case 'header_clear': return palette === 'SOCIAL' ? $r('app.color.social_header_clear') : palette === 'PERSONAL' ? $r('app.color.personal_header_clear') : palette === 'CREATE' ? $r('app.color.create_header_clear') : $r('app.color.note_header_clear');
    case 'header_fade': return palette === 'SOCIAL' ? $r('app.color.social_header_fade') : palette === 'PERSONAL' ? $r('app.color.personal_header_fade') : palette === 'CREATE' ? $r('app.color.create_header_fade') : $r('app.color.note_header_fade');
    case 'action': return palette === 'SOCIAL' ? $r('app.color.social_action') : palette === 'PERSONAL' ? $r('app.color.personal_action') : palette === 'CREATE' ? $r('app.color.create_action') : $r('app.color.note_action');
    case 'error': return palette === 'SOCIAL' ? $r('app.color.social_error') : palette === 'PERSONAL' ? $r('app.color.personal_error') : palette === 'CREATE' ? $r('app.color.create_error') : $r('app.color.note_error');
    case 'good': return palette === 'SOCIAL' ? $r('app.color.social_good') : palette === 'PERSONAL' ? $r('app.color.personal_good') : $r('app.color.create_good');
    case 'glow': return palette === 'SOCIAL' ? $r('app.color.social_glow') : palette === 'PERSONAL' ? $r('app.color.personal_glow') : palette === 'CREATE' ? $r('app.color.create_glow') : $r('app.color.note_glow');
    case 'scrim': return palette === 'SOCIAL' ? $r('app.color.social_scrim') : palette === 'PERSONAL' ? $r('app.color.personal_scrim') : $r('app.color.create_scrim');
  }
  return $r('app.color.note_canvas');
}
