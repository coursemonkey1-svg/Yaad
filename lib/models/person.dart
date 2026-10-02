import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Someone the user lends to / borrows from / shares expenses with.
class Person {
  final String id;
  final String name;
  final String? phone;
  final String note;
  /// True for people created by "Add demo data" (v1.5) — removed
  /// again by "Remove demo data" once nothing references them.
  final bool isDemo;
  final DateTime createdAt;

  Person({
    String? id,
    required this.name,
    this.phone,
    this.note = '',
    this.isDemo = false,
    DateTime? createdAt,
  })  : id = id ?? _uuid.v4(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'phone': phone,
        'note': note,
        'isDemo': isDemo ? 1 : 0,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory Person.fromMap(Map<String, Object?> m) => Person(
        id: m['id'] as String,
        name: m['name'] as String? ?? '',
        phone: m['phone'] as String?,
        note: m['note'] as String? ?? '',
        isDemo: ((m['isDemo'] as num?) ?? 0) != 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int? ?? 0),
      );
}
