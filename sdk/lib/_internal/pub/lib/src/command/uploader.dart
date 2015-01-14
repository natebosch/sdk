// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub.command.uploader;

import 'dart:async';

import 'package:path/path.dart' as path;

import '../command.dart';
import '../entrypoint.dart';
import '../exit_codes.dart' as exit_codes;
import '../http.dart';
import '../io.dart';
import '../log.dart' as log;
import '../oauth2.dart' as oauth2;
import '../source/hosted.dart';

/// Handles the `uploader` pub command.
class UploaderCommand extends PubCommand {
  String get name => "uploader";
  String get description =>
      "Manage uploaders for a package on pub.dartlang.org.";
  String get invocation => "pub uploader [options] {add/remove} <email>";
  String get docUrl => "http://dartlang.org/tools/pub/cmd/pub-uploader.html";

  /// The URL of the package hosting server.
  Uri get server => Uri.parse(argResults['server']);

  UploaderCommand() {
    argParser.addOption('server', defaultsTo: HostedSource.defaultUrl,
        help: 'The package server on which the package is hosted.');
    argParser.addOption('package',
        help: 'The package whose uploaders will be modified.\n'
              '(defaults to the current package)');
  }

  Future run() {
    if (argResults.rest.isEmpty) {
      log.error('No uploader command given.');
      this.printUsage();
      return flushThenExit(exit_codes.USAGE);
    }

    var rest = argResults.rest.toList();

    // TODO(rnystrom): Use subcommands for these.
    var command = rest.removeAt(0);
    if (!['add', 'remove'].contains(command)) {
      log.error('Unknown uploader command "$command".');
      this.printUsage();
      return flushThenExit(exit_codes.USAGE);
    } else if (rest.isEmpty) {
      log.error('No uploader given for "pub uploader $command".');
      this.printUsage();
      return flushThenExit(exit_codes.USAGE);
    }

    return new Future.sync(() {
      var package = argResults['package'];
      if (package != null) return package;
      return new Entrypoint(path.current, cache).root.name;
    }).then((package) {
      var uploader = rest[0];
      return oauth2.withClient(cache, (client) {
        if (command == 'add') {
          var url = server.resolve("/api/packages/"
              "${Uri.encodeComponent(package)}/uploaders");
          return client.post(url,
              headers: PUB_API_HEADERS,
              body: {"email": uploader});
        } else { // command == 'remove'
          var url = server.resolve("/api/packages/"
              "${Uri.encodeComponent(package)}/uploaders/"
              "${Uri.encodeComponent(uploader)}");
          return client.delete(url, headers: PUB_API_HEADERS);
        }
      });
    }).then(handleJsonSuccess)
      .catchError((error) => handleJsonError(error.response),
                  test: (e) => e is PubHttpException);
  }
}
