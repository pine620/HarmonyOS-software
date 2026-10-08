import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
// User-run preparation; never calls a gateway, deploys a site, or opens a browser.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
if (args.length !== 4 || args[0] !== '--api-base' || args[2] !== '--web-origin') throw new Error('Usage: node scripts/configure-share-hosting.mjs --api-base HTTPS_GATEWAY_BASE --web-origin HTTPS_HOSTING_ORIGIN');
function https(value) { const url = new URL(value); if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) throw new Error('Use a real HTTPS URL without credentials, query, or fragment.'); return url; }
const api = https(args[1]), web = https(args[3]);
if (web.pathname !== '/') throw new Error('Hosting origin must not contain a path.');
const source = join(root, 'hosting', 'share'), target = join(root, 'build', 'hosting', 'share');
const contract = JSON.parse(readFileSync(join(source, 'hosting-contract.json'), 'utf8'));
const csp = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self' " + api.origin + "; object-src 'none'; base-uri 'none'; frame-ancestors 'none'";
contract.origin = web.origin; contract.requiredHeaders['Content-Security-Policy'] = csp;
mkdirSync(target, {recursive:true});
for (const name of ['index.html','app.js','style.css']) copyFileSync(join(source,name),join(target,name));
writeFileSync(join(target,'config.json'), JSON.stringify({apiBase:api.href.replace(/\/$/,''),appLinkBase:'https://shike.drcn.agconnect.link/card'},null,2)+'\n');
writeFileSync(join(target,'hosting-contract.json'), JSON.stringify(contract,null,2)+'\n');
console.log('Prepared assets: '+target);
console.log('Set SHIKE_SHARE_ALLOWED_ORIGINS to '+web.origin+' on the dedicated HTTP function.');
console.log('Map hosting-contract.json rewrites and headers in the actual provider console; this is not a vendor CLI manifest.');
console.log('Keep the existing App Linking /card?cardId contract; register and verify this site as its web fallback.');
console.log('No hosting publish, API request, deployment, or test performed.');
