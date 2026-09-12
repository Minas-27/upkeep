import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// An on-disk cache of pub.dev responses.
///
/// A second `upkeep scan` inside the TTL does no network work at all, which
/// matters because this tool is meant to run in CI and on slow connections.
class ResponseCache {
  ResponseCache({Directory? directory, this.ttl = const Duration(hours: 24)})
      : _dir =
            directory ?? Directory(p.join(_home ?? Directory.systemTemp.path, '.upkeep', 'cache'));

  final Directory _dir;
  final Duration ttl;

  static String? get _home => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  File _fileFor(String key) => File(p.join(_dir.path, '${_safe(key)}.json'));

  static String _safe(String key) => key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// The cached value for [key], or null when absent, expired or corrupt.
  Map<String, dynamic>? read(String key) {
    final file = _fileFor(key);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return null;
      final at = DateTime.tryParse(decoded['_cachedAt'] as String? ?? '');
      if (at == null || DateTime.now().difference(at) > ttl) return null;
      final body = decoded['body'];
      return body is Map<String, dynamic> ? body : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Stores [body] under [key]. Cache failures are never fatal.
  void write(String key, Map<String, dynamic> body) {
    try {
      _dir.createSync(recursive: true);
      _fileFor(key).writeAsStringSync(jsonEncode({
        '_cachedAt': DateTime.now().toIso8601String(),
        'body': body,
      }));
    } on FileSystemException {
      // A machine with no writable home still deserves a working scan.
    }
  }

  /// Deletes everything cached.
  void clear() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  }
}
