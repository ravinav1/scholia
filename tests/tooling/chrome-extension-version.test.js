import test from 'node:test';
import assert from 'node:assert/strict';
import {
  isChromeExtensionVersion,
  localChromeExtensionVersion
} from '../../scripts/build/chrome-extension-version.mjs';

test('local Chrome build versions are valid timestamp versions', () => {
  const version = localChromeExtensionVersion(new Date('2026-08-02T13:45:06.007Z'));
  assert.equal(version, '2026.802.1345.6007');
  assert.equal(isChromeExtensionVersion(version), true);
});

test('local Chrome build versions always advance past the previous build', () => {
  const date = new Date('2026-08-02T13:45:06.007Z');
  assert.equal(
    localChromeExtensionVersion(date, '2026.802.1345.6007'),
    '2026.802.1345.6008'
  );
  assert.equal(
    localChromeExtensionVersion(date, '2026.802.1345.65535'),
    '2026.802.1346.0'
  );
});

test('Chrome extension version validation follows manifest constraints', () => {
  assert.equal(isChromeExtensionVersion('0.1.0'), true);
  assert.equal(isChromeExtensionVersion('1.2.3.65535'), true);
  assert.equal(isChromeExtensionVersion('0.0.0.0'), false);
  assert.equal(isChromeExtensionVersion('1.02'), false);
  assert.equal(isChromeExtensionVersion('1.2.3.65536'), false);
  assert.equal(isChromeExtensionVersion('1.2.3.4.5'), false);
});
