'use strict';
const elements = Object.fromEntries(['status','card','cover','name','merchant','price','score','review','mode','open','retry'].map(k => [k, document.getElementById(k)]));
let config, controller, coverUrl = '', generation = 0;
const params = new URLSearchParams(location.search);
const cardId = /^\/card\/([A-Za-z0-9_-]{1,160})\/?$/.exec(location.pathname)?.[1] || (params.getAll('cardId').length === 1 ? params.get('cardId') : '');
function clear() { elements.card.hidden = true; elements.open.hidden = true; elements.cover.hidden = true; elements.cover.removeAttribute('src'); if (coverUrl) URL.revokeObjectURL(coverUrl); coverUrl = ''; for (const key of ['name','merchant','price','score','review','mode']) elements[key].textContent = ''; }
function invalidate() { generation++; if (controller) controller.abort(); clear(); }
async function load() {
  invalidate(); const current = generation; const requestController = new AbortController(); controller = requestController; const signal = requestController.signal; elements.retry.disabled = true; elements.status.textContent = '正在重新验证公开内容…';
  const timeout = setTimeout(() => requestController.abort(), 15000);
  try {
    if (!/^[A-Za-z0-9_-]{1,160}$/.test(cardId || '')) throw new Error('内容已不可访问');
    if (!config) {
      const response = await fetch('/config.json', {cache:'no-store', credentials:'omit', signal}); if (!response.ok) throw new Error('分享服务暂不可用'); const raw = await response.json();
      const api = new URL(raw.apiBase); const app = new URL(raw.appLinkBase);
      if (api.protocol !== 'https:' || api.username || api.password || api.search || api.hash || app.origin !== 'https://shike.drcn.agconnect.link' || app.pathname !== '/card' || app.search || app.hash) throw new Error('分享服务尚未配置');
      config = {apiBase:api.href.replace(/\/$/,''), appLinkBase:app.href};
    }
    const base = config.apiBase + '/api/';
    const response = await fetch(base + 'card/' + encodeURIComponent(cardId), {cache:'no-store', credentials:'omit', signal}); if (!response.ok) throw new Error(response.status === 429 ? '读取较频繁，请稍后重试' : '内容已不可访问');
    if (Number(response.headers.get('Content-Length') || 0) > 32768) throw new Error('内容已不可访问');
    const text = await response.text(); if (text.length > 32768) throw new Error('内容已不可访问'); const card = JSON.parse(text);
    if (card.cardId !== cardId || typeof card.productName !== 'string' || typeof card.reviewText !== 'string') throw new Error('内容已不可访问');
    let blob;
    if (card.coverAvailable) { const photo = await fetch(base + 'media/' + encodeURIComponent(cardId), {cache:'no-store', credentials:'omit', signal}); if (!photo.ok) throw new Error('内容已不可访问'); blob = await photo.blob(); if (blob.type !== 'image/jpeg' || blob.size > 2097152) throw new Error('内容已不可访问'); }
    // Recheck after the media request, so a visibility change cannot reuse the initial DTO.
    const confirmation = await fetch(base + 'card/' + encodeURIComponent(cardId), {cache:'no-store', credentials:'omit', signal}); if (!confirmation.ok) throw new Error('内容已不可访问'); const fresh = await confirmation.json(); if (fresh.contentVersion !== card.contentVersion) throw new Error('内容已变化，请重新读取');
    if (current !== generation || document.hidden) return;
    elements.name.textContent = card.productName.slice(0,100); elements.merchant.textContent = String(card.merchantName || '').slice(0,100);
    elements.price.textContent = card.priceFen === null ? '价格待补充' : '¥' + (Number(card.priceFen)/100).toFixed(2);
    elements.score.textContent = '口味 ' + Number(card.tasteScore).toString() + ' 分'; elements.review.textContent = card.reviewText.slice(0,2000);
    elements.mode.textContent = card.consumptionMode === 'DELIVERY' ? '外卖' : card.consumptionMode === 'DINE_IN' ? '到店' : '历史推荐';
    if (blob) { coverUrl = URL.createObjectURL(blob); elements.cover.src = coverUrl; elements.cover.hidden = false; }
    elements.card.hidden = false; elements.open.href = config.appLinkBase + '?cardId=' + encodeURIComponent(cardId); elements.open.hidden = false; elements.status.textContent = '';
  } catch (error) { if (current === generation) { clear(); elements.status.textContent = error && error.name === 'AbortError' ? '读取未完成，请重试' : error.message || '内容已不可访问'; } }
  finally { clearTimeout(timeout); if (current === generation) elements.retry.disabled = false; }
}
elements.retry.addEventListener('click', load);
document.addEventListener('visibilitychange', () => { if (document.hidden) { invalidate(); elements.retry.disabled = false; } else load(); });
window.addEventListener('pagehide', invalidate); window.addEventListener('pageshow', load); window.addEventListener('focus', () => { if (!document.hidden) load(); });
setInterval(() => { if (!document.hidden && !elements.retry.disabled) load(); }, 30000);
load();
