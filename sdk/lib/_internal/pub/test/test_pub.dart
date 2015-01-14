// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Test infrastructure for testing pub.
///
/// Unlike typical unit tests, most pub tests are integration tests that stage
/// some stuff on the file system, run pub, and then validate the results. This
/// library provides an API to build tests like that.
library test_pub;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:scheduled_test/scheduled_process.dart';
import 'package:scheduled_test/scheduled_server.dart';
import 'package:scheduled_test/scheduled_stream.dart';
import 'package:scheduled_test/scheduled_test.dart' hide fail;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:unittest/compact_vm_config.dart';
import 'package:yaml/yaml.dart';

import '../lib/src/entrypoint.dart';
import '../lib/src/exit_codes.dart' as exit_codes;
// TODO(rnystrom): Using "gitlib" as the prefix here is ugly, but "git" collides
// with the git descriptor method. Maybe we should try to clean up the top level
// scope a bit?
import '../lib/src/git.dart' as gitlib;
import '../lib/src/http.dart';
import '../lib/src/io.dart';
import '../lib/src/lock_file.dart';
import '../lib/src/log.dart' as log;
import '../lib/src/package.dart';
import '../lib/src/pubspec.dart';
import '../lib/src/source/hosted.dart';
import '../lib/src/source/path.dart';
import '../lib/src/source_registry.dart';
import '../lib/src/system_cache.dart';
import '../lib/src/utils.dart';
import '../lib/src/validator.dart';
import 'descriptor.dart' as d;
import 'serve_packages.dart';

export 'serve_packages.dart';

/// This should be called at the top of a test file to set up an appropriate
/// test configuration for the machine running the tests.
initConfig() {
  useCompactVMConfiguration();
  filterStacks = true;
  unittestConfiguration.timeout = null;
}

/// The current [HttpServer] created using [serve].
var _server;

/// The list of paths that have been requested from the server since the last
/// call to [getRequestedPaths].
final _requestedPaths = <String>[];

/// The cached value for [_portCompleter].
Completer<int> _portCompleterCache;

/// A [Matcher] that matches JavaScript generated by dart2js with minification
/// enabled.
Matcher isMinifiedDart2JSOutput =
    isNot(contains("// The code supports the following hooks"));

/// A [Matcher] that matches JavaScript generated by dart2js with minification
/// disabled.
Matcher isUnminifiedDart2JSOutput =
    contains("// The code supports the following hooks");

/// A map from package names to paths from which those packages should be loaded
/// for [createLockFile].
///
/// This allows older versions of dependencies than those that exist in the repo
/// to be used when testing pub.
Map<String, String> _packageOverrides;

/// A map from barback versions to the paths of directories in the repo
/// containing them.
///
/// This includes the latest version of barback from pkg as well as all old
/// versions of barback in third_party.
final _barbackVersions = _findBarbackVersions();

/// Some older barback versions require older versions of barback's dependencies
/// than those that are in the repo.
///
/// This is a map from barback version ranges to the dependencies for those
/// barback versions. Each dependency version listed here should be included in
/// third_party/pkg.
final _barbackDeps = {
  new VersionConstraint.parse("<0.15.0"): {
    "source_maps": "0.9.4"
  }
};

/// Populates [_barbackVersions].
Map<Version, String> _findBarbackVersions() {
  var versions = {};
  var currentBarback = p.join(repoRoot, 'third_party', 'pkg', 'barback');
  versions[new Pubspec.load(currentBarback, new SourceRegistry()).version] =
      currentBarback;

  for (var dir in listDir(p.join(repoRoot, 'third_party', 'pkg'))) {
    var basename = p.basename(dir);
    if (!basename.startsWith('barback-')) continue;
    versions[new Version.parse(split1(basename, '-').last)] = dir;
  }

  return versions;
}

/// Runs the tests in [callback] against all versions of barback in the repo
/// that match [versionConstraint].
///
/// This is used to test that pub doesn't accidentally break older versions of
/// barback that it's committed to supporting. Only versions `0.13.0` and later
/// will be tested.
void withBarbackVersions(String versionConstraint, void callback()) {
  var constraint = new VersionConstraint.parse(versionConstraint);

  var validVersions = _barbackVersions.keys.where(constraint.allows);
  if (validVersions.isEmpty) {
    throw new ArgumentError(
        'No available barback version matches "$versionConstraint".');
  }

  for (var version in validVersions) {
    group("with barback $version", () {
      setUp(() {
        _packageOverrides = {};
        _packageOverrides['barback'] = _barbackVersions[version];
        _barbackDeps.forEach((constraint, deps) {
          if (!constraint.allows(version)) return;
          deps.forEach((packageName, version) {
            _packageOverrides[packageName] = p.join(
                repoRoot, 'third_party', 'pkg', '$packageName-$version');
          });
        });

        currentSchedule.onComplete.schedule(() {
          _packageOverrides = null;
        });
      });

      callback();
    });
  }
}

/// The completer for [port].
Completer<int> get _portCompleter {
  if (_portCompleterCache != null) return _portCompleterCache;
  _portCompleterCache = new Completer<int>();
  currentSchedule.onComplete.schedule(() {
    _portCompleterCache = null;
  }, 'clearing the port completer');
  return _portCompleterCache;
}

/// A future that will complete to the port used for the current server.
Future<int> get port => _portCompleter.future;

/// Gets the list of paths that have been requested from the server since the
/// last time this was called (or since the server was first spun up).
Future<List<String>> getRequestedPaths() {
  return schedule(() {
    var paths = _requestedPaths.toList();
    _requestedPaths.clear();
    return paths;
  }, "get previous network requests");
}

/// Creates an HTTP server to serve [contents] as static files.
///
/// This server will exist only for the duration of the pub run. Subsequent
/// calls to [serve] replace the previous server.
void serve([List<d.Descriptor> contents]) {
  var baseDir = d.dir("serve-dir", contents);

  _hasServer = true;

  schedule(() {
    return _closeServer().then((_) {
      return shelf_io.serve((request) {
        currentSchedule.heartbeat();
        var path = p.posix.fromUri(request.url.path.replaceFirst("/", ""));
        _requestedPaths.add(path);

        return validateStream(baseDir.load(path))
            .then((stream) => new shelf.Response.ok(stream))
            .catchError((error) {
          return new shelf.Response.notFound('File "$path" not found.');
        });
      }, 'localhost', 0).then((server) {
        _server = server;
        _portCompleter.complete(_server.port);
        currentSchedule.onComplete.schedule(_closeServer);
      });
    });
  }, 'starting a server serving:\n${baseDir.describe()}');
}

/// Closes [_server].
///
/// Returns a [Future] that completes after the [_server] is closed.
Future _closeServer() {
  if (_server == null) return new Future.value();
  var future = _server.close();
  _server = null;
  _hasServer = false;
  _portCompleterCache = null;
  return future;
}

/// `true` if the current test spins up an HTTP server.
bool _hasServer = false;

/// Converts [value] into a YAML string.
String yaml(value) => JSON.encode(value);

/// The full path to the created sandbox directory for an integration test.
String get sandboxDir => _sandboxDir;
String _sandboxDir;

/// The path of the package cache directory used for tests, relative to the
/// sandbox directory.
final String cachePath = "cache";

/// The path of the mock app directory used for tests, relative to the sandbox
/// directory.
final String appPath = "myapp";

/// The path of the packages directory in the mock app used for tests, relative
/// to the sandbox directory.
final String packagesPath = "$appPath/packages";

/// Set to true when the current batch of scheduled events should be aborted.
bool _abortScheduled = false;

/// Enum identifying a pub command that can be run with a well-defined success
/// output.
class RunCommand {
  static final get = new RunCommand('get', new RegExp(
      r'Got dependencies!|Changed \d+ dependenc(y|ies)!'));
  static final upgrade = new RunCommand('upgrade', new RegExp(
      r'(No dependencies changed\.|Changed \d+ dependenc(y|ies)!)$'));
  static final downgrade = new RunCommand('downgrade', new RegExp(
      r'(No dependencies changed\.|Changed \d+ dependenc(y|ies)!)$'));

  final String name;
  final RegExp success;
  RunCommand(this.name, this.success);
}

/// Runs the tests defined within [callback] using both pub get and pub upgrade.
///
/// Many tests validate behavior that is the same between pub get and
/// upgrade have the same behavior. Instead of duplicating those tests, this
/// takes a callback that defines get/upgrade agnostic tests and runs them
/// with both commands.
void forBothPubGetAndUpgrade(void callback(RunCommand command)) {
  group(RunCommand.get.name, () => callback(RunCommand.get));
  group(RunCommand.upgrade.name, () => callback(RunCommand.upgrade));
}

/// Schedules an invocation of pub [command] and validates that it completes
/// in an expected way.
///
/// By default, this validates that the command completes successfully and
/// understands the normal output of a successful pub command. If [warning] is
/// given, it expects the command to complete successfully *and* print
/// [warning] to stderr. If [error] is given, it expects the command to *only*
/// print [error] to stderr. [output], [error], and [warning] may be strings,
/// [RegExp]s, or [Matcher]s.
///
/// If [exitCode] is given, expects the command to exit with that code.
// TODO(rnystrom): Clean up other tests to call this when possible.
void pubCommand(RunCommand command,
    {Iterable<String> args, output, error, warning, int exitCode}) {
  if (error != null && warning != null) {
    throw new ArgumentError("Cannot pass both 'error' and 'warning'.");
  }

  var allArgs = [command.name];
  if (args != null) allArgs.addAll(args);

  if (output == null) output = command.success;

  if (error != null && exitCode == null) exitCode = 1;

  // No success output on an error.
  if (error != null) output = null;
  if (warning != null) error = warning;

  schedulePub(args: allArgs, output: output, error: error, exitCode: exitCode);
}

void pubGet({Iterable<String> args, output, error, warning, int exitCode}) {
  pubCommand(RunCommand.get, args: args, output: output, error: error,
      warning: warning, exitCode: exitCode);
}

void pubUpgrade({Iterable<String> args, output, error, warning, int exitCode}) {
  pubCommand(RunCommand.upgrade, args: args, output: output, error: error,
      warning: warning, exitCode: exitCode);
}

void pubDowngrade({Iterable<String> args, output, error, warning,
    int exitCode}) {
  pubCommand(RunCommand.downgrade, args: args, output: output, error: error,
      warning: warning, exitCode: exitCode);
}

/// Schedules starting the "pub [global] run" process and validates the
/// expected startup output.
///
/// If [global] is `true`, this invokes "pub global run", otherwise it does
/// "pub run".
///
/// Returns the `pub run` process.
ScheduledProcess pubRun({bool global: false, Iterable<String> args}) {
  var pubArgs = global ? ["global", "run"] : ["run"];
  pubArgs.addAll(args);
  var pub = startPub(args: pubArgs);

  // Loading sources and transformers isn't normally printed, but the pub test
  // infrastructure runs pub in verbose mode, which enables this.
  pub.stdout.expect(consumeWhile(startsWith("Loading")));

  return pub;
}

/// Defines an integration test.
///
/// The [body] should schedule a series of operations which will be run
/// asynchronously.
void integration(String description, void body()) =>
  _integration(description, body, test);

/// Like [integration], but causes only this test to run.
void solo_integration(String description, void body()) =>
  _integration(description, body, solo_test);

void _integration(String description, void body(), [Function testFn]) {
  testFn(description, () {
    // TODO(nweiz): remove this when issue 15362 is fixed.
    currentSchedule.timeout *= 2;

    // The windows bots are very slow, so we increase the default timeout.
    if (Platform.operatingSystem == "windows") {
      currentSchedule.timeout *= 2;
    }

    _sandboxDir = createSystemTempDir();
    d.defaultRoot = sandboxDir;
    currentSchedule.onComplete.schedule(() => deleteEntry(_sandboxDir),
        'deleting the sandbox directory');

    // Schedule the test.
    body();
  });
}

/// Get the path to the root "pub/test" directory containing the pub
/// tests.
String get testDirectory =>
  p.absolute(p.dirname(libraryPath('test_pub')));

/// Schedules renaming (moving) the directory at [from] to [to], both of which
/// are assumed to be relative to [sandboxDir].
void scheduleRename(String from, String to) {
  schedule(
      () => renameDir(
          p.join(sandboxDir, from),
          p.join(sandboxDir, to)),
      'renaming $from to $to');
}

/// Schedules creating a symlink at path [symlink] that points to [target],
/// both of which are assumed to be relative to [sandboxDir].
void scheduleSymlink(String target, String symlink) {
  schedule(
      () => createSymlink(
          p.join(sandboxDir, target),
          p.join(sandboxDir, symlink)),
      'symlinking $target to $symlink');
}

/// Schedules a call to the Pub command-line utility.
///
/// Runs Pub with [args] and validates that its results match [output] (or
/// [outputJson]), [error], and [exitCode].
///
/// [output] and [error] can be [String]s, [RegExp]s, or [Matcher]s.
///
/// If [outputJson] is given, validates that pub outputs stringified JSON
/// matching that object, which can be a literal JSON object or any other
/// [Matcher].
///
/// If [environment] is given, any keys in it will override the environment
/// variables passed to the spawned process.
void schedulePub({List args, output, error, outputJson,
    int exitCode: exit_codes.SUCCESS, Map<String, String> environment}) {
  // Cannot pass both output and outputJson.
  assert(output == null || outputJson == null);

  var pub = startPub(args: args, environment: environment);
  pub.shouldExit(exitCode);

  var failures = [];
  var stderr;

  expect(Future.wait([
    pub.stdoutStream().toList(),
    pub.stderrStream().toList()
  ]).then((results) {
    var stdout = results[0].join("\n");
    stderr = results[1].join("\n");

    if (outputJson == null) {
      _validateOutput(failures, 'stdout', output, stdout);
      return null;
    }

    // Allow the expected JSON to contain futures.
    return awaitObject(outputJson).then((resolved) {
      _validateOutputJson(failures, 'stdout', resolved, stdout);
    });
  }).then((_) {
    _validateOutput(failures, 'stderr', error, stderr);

    if (!failures.isEmpty) throw new TestFailure(failures.join('\n'));
  }), completes);
}

/// Like [startPub], but runs `pub lish` in particular with [server] used both
/// as the OAuth2 server (with "/token" as the token endpoint) and as the
/// package server.
///
/// Any futures in [args] will be resolved before the process is started.
ScheduledProcess startPublish(ScheduledServer server, {List args}) {
  var tokenEndpoint = server.url.then((url) =>
      url.resolve('/token').toString());
  if (args == null) args = [];
  args = flatten(['lish', '--server', tokenEndpoint, args]);
  return startPub(args: args, tokenEndpoint: tokenEndpoint);
}

/// Handles the beginning confirmation process for uploading a packages.
///
/// Ensures that the right output is shown and then enters "y" to confirm the
/// upload.
void confirmPublish(ScheduledProcess pub) {
  // TODO(rnystrom): This is overly specific and inflexible regarding different
  // test packages. Should validate this a little more loosely.
  pub.stdout.expect(startsWith('Publishing test_pkg 1.0.0 to '));
  pub.stdout.expect(emitsLines(
      "|-- LICENSE\n"
      "|-- lib\n"
      "|   '-- test_pkg.dart\n"
      "'-- pubspec.yaml\n"
      "\n"
      "Looks great! Are you ready to upload your package (y/n)?"));
  pub.writeLine("y");
}

/// Gets the absolute path to [relPath], which is a relative path in the test
/// sandbox.
String _pathInSandbox(String relPath) {
  return p.join(p.absolute(sandboxDir), relPath);
}

/// Gets the environment variables used to run pub in a test context.
Future<Map> getPubTestEnvironment([String tokenEndpoint]) async {
  var environment = {};
  environment['_PUB_TESTING'] = 'true';
  environment['PUB_CACHE'] = _pathInSandbox(cachePath);

  // Ensure a known SDK version is set for the tests that rely on that.
  environment['_PUB_TEST_SDK_VERSION'] = "0.1.2+3";

  if (tokenEndpoint != null) {
    environment['_PUB_TEST_TOKEN_ENDPOINT'] = tokenEndpoint.toString();
  }

  if (_hasServer) {
    return port.then((p) {
      environment['PUB_HOSTED_URL'] = "http://localhost:$p";
      return environment;
    });
  }

  return environment;
}

/// Starts a Pub process and returns a [ScheduledProcess] that supports
/// interaction with that process.
///
/// Any futures in [args] will be resolved before the process is started.
///
/// If [environment] is given, any keys in it will override the environment
/// variables passed to the spawned process.
ScheduledProcess startPub({List args, Future<String> tokenEndpoint,
    Map<String, String> environment}) {
  ensureDir(_pathInSandbox(appPath));

  // Find a Dart executable we can use to spawn. Use the same one that was
  // used to run this script itself.
  var dartBin = Platform.executable;

  // If the executable looks like a path, get its full path. That way we
  // can still find it when we spawn it with a different working directory.
  if (dartBin.contains(Platform.pathSeparator)) {
    dartBin = p.absolute(dartBin);
  }

  // Always run pub from a snapshot. Since we require the SDK to be built, the
  // snapshot should be there. Note that this *does* mean that the snapshot has
  // to be manually updated when changing code before running the tests.
  // Otherwise, you will test against stale data.
  //
  // Using the snapshot makes running the tests much faster, which is why we
  // make this trade-off.
  var pubPath = p.join(p.dirname(dartBin), 'snapshots/pub.dart.snapshot');
  var dartArgs = [pubPath, '--verbose'];
  dartArgs.addAll(args);

  if (tokenEndpoint == null) tokenEndpoint = new Future.value();
  var environmentFuture = tokenEndpoint
      .then((tokenEndpoint) => getPubTestEnvironment(tokenEndpoint))
      .then((pubEnvironment) {
    if (environment != null) pubEnvironment.addAll(environment);
    return pubEnvironment;
  });

  return new PubProcess.start(dartBin, dartArgs, environment: environmentFuture,
      workingDirectory: _pathInSandbox(appPath),
      description: args.isEmpty ? 'pub' : 'pub ${args.first}');
}

/// A subclass of [ScheduledProcess] that parses pub's verbose logging output
/// and makes [stdout] and [stderr] work as though pub weren't running in
/// verbose mode.
class PubProcess extends ScheduledProcess {
  Stream<Pair<log.Level, String>> _log;
  Stream<String> _stdout;
  Stream<String> _stderr;

  PubProcess.start(executable, arguments,
      {workingDirectory, environment, String description,
       Encoding encoding: UTF8})
    : super.start(executable, arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        description: description,
        encoding: encoding);

  Stream<Pair<log.Level, String>> _logStream() {
    if (_log == null) {
      _log = mergeStreams(
        _outputToLog(super.stdoutStream(), log.Level.MESSAGE),
        _outputToLog(super.stderrStream(), log.Level.ERROR));
    }

    var pair = tee(_log);
    _log = pair.first;
    return pair.last;
  }

  final _logLineRegExp = new RegExp(r"^([A-Z ]{4})[:|] (.*)$");
  final _logLevels = [
    log.Level.ERROR, log.Level.WARNING, log.Level.MESSAGE, log.Level.IO,
    log.Level.SOLVER, log.Level.FINE
  ].fold(<String, log.Level>{}, (levels, level) {
    levels[level.name] = level;
    return levels;
  });

  Stream<Pair<log.Level, String>> _outputToLog(Stream<String> stream,
      log.Level defaultLevel) {
    var lastLevel;
    return stream.map((line) {
      var match = _logLineRegExp.firstMatch(line);
      if (match == null) return new Pair<log.Level, String>(defaultLevel, line);

      var level = _logLevels[match[1]];
      if (level == null) level = lastLevel;
      lastLevel = level;
      return new Pair<log.Level, String>(level, match[2]);
    });
  }

  Stream<String> stdoutStream() {
    if (_stdout == null) {
      _stdout = _logStream().expand((entry) {
        if (entry.first != log.Level.MESSAGE) return [];
        return [entry.last];
      });
    }

    var pair = tee(_stdout);
    _stdout = pair.first;
    return pair.last;
  }

  Stream<String> stderrStream() {
    if (_stderr == null) {
      _stderr = _logStream().expand((entry) {
        if (entry.first != log.Level.ERROR &&
            entry.first != log.Level.WARNING) {
          return [];
        }
        return [entry.last];
      });
    }

    var pair = tee(_stderr);
    _stderr = pair.first;
    return pair.last;
  }
}

/// The path to the `packages` directory from which pub loads its dependencies.
String get _packageRoot => p.absolute(Platform.packageRoot);

/// Fails the current test if Git is not installed.
///
/// We require machines running these tests to have git installed. This
/// validation gives an easier-to-understand error when that requirement isn't
/// met than just failing in the middle of a test when pub invokes git.
///
/// This also increases the [Schedule] timeout to 30 seconds on Windows,
/// where Git runs really slowly.
void ensureGit() {
  if (Platform.operatingSystem == "windows") {
    currentSchedule.timeout = new Duration(seconds: 30);
  }

  if (!gitlib.isInstalled) {
    throw new Exception("Git must be installed to run this test.");
  }
}

/// Schedules activating a global package [package] without running
/// "pub global activate".
///
/// This is useful because global packages must be hosted, but the test hosted
/// server doesn't serve barback. The other parameters here follow
/// [createLockFile].
void makeGlobalPackage(String package, String version,
    Iterable<d.Descriptor> contents, {Iterable<String> pkg,
    Map<String, String> hosted}) {
  // Start the server so we know what port to use in the cache directory name.
  serveNoPackages();

  // Create the package in the hosted cache.
  d.hostedCache([
    d.dir("$package-$version", contents)
  ]).create();

  var lockFile = _createLockFile(pkg: pkg, hosted: hosted);

  // Add the root package to the lockfile.
  var id = new PackageId(package, "hosted", new Version.parse(version),
      package);
  lockFile.packages[package] = id;

  // Write the lockfile to the global cache.
  var sources = new SourceRegistry();
  sources.register(new HostedSource());
  sources.register(new PathSource());

  d.dir(cachePath, [
    d.dir("global_packages", [
      d.file("$package.lock", lockFile.serialize(null, sources))
    ])
  ]).create();
}

/// Creates a lock file for [package] without running `pub get`.
///
/// [sandbox] is a list of path dependencies to be found in the sandbox
/// directory. [pkg] is a list of packages in the Dart repo's "pkg" directory;
/// each package listed here and all its dependencies will be linked to the
/// version in the Dart repo.
///
/// [hosted] is a list of package names to version strings for dependencies on
/// hosted packages.
void createLockFile(String package, {Iterable<String> sandbox,
    Iterable<String> pkg, Map<String, String> hosted}) {
  var lockFile = _createLockFile(sandbox: sandbox, pkg: pkg, hosted: hosted);

  var sources = new SourceRegistry();
  sources.register(new HostedSource());
  sources.register(new PathSource());

  d.file(p.join(package, 'pubspec.lock'),
      lockFile.serialize(null, sources)).create();
}

/// Creates a lock file for [package] without running `pub get`.
///
/// [sandbox] is a list of path dependencies to be found in the sandbox
/// directory. [pkg] is a list of packages in the Dart repo's "pkg" directory;
/// each package listed here and all its dependencies will be linked to the
/// version in the Dart repo.
///
/// [hosted] is a list of package names to version strings for dependencies on
/// hosted packages.
LockFile _createLockFile({Iterable<String> sandbox,
Iterable<String> pkg, Map<String, String> hosted}) {
  var dependencies = {};

  if (sandbox != null) {
    for (var package in sandbox) {
      dependencies[package] = '../$package';
    }
  }

  if (pkg != null) {
    _addPackage(String package) {
      if (dependencies.containsKey(package)) return;

      var path;
      if (package == 'barback' && _packageOverrides == null) {
        throw new StateError("createLockFile() can only create a lock file "
            "with a barback dependency within a withBarbackVersions() "
            "block.");
      }

      if (_packageOverrides.containsKey(package)) {
        path = _packageOverrides[package];
      } else {
        path = packagePath(package);
      }

      dependencies[package] = path;
      var pubspec = loadYaml(
          readTextFile(p.join(path, 'pubspec.yaml')));
      var packageDeps = pubspec['dependencies'];
      if (packageDeps == null) return;
      packageDeps.keys.forEach(_addPackage);
    }

    pkg.forEach(_addPackage);
  }

  var lockFile = new LockFile.empty();
  dependencies.forEach((name, dependencyPath) {
    var id = new PackageId(name, 'path', new Version(0, 0, 0), {
      'path': dependencyPath,
      'relative': p.isRelative(dependencyPath)
    });
    lockFile.packages[name] = id;
  });

  if (hosted != null) {
    hosted.forEach((name, version) {
      var id = new PackageId(name, 'hosted', new Version.parse(version), name);
      lockFile.packages[name] = id;
    });
  }

  return lockFile;
}

/// Returns the path to [package] within the repo.
String packagePath(String package) =>
    dirExists(p.join(repoRoot, 'pkg', package)) ?
        p.join(repoRoot, 'pkg', package) :
        p.join(repoRoot, 'third_party', 'pkg', package);

/// Uses [client] as the mock HTTP client for this test.
///
/// Note that this will only affect HTTP requests made via http.dart in the
/// parent process.
void useMockClient(MockClient client) {
  var oldInnerClient = innerHttpClient;
  innerHttpClient = client;
  currentSchedule.onComplete.schedule(() {
    innerHttpClient = oldInnerClient;
  }, 'de-activating the mock client');
}

/// Describes a map representing a library package with the given [name],
/// [version], and [dependencies].
Map packageMap(String name, String version, [Map dependencies]) {
  var package = {
    "name": name,
    "version": version,
    "author": "Natalie Weizenbaum <nweiz@google.com>",
    "homepage": "http://pub.dartlang.org",
    "description": "A package, I guess."
  };

  if (dependencies != null) package["dependencies"] = dependencies;

  return package;
}

/// Resolves [target] relative to the path to pub's `test/asset` directory.
String testAssetPath(String target) {
  var libPath = libraryPath('test_pub');

  // We are running from the generated directory, but non-dart assets are only
  // in the canonical directory.
  // TODO(rnystrom): Remove this when #104 is fixed.
  libPath = libPath.replaceAll('pub_generated', 'pub');

  return p.join(p.dirname(libPath), 'asset', target);
}

/// Returns a Map in the format used by the pub.dartlang.org API to represent a
/// package version.
///
/// [pubspec] is the parsed pubspec of the package version. If [full] is true,
/// this returns the complete map, including metadata that's only included when
/// requesting the package version directly.
Map packageVersionApiMap(Map pubspec, {bool full: false}) {
  var name = pubspec['name'];
  var version = pubspec['version'];
  var map = {
    'pubspec': pubspec,
    'version': version,
    'url': '/api/packages/$name/versions/$version',
    'archive_url': '/packages/$name/versions/$version.tar.gz',
    'new_dartdoc_url': '/api/packages/$name/versions/$version'
        '/new_dartdoc',
    'package_url': '/api/packages/$name'
  };

  if (full) {
    map.addAll({
      'downloads': 0,
      'created': '2012-09-25T18:38:28.685260',
      'libraries': ['$name.dart'],
      'uploader': ['nweiz@google.com']
    });
  }

  return map;
}

/// Returns the name of the shell script for a binstub named [name].
///
/// Adds a ".bat" extension on Windows.
String binStubName(String name) => Platform.isWindows ? '$name.bat' : name;

/// Compares the [actual] output from running pub with [expected].
///
/// If [expected] is a [String], ignores leading and trailing whitespace
/// differences and tries to report the offending difference in a nice way.
///
/// If it's a [RegExp] or [Matcher], just reports whether the output matches.
void _validateOutput(List<String> failures, String pipe, expected,
                     String actual) {
  if (expected == null) return;

  if (expected is String) {
    _validateOutputString(failures, pipe, expected, actual);
  } else {
    if (expected is RegExp) expected = matches(expected);
    expect(actual, expected);
  }
}

void _validateOutputString(List<String> failures, String pipe,
                           String expected, String actual) {
  var actualLines = actual.split("\n");
  var expectedLines = expected.split("\n");

  // Strip off the last line. This lets us have expected multiline strings
  // where the closing ''' is on its own line. It also fixes '' expected output
  // to expect zero lines of output, not a single empty line.
  if (expectedLines.last.trim() == '') {
    expectedLines.removeLast();
  }

  var results = [];
  var failed = false;

  // Compare them line by line to see which ones match.
  var length = max(expectedLines.length, actualLines.length);
  for (var i = 0; i < length; i++) {
    if (i >= actualLines.length) {
      // Missing output.
      failed = true;
      results.add('? ${expectedLines[i]}');
    } else if (i >= expectedLines.length) {
      // Unexpected extra output.
      failed = true;
      results.add('X ${actualLines[i]}');
    } else {
      var expectedLine = expectedLines[i].trim();
      var actualLine = actualLines[i].trim();

      if (expectedLine != actualLine) {
        // Mismatched lines.
        failed = true;
        results.add('X ${actualLines[i]}');
      } else {
        // Output is OK, but include it in case other lines are wrong.
        results.add('| ${actualLines[i]}');
      }
    }
  }

  // If any lines mismatched, show the expected and actual.
  if (failed) {
    failures.add('Expected $pipe:');
    failures.addAll(expectedLines.map((line) => '| $line'));
    failures.add('Got:');
    failures.addAll(results);
  }
}

/// Validates that [actualText] is a string of JSON that matches [expected],
/// which may be a literal JSON object, or any other [Matcher].
void _validateOutputJson(List<String> failures, String pipe,
                         expected, String actualText) {
  var actual;
  try {
    actual = JSON.decode(actualText);
  } on FormatException catch(error) {
    failures.add('Expected $pipe JSON:');
    failures.add(expected);
    failures.add('Got invalid JSON:');
    failures.add(actualText);
  }

  // Match against the expectation.
  expect(actual, expected);
}

/// A function that creates a [Validator] subclass.
typedef Validator ValidatorCreator(Entrypoint entrypoint);

/// Schedules a single [Validator] to run on the [appPath].
///
/// Returns a scheduled Future that contains the errors and warnings produced
/// by that validator.
Future<Pair<List<String>, List<String>>> schedulePackageValidation(
    ValidatorCreator fn) {
  return schedule(() {
    var cache = new SystemCache.withSources(
        rootDir: p.join(sandboxDir, cachePath));

    return new Future.sync(() {
      var validator = fn(new Entrypoint(p.join(sandboxDir, appPath), cache));
      return validator.validate().then((_) {
        return new Pair(validator.errors, validator.warnings);
      });
    });
  }, "validating package");
}

/// A matcher that matches a Pair.
Matcher pairOf(Matcher firstMatcher, Matcher lastMatcher) =>
   new _PairMatcher(firstMatcher, lastMatcher);

class _PairMatcher extends Matcher {
  final Matcher _firstMatcher;
  final Matcher _lastMatcher;

  _PairMatcher(this._firstMatcher, this._lastMatcher);

  bool matches(item, Map matchState) {
    if (item is! Pair) return false;
    return _firstMatcher.matches(item.first, matchState) &&
        _lastMatcher.matches(item.last, matchState);
  }

  Description describe(Description description) {
    return description.addAll("(", ", ", ")", [_firstMatcher, _lastMatcher]);
  }
}

/// A [StreamMatcher] that matches multiple lines of output.
StreamMatcher emitsLines(String output) => inOrder(output.split("\n"));
