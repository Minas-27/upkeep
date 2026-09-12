import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:upkeep/src/pub/cache.dart';
import 'package:upkeep/upkeep.dart';

/// A pub.dev that answers from a table, so command output can be tested
/// without the network.
PubClient fakePub(Map<String, ({Map<String, Object?> meta, Map<String, Object?> score})> packages) {
  final client = MockClient((request) async {
    final segments = request.url.pathSegments; // api, packages, <name>[, score]
    final entry = packages[segments[2]];
    if (entry == null) return http.Response('{}', 404);
    final body = segments.length == 4 ? entry.score : entry.meta;
    return http.Response(jsonEncode(body), 200);
  });
  final dir = Directory.systemTemp.createTempSync('upkeep_cache_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return PubClient(httpClient: client, cache: ResponseCache(directory: dir));
}

({Map<String, Object?> meta, Map<String, Object?> score}) published({
  required String name,
  String version = '1.0.0',
  int monthsAgo = 1,
  bool discontinued = false,
  String? replacedBy,
  int points = 160,
  List<String> tags = const ['is:dart3-compatible'],
}) =>
    (
      meta: {
        'name': name,
        'isDiscontinued': discontinued,
        if (replacedBy != null) 'replacedBy': replacedBy,
        'latest': {
          'version': version,
          'published': DateTime.now()
              .toUtc()
              .subtract(Duration(days: (monthsAgo * 30.44).round()))
              .toIso8601String(),
          'pubspec': {
            'name': name,
            'environment': {'sdk': '>=3.0.0 <4.0.0'},
          },
        },
        'versions': [
          {'version': version}
        ],
      },
      score: {
        'grantedPoints': points,
        'maxPoints': 160,
        'likeCount': 1,
        'downloadCount30Days': 1000,
        'tags': tags,
      },
    );

String project(Map<String, String> files) {
  final root = Directory.systemTemp.createTempSync('upkeep_out_').path;
  addTearDown(() => Directory(root).deleteSync(recursive: true));
  files.forEach((path, content) {
    File(p.join(root, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  });
  return root;
}

void main() {
  final pub = {
    'old_thing': published(name: 'old_thing', discontinued: true, replacedBy: 'new_thing'),
    'fine': published(name: 'fine'),
  };
  const pubspec = 'name: demo\nenvironment:\n  sdk: ^3.0.0\ndependencies:\n  old_thing: ^1.0.0\n  fine: ^1.0.0\n';

  group('json', () {
    test('scan emits the versioned contract with reasons and exit code', () async {
      final root = project({'pubspec.yaml': pubspec, 'lib/a.dart': "import 'package:old_thing/x.dart';\n"});
      final out = StringBuffer();
      final code = await runScan(
        projectPath: root,
        format: OutputFormat.json,
        out: out,
        client: fakePub(pub),
      );

      final doc = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(code, ExitCodes.findings);
      expect(doc['schemaVersion'], jsonSchemaVersion);
      expect(doc['command'], 'scan');
      expect(doc['exitCode'], code);
      expect(doc['summary']['blocking'], 1);
      final old = (doc['dependencies'] as List).firstWhere((d) => d['name'] == 'old_thing');
      expect(old['verdict'], 'discontinued');
      expect(old['reasons'], isNotEmpty);
      expect(old['replacement'], {'package': 'new_thing', 'source': 'publisher', 'evidence': null});
    });

    test('a missing pubspec is still valid JSON, with exit code 2', () async {
      final root = project({});
      final out = StringBuffer();
      final code = await runScan(projectPath: root, format: OutputFormat.json, out: out, client: fakePub(pub));

      expect(code, ExitCodes.error);
      expect((jsonDecode(out.toString()) as Map)['error'], contains('No pubspec.yaml'));
    });

    test('fix lists to-dos with file and line references', () async {
      final root = project({'pubspec.yaml': pubspec, 'lib/a.dart': "import 'package:old_thing/x.dart';\n"});
      final out = StringBuffer();
      await runFix(projectPath: root, format: OutputFormat.json, out: out, client: fakePub(pub));

      final doc = jsonDecode(out.toString()) as Map<String, dynamic>;
      final todo = (doc['todos'] as List).single;
      expect(todo['title'], 'Replace old_thing with new_thing');
      expect(todo['references'], [
        {'file': 'lib/a.dart', 'line': 1}
      ]);
    });
  });

  group('markdown', () {
    test('scan renders a table with reasons', () async {
      final root = project({'pubspec.yaml': pubspec});
      final out = StringBuffer();
      await runScan(projectPath: root, format: OutputFormat.markdown, out: out, client: fakePub(pub));

      final md = out.toString();
      expect(md, contains('| `old_thing`'));
      expect(md, contains('**DISCONTINUED**'));
      expect(md, contains('marked discontinued by its publisher'));
      expect(md, isNot(contains('\x1B[')));
    });
  });

  group('explain', () {
    test('judges a package outside any project, and exits on its verdict', () async {
      final out = StringBuffer();
      final code = await runExplain(
        package: 'old_thing',
        projectPath: project({}),
        out: out,
        style: Style(enabled: false),
        client: fakePub(pub),
      );

      expect(code, ExitCodes.findings);
      expect(out.toString(), contains('DISCONTINUED'));
      expect(out.toString(), contains('judged as if it were added today'));
    });

    test('an unpublished package exits 2 rather than guessing', () async {
      final out = StringBuffer();
      final code = await runExplain(
        package: 'nope',
        projectPath: project({}),
        out: out,
        style: Style(enabled: false),
        client: fakePub(pub),
      );

      expect(code, ExitCodes.error);
      expect(out.toString(), contains('not published on pub.dev'));
    });
  });

  group('curated replacements', () {
    DependencyReport dead(String name) => DependencyReport(
          name: name,
          isDev: false,
          verdict: Verdict.dead,
          reasons: const ['no release in 30 months'],
        );
    const map = {
      'gone': CuratedReplacement(package: 'gone', replacement: 'heir', evidenceUrl: 'https://example.com/readme'),
    };
    final curated = CuratedReplacements(lookup: (name) => map[name]);
    final engine = HealthEngine(dartSdkVersion: Version(3, 11, 0));

    test('attaches a successor that checks out healthy, with its evidence', () async {
      final pub = fakePub({'heir': published(name: 'heir')});
      final lookups = await pub.fetchAll(curated.candidates([dead('gone')]));
      final report = curated.attach([dead('gone')], lookups, engine).single;

      expect(report.replacedBy, 'heir');
      expect(report.replacementSource, ReplacementSource.curated);
      expect(report.replacementEvidence, 'https://example.com/readme');
    });

    test('withholds a successor that is itself dying', () async {
      final pub = fakePub({
        'heir': published(name: 'heir', discontinued: true),
      });
      final lookups = await pub.fetchAll(['heir']);
      expect(curated.attach([dead('gone')], lookups, engine).single.replacedBy, isNull);
    });

    test('withholds a successor that could not be looked up', () {
      expect(curated.attach([dead('gone')], const {}, engine).single.replacedBy, isNull);
    });

    test('never touches a healthy package', () {
      const healthy = DependencyReport(name: 'gone', isDev: false, verdict: Verdict.healthy, reasons: []);
      expect(curated.candidates([healthy]), isEmpty);
    });

    test('every bundled entry cites an https source and names a different package', () {
      for (final entry in curatedReplacements) {
        expect(entry.evidenceUrl, startsWith('https://'), reason: entry.package);
        expect(entry.replacement, isNot(entry.package));
      }
      final names = curatedReplacements.map((e) => e.package).toList();
      expect(names.toSet().length, names.length, reason: 'duplicate entries');
    });
  });
}
