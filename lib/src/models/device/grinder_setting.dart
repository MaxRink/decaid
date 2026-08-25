/// A grinder setting without assuming that every grinder has a numeric dial.
abstract class GrinderSetting {
  final String domain;
  final String displayValue;

  const GrinderSetting({required this.domain, required this.displayValue});

  Map<String, dynamic> toJson();
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
