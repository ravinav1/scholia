// Run with osascript -l JavaScript. NSRunningApplication addresses each running
// instance directly, even when several app bundles have the same identifier.
ObjC.import('AppKit');

function appPath(path) {
  return ObjC.unwrap($(path).stringByStandardizingPath.stringByResolvingSymlinksInPath);
}

function run(paths) {
  if (!paths.length) throw new Error('Pass at least one app bundle path to quit.');
  const targets = paths.map(appPath);
  const requested = [];
  const deadline = Date.now() + 15_000;

  while (true) {
    const apps = $.NSWorkspace.sharedWorkspace.runningApplications;
    const pending = [];
    for (let index = 0; index < apps.count; index++) {
      const app = apps.objectAtIndex(index);
      const url = app.bundleURL;
      if (url.isNil() || app.terminated) continue;
      const path = appPath(ObjC.unwrap(url.path));
      if (!targets.includes(path)) continue;
      const description = `${path} (PID ${app.processIdentifier})`;
      pending.push(description);
      if (requested.some(previous => previous.isEqual(app))) continue;
      console.log(`Force quitting Scholia: ${description}`);
      if (!app.forceTerminate && !app.terminated) {
        throw new Error(`Could not force quit Scholia: ${description}. Quit it and run the updater again.`);
      }
      requested.push(app);
    }
    if (!pending.length) return;
    if (Date.now() >= deadline) {
      throw new Error(`Scholia is still running after force quit: ${pending.join(', ')}. Quit it before running the updater again.`);
    }
    // AppKit caches running/terminated state until the main run loop advances.
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));
  }
}
