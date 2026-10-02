import 'package:flutter/material.dart';

import 'purposes.dart';

/// A purpose the user created themselves (e.g. "Zakat", "Eid shopping").
/// Unlike the fixed [kSpendPurposes] list, these are stored in SQLite,
/// survive restarts, and are included in backup/restore.
///
/// Rule: a custom purpose is spend-side only. Deleting one never orphans
/// transactions — every transaction still tagged with it is reassigned to
/// 'uncategorized' ("Other"), the same neutral default as new captures.
class CustomPurpose {
  final String id;
  final String label;
  final int createdAt;
  /// True for the sample purpose created by "Add demo data" (v1.5).
  final bool isDemo;

  const CustomPurpose({
    required this.id,
    required this.label,
    required this.createdAt,
    this.isDemo = false,
  });

  /// The tile shown in pickers and filter chips. Custom purposes get a
  /// tag icon — [purposeIcon] falls back to the same icon for the id.
  Purpose get asPurpose => Purpose(id, label, Icons.tag);

  /// Stable id derived from the user's label, e.g. "Zakat" ->
  /// "custom_zakat". Keeps transaction references intact across restarts.
  static String idFor(String label) {
    final slug =
        label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return 'custom_${slug.isEmpty ? 'x' : slug}';
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'label': label,
        'createdAt': createdAt,
        'isDemo': isDemo ? 1 : 0,
      };

  factory CustomPurpose.fromMap(Map<String, Object?> m) => CustomPurpose(
        id: m['id'] as String,
        label: m['label'] as String,
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
        isDemo: ((m['isDemo'] as num?) ?? 0) != 0,
      );
}
