// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library services.common_server_impl;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:pedantic/pedantic.dart';

import '../version.dart';
import 'analysis_servers.dart';
import 'common.dart';
import 'compiler.dart';
import 'protos/dart_services.pb.dart' as proto;
import 'sdk_manager.dart';
import 'server_cache.dart';

const Duration _standardExpiration = Duration(hours: 1);
final Logger log = Logger('common_server');

class BadRequest implements Exception {
  String cause;

  BadRequest(this.cause);
}

abstract class ServerContainer {
  String get version;
}

class CommonServerImpl {
  final ServerContainer container;
  final ServerCache cache;

  Compiler compiler;
  AnalysisServersWrapper analysisServers;

  // Restarting and health status of the two Analysis Servers
  bool get analysisServersRunning => analysisServers.running;
  bool get isRestarting => analysisServers.isRestarting;
  bool get isHealthy => analysisServers.isHealthy;

  CommonServerImpl(
    this.container,
    this.cache,
  ) {
    hierarchicalLoggingEnabled = true;
    log.level = Level.ALL;
  }

  Future<void> init() async {
    log.info('Beginning CommonServer init().');
    analysisServers = AnalysisServersWrapper();
    compiler = Compiler(SdkManager.sdk, SdkManager.flutterSdk);

    await compiler.warmup();
    await analysisServers.warmup();
  }

  Future<dynamic> shutdown() {
    return Future.wait(<Future<dynamic>>[
      analysisServers.shutdown(),
      compiler.dispose(),
      Future<dynamic>.sync(cache.shutdown)
    ]).timeout(const Duration(minutes: 1));
  }

  Future<proto.AnalysisResults> analyze(proto.SourceRequest request) {
    if (!request.hasSource()) {
      throw BadRequest('Missing parameter: \'source\'');
    }

    return analysisServers.analyze(request.source);
  }

  Future<proto.CompileResponse> compile(proto.CompileRequest request) {
    if (!request.hasSource()) {
      throw BadRequest('Missing parameter: \'source\'');
    }

    return _compileDart2js(request.source,
        returnSourceMap: request.returnSourceMap ?? false);
  }

  Future<proto.CompileDDCResponse> compileDDC(proto.CompileDDCRequest request) {
    if (!request.hasSource()) {
      throw BadRequest('Missing parameter: \'source\'');
    }

    return _compileDDC(request.source);
  }

  Future<proto.CompleteResponse> complete(proto.SourceRequest request) {
    if (!request.hasSource()) {
      throw BadRequest('Missing parameter: \'source\'');
    }
    if (!request.hasOffset()) {
      throw BadRequest('Missing parameter: \'offset\'');
    }

    return analysisServers.complete(request.source, request.offset);
  }

  Future<proto.FixesResponse> fixes(proto.SourceRequest request) {
    if (!request.hasSource()) {
      throw BadRequest('Missing parameter: \'source\'');
    }
    if (!request.hasOffset()) {
      throw BadRequest('Missing parameter: \'offset\'');
    }

    return analysisServers.getFixes(request.source, request.offset);
  }

  Future<proto.AssistsResponse> assists(proto.SourceRequest request) {
    if (!request.hasSource()) {
      throw BadRequest('Missing parameter: \'source\'');
    }
    if (!request.hasOffset()) {
      throw BadRequest('Missing parameter: \'offset\'');
    }

    return analysisServers.getAssists(request.source, request.offset);
  }

  Future<proto.FormatResponse> format(proto.SourceRequest request) {
    if (!request.hasSource()) {
      throw BadRequest('Missing parameter: \'source\'');
    }

    return analysisServers.format(request.source, request.offset ?? 0);
  }

  Future<proto.DocumentResponse> document(proto.SourceRequest request) async {
    if (!request.hasSource()) {
      throw BadRequest('Missing parameter: \'source\'');
    }
    if (!request.hasOffset()) {
      throw BadRequest('Missing parameter: \'offset\'');
    }

    return proto.DocumentResponse()
      ..info.addAll(
          await analysisServers.dartdoc(request.source, request.offset) ??
              <String, String>{});
  }

  Future<proto.VersionResponse> version(proto.VersionRequest _) =>
      Future<proto.VersionResponse>.value(
        proto.VersionResponse()
          ..sdkVersion = SdkManager.sdk.version
          ..sdkVersionFull = SdkManager.sdk.versionFull
          ..runtimeVersion = vmVersion
          ..servicesVersion = servicesVersion
          ..appEngineVersion = container.version
          ..flutterDartVersion = SdkManager.flutterSdk.version
          ..flutterDartVersionFull = SdkManager.flutterSdk.versionFull
          ..flutterVersion = SdkManager.flutterSdk.flutterVersion,
      );

  Future<proto.CompileResponse> _compileDart2js(
    String source, {
    bool returnSourceMap = false,
  }) async {
    try {
      final sourceHash = _hashSource(source);
      final memCacheKey = '%%COMPILE:v0'
          ':returnSourceMap:$returnSourceMap:source:$sourceHash';

      final result = await _checkCache(memCacheKey);
      if (result != null) {
        log.info('CACHE: Cache hit for compileDart2js');
        final resultObj = const JsonDecoder().convert(result);
        final response = proto.CompileResponse()
          ..result = resultObj['compiledJS'] as String;
        if (resultObj['sourceMap'] != null) {
          response.sourceMap = resultObj['sourceMap'] as String;
        }
        return response;
      }

      log.info('CACHE: MISS for compileDart2js');
      final watch = Stopwatch()..start();

      final results =
          await compiler.compile(source, returnSourceMap: returnSourceMap);

      if (results.hasOutput) {
        final lineCount = source.split('\n').length;
        final outputSize = (results.compiledJS.length / 1024).ceil();
        final ms = watch.elapsedMilliseconds;
        log.info('PERF: Compiled $lineCount lines of Dart into '
            '${outputSize}kb of JavaScript in ${ms}ms using dart2js.');
        final sourceMap = returnSourceMap ? results.sourceMap : null;

        final cachedResult = const JsonEncoder().convert(<String, String>{
          'compiledJS': results.compiledJS,
          'sourceMap': sourceMap,
        });
        // Don't block on cache set.
        unawaited(_setCache(memCacheKey, cachedResult));
        final compileResponse = proto.CompileResponse();
        compileResponse.result = results.compiledJS;
        if (sourceMap != null) {
          compileResponse.sourceMap = sourceMap;
        }
        return compileResponse;
      } else {
        final problems = results.problems;
        final errors = problems.map(_printCompileProblem).join('\n');
        throw BadRequest(errors);
      }
    } catch (e, st) {
      if (e is! BadRequest) {
        log.severe('Error during compile (dart2js) on "$source"', e, st);
      }
      rethrow;
    }
  }

  Future<proto.CompileDDCResponse> _compileDDC(String source) async {
    try {
      final sourceHash = _hashSource(source);
      final memCacheKey = '%%COMPILE_DDC:v0:source:$sourceHash';

      final result = await _checkCache(memCacheKey);
      if (result != null) {
        log.info('CACHE: Cache hit for compileDDC');
        final resultObj = const JsonDecoder().convert(result);
        return proto.CompileDDCResponse()
          ..result = resultObj['compiledJS'] as String
          ..modulesBaseUrl = resultObj['modulesBaseUrl'] as String;
      }

      log.info('CACHE: MISS for compileDDC');
      final watch = Stopwatch()..start();

      final results = await compiler.compileDDC(source);

      if (results.hasOutput) {
        final lineCount = source.split('\n').length;
        final outputSize = (results.compiledJS.length / 1024).ceil();
        final ms = watch.elapsedMilliseconds;
        log.info('PERF: Compiled $lineCount lines of Dart into '
            '${outputSize}kb of JavaScript in ${ms}ms using DDC.');

        final cachedResult = const JsonEncoder().convert(<String, String>{
          'compiledJS': results.compiledJS,
          'modulesBaseUrl': results.modulesBaseUrl,
        });
        // Don't block on cache set.
        unawaited(_setCache(memCacheKey, cachedResult));
        return proto.CompileDDCResponse()
          ..result = results.compiledJS
          ..modulesBaseUrl = results.modulesBaseUrl;
      } else {
        final problems = results.problems;
        final errors = problems.map(_printCompileProblem).join('\n');
        throw BadRequest(errors);
      }
    } catch (e, st) {
      if (e is! BadRequest) {
        log.severe('Error during compile (DDC) on "$source"', e, st);
      }
      rethrow;
    }
  }

  Future<String> _checkCache(String query) => cache.get(query);

  Future<void> _setCache(String query, String result) =>
      cache.set(query, result, expiration: _standardExpiration);
}

String _printCompileProblem(CompilationProblem problem) => problem.message;

String _hashSource(String str) {
  return sha1.convert(str.codeUnits).toString();
}
