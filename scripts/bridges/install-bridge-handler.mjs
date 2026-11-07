#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const scripts = dirname(fileURLToPath(import.meta.url));
const handlers = {
  codex: {
    scriptName: 'install-bridge-handler.mjs codex',
    displayName: 'Scholia Codex Bridge',
    appName: 'Scholia Codex Bridge.app',
    bundleId: 'app.scholia.codexbridge',
    scheme: 'scholia-codex',
    defaultPort: 8789,
    binary: 'codex',
    launcher: join(scripts, 'start-codex-bridge.command'),
    environmentFile: join(scripts, '.codex-bridge-env'),
    directCommand: 'node scripts/bridges/codex-bridge.mjs --port 8789',
    environment: ({ nodePath, binaryPath, port }) => ({
      NODE: nodePath,
      CODEX: binaryPath,
      PORT: port,
    }),
  },
  claude: {
    scriptName: 'install-bridge-handler.mjs claude',
    displayName: 'Scholia Claude Bridge',
    appName: 'ScholiaClaudeBridge.app',
    bundleId: 'app.scholia.claudecodebridge',
    scheme: 'claudecode',
    defaultPort: 8787,
    binary: 'claude',
    launcher: join(scripts, 'start-claude-bridge.command'),
    environmentFile: join(scripts, '.claude-bridge-env'),
    directCommand: 'node scripts/bridges/claude-code-bridge.mjs --port 8787',
    environment: ({ nodePath, binaryPath, port }) => ({
      BRIDGE_NODE: nodePath,
      BRIDGE_CLAUDE: binaryPath,
      BRIDGE_PORT: port,
    }),
  },
  opencode: {
    scriptName: 'install-bridge-handler.mjs opencode',
    displayName: 'Scholia opencode Launcher',
    appName: 'ScholiaOpencodeLauncher.app',
    bundleId: 'app.scholia.opencodelauncher',
    scheme: 'opencode',
    defaultPort: 4096,
    binary: 'opencode',
    launcher: join(scripts, 'start-opencode.command'),
    environmentFile: join(scripts, '.opencode-env'),
    directCommand: 'opencode serve --port 4096',
    environment: ({ binaryPath, port }) => ({
      OPENCODE_BIN: binaryPath,
      OPENCODE_PORT: port,
    }),
  },
};

const PLIST_BUDDY = '/usr/libexec/PlistBuddy';
const LAUNCH_SERVICES = [
  '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
  '/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister',
];

function parseArguments(argv, defaultPort) {
  const result = { help: false, uninstall: false, port: defaultPort };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--help' || argument === '-h') result.help = true;
    else if (argument === '--uninstall') result.uninstall = true;
    else if (argument === '--port') result.port = Number(argv[++index]);
    else throw new Error(`Unknown option: ${argument}`);
  }
  if (!Number.isInteger(result.port) || result.port < 1 || result.port > 65_535) {
    throw new Error('--port must be an integer between 1 and 65535.');
  }
  return result;
}

function findExecutable(name) {
  try {
    return execFileSync('/usr/bin/which', [name], { encoding: 'utf8' }).trim().split('\n')[0] || '';
  } catch {
    return '';
  }
}

function launchServices(args) {
  const executable = LAUNCH_SERVICES.find(existsSync);
  if (!executable) return;
  try {
    execFileSync(executable, args, { stdio: 'ignore' });
  } catch {
    // Launch Services registration is best-effort; opening the app also registers it.
  }
}

function plist(appPath, command, optional = false) {
  const plistPath = join(appPath, 'Contents', 'Info.plist');
  try {
    execFileSync(PLIST_BUDDY, ['-c', command, plistPath], { stdio: 'ignore' });
  } catch (error) {
    if (!optional) throw error;
  }
}

function setPlistValue(appPath, key, type, value) {
  try {
    plist(appPath, `Set :${key} ${value}`);
  } catch {
    plist(appPath, `Add :${key} ${type} ${value}`);
  }
}

function escapeAppleScript(value) {
  return String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function environmentFile(values) {
  return (
    Object.entries(values)
      .map(([name, value]) => `${name}=${shellQuote(value)}`)
      .join('\n') + '\n'
  );
}

function compileHandler(config, targetPath) {
  const temporaryDirectory = mkdtempSync(join(tmpdir(), 'scholia-handler-'));
  const sourcePath = join(temporaryDirectory, 'handler.applescript');
  const compiledPath = join(temporaryDirectory, basename(targetPath));
  const launcher = escapeAppleScript(config.launcher);
  const source = [
    'on launchService()',
    `  do shell script "/bin/bash " & quoted form of "${launcher}"`,
    'end launchService',
    '',
    'on open location this_URL',
    '  launchService()',
    'end open location',
    '',
    'on run',
    '  launchService()',
    'end run',
    '',
  ].join('\n');

  try {
    writeFileSync(sourcePath, source, 'utf8');
    execFileSync('/usr/bin/osacompile', ['-o', compiledPath, sourcePath], { stdio: 'inherit' });
    setPlistValue(compiledPath, 'CFBundleIdentifier', 'string', config.bundleId);
    setPlistValue(compiledPath, 'LSUIElement', 'bool', 'true');
    plist(compiledPath, 'Delete :CFBundleURLTypes', true);
    plist(compiledPath, 'Add :CFBundleURLTypes array');
    plist(compiledPath, 'Add :CFBundleURLTypes:0 dict');
    plist(compiledPath, `Add :CFBundleURLTypes:0:CFBundleURLName string ${config.displayName}`);
    plist(compiledPath, 'Add :CFBundleURLTypes:0:CFBundleURLSchemes array');
    plist(compiledPath, `Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string ${config.scheme}`);

    mkdirSync(join(homedir(), 'Applications'), { recursive: true });
    if (existsSync(targetPath)) {
      launchServices(['-u', targetPath]);
      rmSync(targetPath, { recursive: true, force: true });
    }
    cpSync(compiledPath, targetPath, { recursive: true });
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

function runMacUrlHandlerInstaller(config, argv) {
  try {
    const options = parseArguments(argv, config.defaultPort);
    const usage = `node scripts/bridges/${config.scriptName} [--port N] [--uninstall]`;
    if (options.help) {
      console.log(`Usage: ${usage}`);
      return;
    }
    if (process.platform !== 'darwin') {
      throw new Error(
        `This installer supports macOS only. Start the service directly with: ${config.directCommand}`
      );
    }

    const appPath = join(homedir(), 'Applications', config.appName);
    if (options.uninstall) {
      if (existsSync(appPath)) {
        launchServices(['-u', appPath]);
        rmSync(appPath, { recursive: true, force: true });
      }
      rmSync(config.environmentFile, { force: true });
      console.log(`Removed the ${config.scheme}:// handler.`);
      return;
    }
    if (!existsSync(config.launcher)) throw new Error(`Missing launcher: ${config.launcher}`);

    const binaryPath = findExecutable(config.binary);
    if (!binaryPath) {
      console.warn(
        `${config.binary} was not found on PATH. The launcher will probe common locations.`
      );
    }

    compileHandler(config, appPath);
    chmodSync(config.launcher, 0o755);
    writeFileSync(
      config.environmentFile,
      environmentFile(
        config.environment({
          binaryPath: binaryPath || config.binary,
          nodePath: process.execPath,
          port: options.port,
        })
      ),
      { mode: 0o600 }
    );
    launchServices(['-f', appPath]);

    console.log(`Installed ${config.displayName} at ${appPath}`);
    console.log(`URL scheme: ${config.scheme}://start`);
    console.log(`Port: ${options.port}`);
    console.log(`Uninstall: node scripts/bridges/${config.scriptName} --uninstall`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

const [provider, ...args] = process.argv.slice(2);
if (provider === '--help' || provider === '-h') {
  console.log(
    'Usage: node scripts/bridges/install-bridge-handler.mjs <codex|claude|opencode> [--port N] [--uninstall]'
  );
} else if (!Object.hasOwn(handlers, provider)) {
  console.error('Choose a bridge: codex, claude, or opencode. Use --help for usage.');
  process.exitCode = 1;
} else {
  runMacUrlHandlerInstaller(handlers[provider], args);
}
