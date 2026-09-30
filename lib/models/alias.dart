import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Maps a confusing bank/statement label to the user's own recognizable name.
class MerchantAlias {
  final String id;
  final String rawName; // exactly as the bank shows it
  final String alias; // e.g. "corner grocery near home"
  final int usageCount;
  final DateTime lastUsed;

  MerchantAlias({
    String? id,
    required this.rawName,
    required this.alias,
    this.usageCount = 1,
    DateTime? lastUsed,
  })  : id = id ?? _uuid.v4(),
        lastUsed = lastUsed ?? DateTime.now();

  MerchantAlias used() => MerchantAlias(
        id: id,
        rawName: rawName,
        alias: alias,
        usageCount: usageCount + 1,
        lastUsed: DateTime.now(),
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'rawName': rawName,
        'alias': alias,
        'usageCount': usageCount,
        'lastUsed': lastUsed.millisecondsSinceEpoch,
      };

  factory MerchantAlias.fromMap(Map<String, Object?> m) => MerchantAlias(
        id: m['id'] as String,
        rawName: m['rawName'] as String? ?? '',
        alias: m['alias'] as String? ?? '',
        usageCount: m['usageCount'] as int? ?? 1,
        lastUsed:
            DateTime.fromMillisecondsSinceEpoch(m['lastUsed'] as int? ?? 0),
      );
}
