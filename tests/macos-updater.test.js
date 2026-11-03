import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, copyFile, writeFile, readFile, readdir, access, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const execute = promisify(execFile);

// Exercise real AppKit force quit with disposable apps sharing one bundle ID.
// Only signature checks are stubbed; no installed app or signing key is touched.
test('macOS updater force quits exact running copies, including apps that refuse normal quit', {
  skip: process.platform !== 'darwin', timeout: 60_000
}, async t => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-updater-'));
  const children = [];
  t.after(async () => {
    for (const child of children) {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    }
    await Promise.all(children.map(child => child.exitCode !== null || child.signalCode !== null
      ? Promise.resolve() : new Promise(resolve => child.once('exit', resolve))));
    await rm(root, { recursive: true, force: true });
  });

  const scripts = join(root, 'scripts');
  const bin = join(root, 'bin');
  const destination = join(root, 'Applications [test]', 'Scholia.app');
  const source = join(root, 'dist', 'macos', 'Scholia.app');
  const unrelated = join(root, 'Other', 'Scholia.app');
  await mkdir(scripts);
  await mkdir(bin);
  for (const name of ['install-macos-app.sh', 'quit-macos-apps.js']) {
    await copyFile(new URL(`../scripts/${name}`, import.meta.url), join(scripts, name));
  }
  await writeFile(join(bin, 'codesign'), '#!/bin/sh\necho "designated => identifier \\"fixture\\""\n', { mode: 0o755 });
  const fixtureSource = join(root, 'Fixture.m');
  const fixtureBinary = join(root, 'Fixture');
  await writeFile(fixtureSource, `
#import <AppKit/AppKit.h>
static NSString *marker;
static BOOL refuse;
static void mark(NSString *suffix) {
    [@"yes" writeToFile:[marker stringByAppendingString:suffix]
              atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
@interface FixtureDelegate : NSObject <NSApplicationDelegate>
@end
@implementation FixtureDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification { mark(@".ready"); }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    mark(@".requested");
    return refuse ? NSTerminateCancel : NSTerminateNow;
}
- (void)applicationWillTerminate:(NSNotification *)notification { mark(@".saved"); }
@end
int main(int argc, const char **argv) {
    @autoreleasepool {
        marker = [NSString stringWithUTF8String:argv[1]];
        refuse = argc > 2;
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        FixtureDelegate *delegate = [FixtureDelegate new];
        app.delegate = delegate;
        [app run];
    }
}
`);
  await execute('/usr/bin/clang', ['-fobjc-arc', '-framework', 'AppKit', fixtureSource, '-o', fixtureBinary]);
  for (const path of [source, destination, unrelated]) {
    await mkdir(join(path, 'Contents', 'MacOS'), { recursive: true });
    await copyFile(fixtureBinary, join(path, 'Contents', 'MacOS', 'Fixture'));
    await writeFile(join(path, 'Contents', 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundleIdentifier</key><string>app.scholia.updater-fixture.${root.split('-').at(-1)}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>`);
  }
  await writeFile(join(source, 'version.txt'), 'new build');
  await writeFile(join(destination, 'version.txt'), 'old build');
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, TMPDIR: root, SCHOLIA_INSTALL_PATH: destination };
  const install = (...args) => execute('/bin/zsh', [join(scripts, 'install-macos-app.sh'), '--skip-build', ...args], { env, timeout: 25_000 });
  async function launch(path, name, refuses = false) {
    const marker = join(root, name);
    const child = spawn(join(path, 'Contents', 'MacOS', 'Fixture'), [marker, ...(refuses ? ['refuse'] : [])], { stdio: 'ignore' });
    children.push(child);
    const deadline = Date.now() + 5_000;
    while (true) {
      try { await access(`${marker}.ready`); break; } catch {}
      assert.equal(child.exitCode, null, 'Fixture must stay running');
      assert.ok(Date.now() < deadline, 'Fixture must finish launching');
      await delay(50);
    }
    return { child, marker };
  }
  const sourceInstance = await launch(source, 'source');
  const installedInstance = await launch(destination, 'installed');
  const otherInstance = await launch(unrelated, 'other');

  await install('--check-only');
  assert.equal(await readFile(join(destination, 'version.txt'), 'utf8'), 'old build');
  for (const instance of [sourceInstance, installedInstance, otherInstance]) {
    await assert.rejects(access(`${instance.marker}.requested`), { code: 'ENOENT' });
    assert.equal(instance.child.exitCode, null);
    assert.equal(instance.child.signalCode, null, 'Checking compatibility must not quit running apps');
  }

  await install();
  for (const instance of [sourceInstance, installedInstance]) {
    assert.ok(instance.child.signalCode, 'The old process must be terminated before replacement');
    await assert.rejects(access(`${instance.marker}.requested`), { code: 'ENOENT' });
  }
  assert.equal(await readFile(join(destination, 'version.txt'), 'utf8'), 'new build');
  await assert.rejects(access(`${otherInstance.marker}.requested`), { code: 'ENOENT' });
  assert.equal(otherInstance.child.exitCode, null, 'A third copy with the same identifier must stay open');
  assert.equal(otherInstance.child.signalCode, null);

  await writeFile(join(destination, 'version.txt'), 'replace this build');
  const refusing = await launch(destination, 'refusing', true);
  await install();
  assert.ok(refusing.child.signalCode, 'A quit dialog must not block the update');
  assert.equal(await readFile(join(destination, 'version.txt'), 'utf8'), 'new build');
  assert.equal(otherInstance.child.signalCode, null, 'Only the copies being replaced may be force quit');
  const remaining = await readdir(join(root, 'Applications [test]'));
  assert.deepEqual(remaining, ['Scholia.app'], 'Successful staging must be cleaned up');
});

// Opt in because this opens disposable Terminal windows in the current desktop.
test('Enter closes only the updater Terminal window after success or failure', {
  skip: process.platform !== 'darwin' || process.env.SCHOLIA_TEST_TERMINAL !== '1', timeout: 60_000
}, async t => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-terminal-'));
  const windowIDs = [];
  const shellQuote = value => `'${value.replaceAll("'", "'\\''")}'`;
  const terminal = async (script, ...args) => {
    const result = await execute('/usr/bin/osascript', ['-l', 'JavaScript', '-e', `
      function run(args) {
        const terminal = Application('Terminal');
        ${script}
      }
    `, ...args.map(String)], { timeout: 10_000 });
    return result.stdout.trim();
  };
  const openWindow = async command => {
    const id = Number(await terminal(`
      const tab = terminal.doScript(args[0]);
      return terminal.windows().find(window => window.tabs().some(item => item.tty() === tab.tty())).id();
    `, command));
    windowIDs.push(id);
    return id;
  };
  const exists = async id => await terminal('return terminal.windows.byId(Number(args[0])).exists();', id) === 'true';
  t.after(async () => {
    for (const id of windowIDs) {
      await terminal(`
        const window = terminal.windows.byId(Number(args[0]));
        if (window.exists() && !window.selectedTab().busy()) window.close({ saving: 'no' });
      `, id);
    }
    await rm(root, { recursive: true, force: true });
  });
  await mkdir(join(root, 'scripts'));
  await copyFile(new URL('../Update Scholia.command', import.meta.url), join(root, 'Update Scholia.command'));
  await copyFile(new URL('../scripts/close-updater-terminal.applescript', import.meta.url), join(root, 'scripts', 'close-updater-terminal.applescript'));
  // Run the real launcher; replace only the installer so no app is rebuilt or installed.
  await writeFile(join(root, 'scripts', 'install-macos-app.sh'), '#!/bin/zsh\nexit "$2"\n');
  for (const exitCode of [0, 7]) {
    const resultPath = join(root, `result-${exitCode}`);
    const command = `/bin/zsh ${shellQuote(join(root, 'Update Scholia.command'))} ${exitCode}; update_result=$?; print -r -- "$update_result" > ${shellQuote(resultPath)}; exit "$update_result"`;
    const updater = await openWindow(`exec /bin/zsh -c ${shellQuote(command)}`);
    const promptDeadline = Date.now() + 10_000;
    while (true) {
      const contents = await terminal('return terminal.windows.byId(Number(args[0])).selectedTab().contents();', updater);
      if (contents.includes('Press Enter to close this window.')) {
        assert.ok(contents.includes(exitCode === 0 ? 'Scholia is ready.' : 'The update did not finish.'));
        break;
      }
      assert.ok(Date.now() < promptDeadline, `The result must wait for Enter. Terminal shows: ${contents}`);
      await delay(100);
    }
    const unrelated = await openWindow('');
    assert.ok(await exists(updater), 'The updater must remain open until Enter is pressed');
    await terminal('terminal.doScript("", { in: terminal.windows.byId(Number(args[0])).selectedTab() });', updater);
    const closeDeadline = Date.now() + 15_000;
    while (await exists(updater)) {
      if (Date.now() >= closeDeadline) {
        const state = await terminal(`
          const tab = terminal.windows.byId(Number(args[0])).selectedTab();
          return JSON.stringify({ tty: tab.tty(), busy: tab.busy(), processes: tab.processes(), contents: tab.contents() });
        `, updater);
        assert.fail(`Enter must close the actual window. Terminal shows: ${state}`);
      }
      await delay(100);
    }
    assert.equal((await readFile(resultPath, 'utf8')).trim(), String(exitCode), 'The installer exit status must survive the prompt');
    assert.ok(await exists(unrelated), 'Another Terminal window must remain open');
  }
});
