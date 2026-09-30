import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Someone the user lends to / borrows from / shares expenses with.
class Person {
  final String id;
  final String name;
  final String? phone;
  final String note;
  final DateTime createdAt;

  Person({
    String? id,
    required this.name,
    this.phone,
    this.note = '',
    DateTime? createdAt,
  })  : id = id ?? _uuid.v4(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'phone': phone,
        'note': note,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory Person.fromMap(Map<String, Object?> m) => Person(
        id: m['id'] as String,
        name: m['name'] as String? ?? '',
        phone: m['phone'] as String?,
        note: m['note'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int? ?? 0),
      );
}
