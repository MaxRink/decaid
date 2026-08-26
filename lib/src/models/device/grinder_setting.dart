/// A grinder setting without assuming that every grinder has a numeric dial.
abstract class GrinderSetting {
  final String domain;
  final String displayValue;

  const GrinderSetting({required this.domain, required this.displayValue});

  Map<String, dynamic> toJson();

  /// Decodes the stable JSON form used by plugin and persistence boundaries.
  ///
  /// Keeping this parser here prevents each adapter from inventing a subtly
  /// different representation for numeric versus named grinder settings.
  static GrinderSetting fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    final domain = json['domain'];
    if (domain is! String || domain.isEmpty) {
      throw const FormatException('Grinder setting domain is required');
    }
    switch (kind) {
      case 'numeric':
        final value = json['value'];
        final unit = json['unit'];
        if (value is! num || !value.isFinite || unit is! String || unit.isEmpty) {
          throw const FormatException('Invalid numeric grinder setting');
        }
        return NumericGrinderSetting(
          domain: domain,
          value: value.toDouble(),
          unit: unit,
          displayValue: json['displayValue'] as String?,
        );
      case 'named':
        final value = json['value'];
        if (value is! String || value.isEmpty) {
          throw const FormatException('Invalid named grinder setting');
        }
        return NamedGrinderSetting(
          domain: domain,
          value: value,
          displayValue: json['displayValue'] as String?,
        );
      default:
        throw FormatException('Unknown grinder setting kind: $kind');
    }
  }
}

class NumericGrinderSetting extends GrinderSetting {
  final double value;
  final String unit;

  const NumericGrinderSetting({
    required super.domain,
    required this.value,
    required this.unit,
    String? displayValue,
  }) : super(displayValue: displayValue ?? '$value $unit');

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'numeric',
    'domain': domain,
    'value': value,
    'unit': unit,
    'displayValue': displayValue,
  };
}

class NamedGrinderSetting extends GrinderSetting {
  final String value;

  const NamedGrinderSetting({
    required super.domain,
    required this.value,
    String? displayValue,
  }) : super(displayValue: displayValue ?? value);

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'named',
    'domain': domain,
    'value': value,
    'displayValue': displayValue,
  };
}
