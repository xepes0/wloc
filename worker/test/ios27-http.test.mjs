import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import app from '../src/index.js';

test('iOS 27 页面存在且内联脚本可解析', async () => {
  const response = await app.request('/ios27');
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.ok(html.includes('WLOC · iOS 27 CoreDevice'));
  assert.ok(html.includes("const BRIDGE_ROOT = 'localdevvpn://wloc'"));
  assert.ok(html.includes("launchBridge('pair')"));
  assert.ok(html.includes("launchBridge('set'"));
  assert.ok(html.includes("launchBridge('clear')"));
  assert.ok(!html.includes("const SAVE_API = 'https://gs-loc.apple.com/wloc-settings/save'"));
  const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)]
    .map(x => x[1])
    .filter(x => x.trim());
  assert.ok(scripts.length > 0);
  for (const script of scripts) new vm.Script(script);
});

test('iOS 27 capabilities 固定 LocalDevVPN bridge 契约', async () => {
  const response = await app.request('/api/ios27/capabilities');
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.version, 2);
  assert.equal(data.coreDeviceFrontend, true);
  assert.equal(data.browserRawTcp, false);
  assert.equal(data.preferredControl, 'LocalDevVPN URL bridge');
  assert.equal(data.stockLocalDevVPNSupported, false);
  assert.equal(data.wlocEnabledLocalDevVPNRequired, true);
  assert.equal(data.bridgeScheme, 'localdevvpn://wloc');
  assert.deepEqual(data.bridgeOperations, ['pair', 'set', 'clear', 'status']);
  assert.deepEqual(data.coreDevicePath, ['RemotePairing', 'RSD', 'DVT', 'LocationSimulation']);
  assert.equal(response.headers.get('cache-control'), 'no-store');
});
