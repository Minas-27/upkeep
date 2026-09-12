import 'package:http_server/http_server.dart';
import 'package:path/path.dart' as p;

/// Exists so the fixture imports a discontinued package that upkeep must not
/// remove on its own.
Object describe() => (VirtualDirectory, p.separator);
