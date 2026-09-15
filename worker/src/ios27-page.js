import { SOURCE_URL } from "./project.js";

export function getIos27PageHtml() {
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>WLOC iOS 27 CoreDevice</title>
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="WLOC 27">
<style>
:root { --blue:#007aff; --green:#34c759; --red:#ff3b30; --orange:#ff9500; --gray:#8e8e93; --bg:#f2f2f7; }
* { box-sizing:border-box; }
body { margin:0; font-family:-apple-system,system-ui,"SF Pro","Helvetica Neue",sans-serif; background:var(--bg); color:#111; }
main { max-width:640px; margin:0 auto; padding:18px 14px 48px; }
h1 { font-size:24px; margin:4px 0 6px; }
p { line-height:1.55; }
.card { background:#fff; border-radius:14px; padding:16px; margin-top:12px; box-shadow:0 1px 3px rgba(0,0,0,.07); }
.badge { display:inline-block; border-radius:999px; padding:4px 8px; font-size:12px; font-weight:600; background:#fff2d6; color:#8a5700; }
.badge.ok { background:#e6f8ea; color:#177a2f; }
.small { font-size:12px; color:var(--gray); }
.grid { display:grid; grid-template-columns:1fr 1fr; gap:8px; }
label { display:block; font-size:12px; color:var(--gray); margin-bottom:5px; }
input { width:100%; padding:11px 12px; border:1px solid #d1d1d6; border-radius:10px; font-size:15px; background:#fff; }
button { border:0; border-radius:10px; padding:11px 13px; font-size:14px; font-weight:600; cursor:pointer; }
.primary { background:var(--blue); color:#fff; }
.secondary { background:#e5e5ea; color:#222; }
.danger { background:var(--red); color:#fff; }
.row { display:flex; gap:8px; flex-wrap:wrap; margin-top:10px; }
.row button { flex:1; min-width:120px; }
pre { white-space:pre-wrap; word-break:break-word; margin:0; padding:12px; border-radius:10px; background:#111; color:#d7ffd7; font-size:12px; line-height:1.45; min-height:92px; max-height:260px; overflow:auto; }
.warn { border-left:4px solid var(--orange); padding-left:12px; }
.okline { border-left:4px solid var(--green); padding-left:12px; }
code { font-family:"SF Mono",ui-monospace,monospace; }
a { color:var(--blue); }
</style>
</head>
<body>
<main>
  <span class="badge">实验分支</span>
  <h1>WLOC · iOS 27 CoreDevice</h1>
  <p class="small">新版目标：WLOC 网页 → WLOC-enabled LocalDevVPN → RemotePairing → RSD → DVT → LocationSimulation。</p>

  <section class="card warn">
    <b>当前要求</b>
    <p>这里已经完全绕开旧 <code>gs-loc</code> MITM。当前 App Store / 原版 LocalDevVPN 只有 tunnel 能力，尚未实现下面的 <code>localdevvpn://wloc/...</code> 命令；需要集成 WLOC CoreDevice bridge 的 LocalDevVPN 构建。</p>
  </section>

  <section class="card">
    <h3>设备准备</h3>
    <p class="small">第一次使用先让 LocalDevVPN 为这台 iPhone 建立 Remote Pairing。配对记录必须只保存在设备本地，不上传 Worker。</p>
    <div class="row">
      <button class="primary" onclick="pairDevice()">配对这台 iPhone</button>
      <button class="secondary" onclick="requestStatus()">检查状态</button>
    </div>
  </section>

  <section class="card">
    <h3>目标坐标</h3>
    <div class="grid">
      <div>
        <label for="lat">纬度</label>
        <input id="lat" inputmode="decimal" value="34.052235">
      </div>
      <div>
        <label for="lon">经度</label>
        <input id="lon" inputmode="decimal" value="-118.243683">
      </div>
    </div>
    <div class="row">
      <button class="primary" onclick="setLocation()">设置位置</button>
      <button class="danger" onclick="clearLocation()">恢复真实位置</button>
    </div>
    <p class="small">坐标通过 iOS 本机 URL Scheme 交给 LocalDevVPN，不会由这个页面 POST 到 Cloudflare。正式版后续会把现有 WLOC 地图选点 UI 接到同一个命令层。</p>
  </section>

  <section class="card">
    <h3>运行能力</h3>
    <div id="caps">读取中...</div>
    <div class="row"><button class="secondary" onclick="loadCapabilities()">重新检测</button></div>
  </section>

  <section class="card okline">
    <b>Bridge v1 URL 协议</b>
    <p class="small"><code>localdevvpn://wloc/pair</code> · <code>/set</code> · <code>/clear</code> · <code>/status</code>。每次请求都带随机 request id 和 HTTPS callback；LocalDevVPN 完成后回到本页显示结果。</p>
  </section>

  <section class="card">
    <h3>诊断日志</h3>
    <pre id="log">WLOC iOS 27 frontend ready.</pre>
  </section>

  <p class="small">源码：<a href="${SOURCE_URL}" target="_blank" rel="noopener noreferrer">${SOURCE_URL}</a> · <a href="/">返回旧版 WLOC</a></p>
</main>
<script>
const BRIDGE_ROOT = 'localdevvpn://wloc';
let requestSeq = 0;

function log(message) {
  const el = document.getElementById('log');
  const stamp = new Date().toLocaleTimeString('zh-CN', { hour12:false });
  el.textContent += '\\n[' + stamp + '] ' + message;
  el.scrollTop = el.scrollHeight;
}

function validateCoords(latitude, longitude) {
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) throw new Error('经纬度必须是数字');
  if (latitude < -90 || latitude > 90) throw new Error('纬度必须在 -90..90');
  if (longitude < -180 || longitude > 180) throw new Error('经度必须在 -180..180');
}

function requestId() {
  requestSeq += 1;
  const random = globalThis.crypto && crypto.getRandomValues
    ? Array.from(crypto.getRandomValues(new Uint32Array(2))).map(v => v.toString(36)).join('')
    : Math.random().toString(36).slice(2);
  return 'wloc-' + Date.now().toString(36) + '-' + requestSeq.toString(36) + '-' + random;
}

function callbackURL(id, op) {
  const url = new URL(location.href);
  url.search = '';
  url.hash = '';
  url.searchParams.set('wloc_return', '1');
  url.searchParams.set('request', id);
  url.searchParams.set('op', op);
  return url.toString();
}

function bridgeURL(op, params = {}) {
  const id = requestId();
  const query = new URLSearchParams();
  query.set('v', '1');
  query.set('request', id);
  query.set('callback', callbackURL(id, op));
  for (const [key, value] of Object.entries(params)) query.set(key, String(value));
  return { id, url: BRIDGE_ROOT + '/' + op + '?' + query.toString() };
}

function launchBridge(op, params = {}) {
  const request = bridgeURL(op, params);
  sessionStorage.setItem('wloc_last_request', request.id);
  log('唤起 LocalDevVPN: ' + op + ' (' + request.id + ')');
  location.href = request.url;
}

function pairDevice() {
  launchBridge('pair');
}

function requestStatus() {
  launchBridge('status');
}

function setLocation() {
  try {
    const latitude = Number(document.getElementById('lat').value);
    const longitude = Number(document.getElementById('lon').value);
    validateCoords(latitude, longitude);
    launchBridge('set', {
      latitude: latitude.toFixed(6),
      longitude: longitude.toFixed(6)
    });
  } catch (error) {
    log('设置失败: ' + error.message);
  }
}

function clearLocation() {
  launchBridge('clear');
}

function consumeBridgeReturn() {
  const url = new URL(location.href);
  if (url.searchParams.get('wloc_return') !== '1') return;
  const request = url.searchParams.get('request') || '';
  const op = url.searchParams.get('op') || 'unknown';
  const status = url.searchParams.get('status') || 'unknown';
  const code = url.searchParams.get('code') || '';
  const message = url.searchParams.get('message') || '';
  const expected = sessionStorage.getItem('wloc_last_request') || '';

  if (expected && request && expected !== request) {
    log('忽略不匹配的 callback request: ' + request);
  } else {
    log('LocalDevVPN 回调: op=' + op + ' status=' + status + (code ? ' code=' + code : '') + (message ? ' message=' + message : ''));
    if (request) sessionStorage.removeItem('wloc_last_request');
  }

  for (const key of ['wloc_return','request','op','status','code','message']) url.searchParams.delete(key);
  history.replaceState(null, '', url.pathname + (url.search ? url.search : '') + url.hash);
}

async function loadCapabilities() {
  const el = document.getElementById('caps');
  try {
    const response = await fetch('/api/ios27/capabilities', { cache:'no-store' });
    const data = await response.json();
    const rows = [
      ['旧 MITM', data.legacyMitm ? 'legacy 保留' : '关闭'],
      ['iOS 27 控制方式', data.preferredControl],
      ['原版 LocalDevVPN', data.stockLocalDevVPNSupported ? '可直接使用' : '缺少 WLOC bridge'],
      ['浏览器 raw TCP', data.browserRawTcp ? '可用' : '不需要 / 不可用'],
      ['CoreDevice', data.coreDevicePath.join(' → ')]
    ];
    el.innerHTML = rows.map(([k,v]) => '<div style="display:flex;justify-content:space-between;gap:12px;padding:6px 0;border-bottom:1px solid #eee"><span>' + k + '</span><b style="text-align:right">' + v + '</b></div>').join('');
  } catch (error) {
    el.textContent = '能力信息读取失败';
    log(error.message);
  }
}

consumeBridgeReturn();
loadCapabilities();
<\/script>
</body>
</html>`;
}
