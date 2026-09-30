import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Direction of money movement.
enum TxnDirection { out, incoming, ownTransfer, adjustment }

/// Lifecycle status of a transaction record.
enum TxnStatus { confirmed, needsReview, recurring, disputed, excluded }

/// Where the transaction came from.
enum TxnSource { share, ocr, statementImport, manual, notification }

/// A single money event, enriched with the user's own context.
class YaadTransaction {
  final String id;
  final double amount;
  final String currency; // e.g. "PKR"
  final DateTime dateTime;
  final TxnDirection direction;
  final String rawMerchant; // exactly what the bank / receipt said
  final String? aliasId; // link to MerchantAlias
  final String purpose; // groceries, food, ...
  final String note;
  final List<String> tags;
  final String? receiptPath; // local image path
  final String? bankReference;
  final TxnSource source;
  final TxnStatus status;
  final String? personId; // who it was with, if anyone
  final String? linkedLendingId; // loan this settles / repays
  final DateTime createdAt;
  final DateTime updatedAt;

  YaadTransaction({
    String? id,
    required this.amount,
    this.currency = 'PKR',
    required this.dateTime,
    this.direction = TxnDirection.out,
    this.rawMerchant = '',
    this.aliasId,
    this.purpose = 'uncategorized',
    this.note = '',
    this.tags = const [],
    this.receiptPath,
    this.bankReference,
    this.source = TxnSource.manual,
    this.status = TxnStatus.confirmed,
    this.personId,
    this.linkedLendingId,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? _uuid.v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  YaadTransaction copyWith({
    double? amount,
    String? currency,
    DateTime? dateTime,
    TxnDirection? direction,
    String? rawMerchant,
    String? aliasId,
    String? purpose,
    String? note,
    List<String>? tags,
    String? receiptPath,
    String? bankReference,
    TxnSource? source,
    TxnStatus? status,
    String? personId,
    String? linkedLendingId,
  }) {
    return YaadTransaction(
      id: id,
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      dateTime: dateTime ?? this.dateTime,
      direction: direction ?? this.direction,
      rawMerchant: rawMerchant ?? this.rawMerchant,
      aliasId: aliasId ?? this.aliasId,
      purpose: purpose ?? this.purpose,
      note: note ?? this.note,
      tags: tags ?? this.tags,
      receiptPath: receiptPath ?? this.receiptPath,
      bankReference: bankReference ?? this.bankReference,
      source: source ?? this.source,
      status: status ?? this.status,
      personId: personId ?? this.personId,
      linkedLendingId: linkedLendingId ?? this.linkedLendingId,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'amount': amount,
        'currency': currency,
        'dateTime': dateTime.millisecondsSinceEpoch,
        'direction': direction.name,
        'rawMerchant': rawMerchant,
        'aliasId': aliasId,
        'purpose': purpose,
        'note': note,
        'tags': tags.join('|'),
        'receiptPath': receiptPath,
        'bankReference': bankReference,
        'source': source.name,
        'status': status.name,
        'personId': personId,
        'linkedLendingId': linkedLendingId,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  factory YaadTransaction.fromMap(Map<String, Object?> m) => YaadTransaction(
        id: m['id'] as String,
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        currency: m['currency'] as String? ?? 'PKR',
        dateTime:
            DateTime.fromMillisecondsSinceEpoch(m['dateTime'] as int? ?? 0),
        direction: TxnDirection.values.byName(m['direction'] as String? ?? 'out'),
        rawMerchant: m['rawMerchant'] as String? ?? '',
        aliasId: m['aliasId'] as String?,
        purpose: m['purpose'] as String? ?? 'uncategorized',
        note: m['note'] as String? ?? '',
        tags: ((m['tags'] as String?) ?? '').split('|').where((t) => t.isNotEmpty).toList(),
        receiptPath: m['receiptPath'] as String?,
        bankReference: m['bankReference'] as String?,
        source: TxnSource.values.byName(m['source'] as String? ?? 'manual'),
        status: TxnStatus.values.byName(m['status'] as String? ?? 'confirmed'),
        personId: m['personId'] as String?,
        linkedLendingId: m['linkedLendingId'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            m['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            m['updatedAt'] as int? ?? DateTime.now().millisecondsSinceEpoch),
      );
}
