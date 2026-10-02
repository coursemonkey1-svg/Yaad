import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Direction of money movement (legacy display helper; [TxnKind] is
/// authoritative since v1.1).
enum TxnDirection { out, incoming, ownTransfer, adjustment }

/// What kind of money event this is. Lending is NEVER spending:
/// spending totals count only [spend], received totals only [receive].
enum TxnKind {
  spend,
  receive,
  lendOut,
  borrowIn,
  repayOut,
  repayIn,
  transfer, // between the user's own accounts — neither spend nor income
}

/// Plain-words label for a kind. Never "debit"/"credit"/"outflow".
String kindLabel(TxnKind kind) {
  switch (kind) {
    case TxnKind.spend:
      return 'Spent';
    case TxnKind.receive:
      return 'Received';
    case TxnKind.lendOut:
      return 'Lent';
    case TxnKind.borrowIn:
      return 'Borrowed';
    case TxnKind.repayOut:
      return 'Paid back';
    case TxnKind.repayIn:
      return 'Paid back';
    case TxnKind.transfer:
      return 'Moved';
  }
}

/// Lifecycle status of a transaction record.
enum TxnStatus { confirmed, needsReview, recurring, disputed, excluded }

/// Where the transaction came from.
enum TxnSource {
  share,
  ocr,
  statementImport,
  manual,
  notification,
  sms,
}

/// A single money event, enriched with the user's own context.
class YaadTransaction {
  final String id;
  final double amount;
  final String currency; // e.g. "PKR"
  final DateTime dateTime;
  final TxnDirection direction;
  final TxnKind kind;
  final String rawMerchant; // exactly what the bank / receipt said
  final String? aliasId; // link to MerchantAlias
  final String purpose; // groceries, food, ...
  final String note;
  final List<String> tags;
  final String? receiptPath; // local image path
  final String? audioPath; // local .m4a voice recording, if any
  final String? voiceNote; // speech-to-text transcript — separate from `note`
  final String? bankReference;
  final TxnSource source;
  final TxnStatus status;
  final String? personId; // who it was with, if anyone
  final String? linkedLendingId; // loan this settles / repays
  /// Which money account this belongs to ('meezan' / 'savings' /
  /// 'cash' / a user-added id). Nullable: NULL means "the default
  /// account" — callers pass the default explicitly, and the v4→v5
  /// migration backfills every existing row.
  final String? accountId;
  /// For transfers only: the account the money moved TO. A savings
  /// "add" is accountId = Meezan, toAccountId = savings; a "take
  /// back" is the reverse. NULL for every non-transfer row (and for
  /// transfers whose destination is unknown, e.g. pre-v1.4 rows).
  final String? toAccountId;
  final DateTime createdAt;
  final DateTime updatedAt;

  YaadTransaction({
    String? id,
    required this.amount,
    this.currency = 'PKR',
    required this.dateTime,
    this.direction = TxnDirection.out,
    TxnKind? kind,
    this.rawMerchant = '',
    this.aliasId,
    this.purpose = 'uncategorized',
    this.note = '',
    this.tags = const [],
    this.receiptPath,
    this.audioPath,
    this.voiceNote,
    this.bankReference,
    this.source = TxnSource.manual,
    this.status = TxnStatus.confirmed,
    this.personId,
    this.linkedLendingId,
    this.accountId,
    this.toAccountId,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? _uuid.v4(),
        kind = kind ?? _kindFromDirection(direction),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  static TxnKind _kindFromDirection(TxnDirection d) {
    switch (d) {
      case TxnDirection.out:
        return TxnKind.spend;
      case TxnDirection.incoming:
        return TxnKind.receive;
      case TxnDirection.ownTransfer:
        return TxnKind.transfer;
      case TxnDirection.adjustment:
        return TxnKind.spend;
    }
  }

  /// Direction derived from kind (for legacy consumers).
  TxnDirection get derivedDirection {
    switch (kind) {
      case TxnKind.spend:
      case TxnKind.lendOut:
      case TxnKind.repayOut:
        return TxnDirection.out;
      case TxnKind.receive:
      case TxnKind.borrowIn:
      case TxnKind.repayIn:
        return TxnDirection.incoming;
      case TxnKind.transfer:
        return TxnDirection.ownTransfer;
    }
  }

  /// True when this transaction counts as spending.
  bool get isSpending => kind == TxnKind.spend;

  /// True when this is a lending/udhaar movement (never spending).
  bool get isLending =>
      kind == TxnKind.lendOut ||
      kind == TxnKind.borrowIn ||
      kind == TxnKind.repayOut ||
      kind == TxnKind.repayIn;

  /// [audioPath]/[voiceNote] use a keep-sentinel so callers can
  /// explicitly clear them to null (plain `?? this.x` can't express that).
  static const _keep = Object();

  YaadTransaction copyWith({
    double? amount,
    String? currency,
    DateTime? dateTime,
    TxnDirection? direction,
    TxnKind? kind,
    String? rawMerchant,
    String? aliasId,
    String? purpose,
    String? note,
    List<String>? tags,
    String? receiptPath,
    Object? audioPath = _keep,
    Object? voiceNote = _keep,
    String? bankReference,
    TxnSource? source,
    TxnStatus? status,
    String? personId,
    String? linkedLendingId,
    String? accountId,
    String? toAccountId,
  }) {
    return YaadTransaction(
      id: id,
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      dateTime: dateTime ?? this.dateTime,
      direction: direction ?? this.direction,
      kind: kind ?? this.kind,
      rawMerchant: rawMerchant ?? this.rawMerchant,
      aliasId: aliasId ?? this.aliasId,
      purpose: purpose ?? this.purpose,
      note: note ?? this.note,
      tags: tags ?? this.tags,
      receiptPath: receiptPath ?? this.receiptPath,
      audioPath:
          identical(audioPath, _keep) ? this.audioPath : audioPath as String?,
      voiceNote:
          identical(voiceNote, _keep) ? this.voiceNote : voiceNote as String?,
      bankReference: bankReference ?? this.bankReference,
      source: source ?? this.source,
      status: status ?? this.status,
      personId: personId ?? this.personId,
      linkedLendingId: linkedLendingId ?? this.linkedLendingId,
      accountId: accountId ?? this.accountId,
      toAccountId: toAccountId ?? this.toAccountId,
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
        'kind': kind.name,
        'rawMerchant': rawMerchant,
        'aliasId': aliasId,
        'purpose': purpose,
        'note': note,
        'tags': tags.join('|'),
        'receiptPath': receiptPath,
        'audioPath': audioPath,
        'voiceNote': voiceNote,
        'bankReference': bankReference,
        'source': source.name,
        'status': status.name,
        'personId': personId,
        'linkedLendingId': linkedLendingId,
        'accountId': accountId,
        'toAccountId': toAccountId,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  factory YaadTransaction.fromMap(Map<String, Object?> m) {
    final direction =
        TxnDirection.values.byName(m['direction'] as String? ?? 'out');
    TxnKind kind;
    final kindRaw = m['kind'] as String?;
    if (kindRaw != null) {
      kind = TxnKind.values.byName(kindRaw);
    } else {
      // v1.0 rows: derive from purpose + direction.
      kind = _migrateKind(
          m['purpose'] as String? ?? 'uncategorized', direction);
    }
    return YaadTransaction(
      id: m['id'] as String,
      amount: (m['amount'] as num?)?.toDouble() ?? 0,
      currency: m['currency'] as String? ?? 'PKR',
      dateTime:
          DateTime.fromMillisecondsSinceEpoch(m['dateTime'] as int? ?? 0),
      direction: direction,
      kind: kind,
      rawMerchant: m['rawMerchant'] as String? ?? '',
      aliasId: m['aliasId'] as String?,
      purpose: m['purpose'] as String? ?? 'uncategorized',
      note: m['note'] as String? ?? '',
      tags: ((m['tags'] as String?) ?? '')
          .split('|')
          .where((t) => t.isNotEmpty)
          .toList(),
      receiptPath: m['receiptPath'] as String?,
      audioPath: m['audioPath'] as String?,
      voiceNote: m['voiceNote'] as String?,
      bankReference: m['bankReference'] as String?,
      source: TxnSource.values.byName(m['source'] as String? ?? 'manual'),
      status: TxnStatus.values.byName(m['status'] as String? ?? 'confirmed'),
      personId: m['personId'] as String?,
      linkedLendingId: m['linkedLendingId'] as String?,
      accountId: m['accountId'] as String?,
      toAccountId: m['toAccountId'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          m['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
          m['updatedAt'] as int? ?? DateTime.now().millisecondsSinceEpoch),
    );
  }

  /// v1.0 → v1.1 migration mapping (also used by the DB onUpgrade).
  static TxnKind _migrateKind(String purpose, TxnDirection direction) {
    switch (purpose) {
      case 'loan':
        return direction == TxnDirection.out
            ? TxnKind.lendOut
            : TxnKind.borrowIn;
      case 'repaymentIn':
        return direction == TxnDirection.out
            ? TxnKind.repayOut
            : TxnKind.repayIn;
      case 'gift':
        return direction == TxnDirection.out
            ? TxnKind.spend
            : TxnKind.receive;
      default:
        return _kindFromDirection(direction);
    }
  }

  /// Maps a v1.0 row for the SQL migration (same rules as [_migrateKind]).
  static String migrateKindName(String purpose, String directionName) {
    final direction = TxnDirection.values.byName(directionName);
    return _migrateKind(purpose, direction).name;
  }
}
