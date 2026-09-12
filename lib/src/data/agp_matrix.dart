/// Android Gradle Plugin compatibility requirements.
///
/// Every row below was taken from Google's own per-version AGP release notes at
/// https://developer.android.com/build/releases/ and not from memory. Rows
/// marked `inferred` had no explicit "maximum API level" sentence on the page;
/// the value is the only API level the page mentions. Where even that was
/// ambiguous the field is left null and `upkeep` simply does not run the
/// compileSdk check for that version.
///
/// Last verified: 12 September 2026 (AGP 9.4 was current).
library;

/// The published requirements for one AGP minor version line.
class AgpRequirement {
  const AgpRequirement({
    required this.agp,
    required this.gradleMin,
    required this.jdkMin,
    required this.buildToolsMin,
    this.maxApi,
    this.maxApiInferred = false,
  });

  /// The AGP version line, as `major.minor`.
  final String agp;

  /// Minimum Gradle version this AGP line requires.
  final String gradleMin;

  /// Minimum JDK major version this AGP line requires.
  final int jdkMin;

  /// Minimum SDK Build Tools version this AGP line requires.
  final String buildToolsMin;

  /// Highest `compileSdk` this AGP line supports, or null when unpublished.
  final int? maxApi;

  /// True when [maxApi] was read from context rather than an explicit statement.
  final bool maxApiInferred;
}

/// Every AGP line `upkeep` knows about, oldest first.
const List<AgpRequirement> agpMatrix = <AgpRequirement>[
  AgpRequirement(agp: '8.0', gradleMin: '8.0', jdkMin: 17, buildToolsMin: '30.0.3'),
  AgpRequirement(agp: '8.1', gradleMin: '8.0', jdkMin: 17, buildToolsMin: '33.0.1'),
  AgpRequirement(agp: '8.2', gradleMin: '8.2', jdkMin: 17, buildToolsMin: '34.0.0', maxApi: 34),
  AgpRequirement(agp: '8.3', gradleMin: '8.4', jdkMin: 17, buildToolsMin: '34.0.0', maxApi: 34),
  AgpRequirement(agp: '8.4', gradleMin: '8.6', jdkMin: 17, buildToolsMin: '34.0.0', maxApi: 34),
  AgpRequirement(agp: '8.5', gradleMin: '8.7', jdkMin: 17, buildToolsMin: '34.0.0', maxApi: 34),
  AgpRequirement(agp: '8.6', gradleMin: '8.7', jdkMin: 17, buildToolsMin: '34.0.0', maxApi: 35),
  AgpRequirement(agp: '8.7', gradleMin: '8.9', jdkMin: 17, buildToolsMin: '34.0.0', maxApi: 35),
  AgpRequirement(agp: '8.8', gradleMin: '8.10.2', jdkMin: 17, buildToolsMin: '35.0.0', maxApi: 35),
  AgpRequirement(agp: '8.9', gradleMin: '8.11.1', jdkMin: 17, buildToolsMin: '35.0.0', maxApi: 35),
  AgpRequirement(
      agp: '8.10',
      gradleMin: '8.11.1',
      jdkMin: 17,
      buildToolsMin: '35.0.0',
      maxApi: 36,
      maxApiInferred: true),
  AgpRequirement(
      agp: '8.11',
      gradleMin: '8.13',
      jdkMin: 17,
      buildToolsMin: '35.0.0',
      maxApi: 36,
      maxApiInferred: true),
  AgpRequirement(
      agp: '8.12',
      gradleMin: '8.13',
      jdkMin: 17,
      buildToolsMin: '35.0.0',
      maxApi: 36,
      maxApiInferred: true),
  AgpRequirement(
      agp: '8.13',
      gradleMin: '8.13',
      jdkMin: 17,
      buildToolsMin: '35.0.0',
      maxApi: 36,
      maxApiInferred: true),
  AgpRequirement(agp: '9.0', gradleMin: '9.1.0', jdkMin: 17, buildToolsMin: '36.0.0', maxApi: 36),
  AgpRequirement(
      agp: '9.1',
      gradleMin: '9.3.1',
      jdkMin: 17,
      buildToolsMin: '36.0.0',
      maxApi: 37,
      maxApiInferred: true),
  AgpRequirement(agp: '9.2', gradleMin: '9.4.1', jdkMin: 17, buildToolsMin: '36.0.0', maxApi: 37),
  AgpRequirement(agp: '9.3', gradleMin: '9.5.0', jdkMin: 17, buildToolsMin: '36.0.0', maxApi: 37),
  AgpRequirement(agp: '9.4', gradleMin: '9.6.0', jdkMin: 17, buildToolsMin: '36.0.0', maxApi: 37),
];

/// The requirements for [agpVersion], matched on its `major.minor` line.
///
/// Returns null for AGP versions older than 8.0, which `upkeep` does not carry
/// data for rather than guess at.
AgpRequirement? requirementForAgp(String agpVersion) {
  final parts = agpVersion.split('.');
  if (parts.length < 2) return null;
  final line = '${parts[0]}.${parts[1]}';
  for (final row in agpMatrix) {
    if (row.agp == line) return row;
  }
  return null;
}

/// The newest AGP line in the bundled matrix.
AgpRequirement get newestKnownAgp => agpMatrix.last;
