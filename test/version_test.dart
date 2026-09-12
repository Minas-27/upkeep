import 'dart:io';

import 'package:test/test.dart';
import 'package:upkeep/upkeep.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('upkeepVersion matches pubspec.yaml', () {
    final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    expect(upkeepVersion, pubspec['version']);
  });
}
