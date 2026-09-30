import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum LendingType { loan, advance, sharedExpense, reimbursement, gift }

enum LendingStatus { open, partial, settled, writtenOff, gift }

/// One lending record: money lent (or borrowed — sign handled by [isOwedToMe]).
class LendingRecord {
  final String id;
  final String personId;
  final LendingType type;
  final double originalAmount;
  final String currency;
  final DateTime date;
  final String reason;
  final DateTime? dueDate;
  final String note;
  final String? receiptPath;
  /// true = they owe me, false = I owe them.
  final bool isOwedToMe;
  final LendingStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  LendingRecord({
    String? id,
    required this.personId,
    this.type = LendingType.loan,
    required this.originalAmount,
    this.currency = 'PKR',
    required this.date,
    this.reason = '',
    this.dueDate,
    this.note = '',
    this.receiptPath,
    this.isOwedToMe = true,
    this.status = LendingStatus.open,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? _uuid.v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  LendingRecord copyWith({
    String? personId,
    LendingType? type,
    double? originalAmount,
    String? currency,
    DateTime? date,
    String? reason,
    DateTime? dueDate,
    String? note,
    String? receiptPath,
    bool? isOwedToMe,
    LendingStatus? status,
  }) {
    return LendingRecord(
      id: id,
      personId: personId ?? this.personId,
      type: type ?? this.type,
      originalAmount: originalAmount ?? this.originalAmount,
      currency: currency ?? this.currency,
      date: date ?? this.date,
      reason: reason ?? this.reason,
      dueDate: dueDate ?? this.dueDate,
      note: note ?? this.note,
      receiptPath: receiptPath ?? this.receiptPath,
      isOwedToMe: isOwedToMe ?? this.isOwedToMe,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'personId': personId,
        'type': type.name,
        'originalAmount': originalAmount,
        'currency': currency,
        'date': date.millisecondsSinceEpoch,
        'reason': reason,
        'dueDate': dueDate?.millisecondsSinceEpoch,
        'note': note,
        'receiptPath': receiptPath,
        'isOwedToMe': isOwedToMe ? 1 : 0,
        'status': status.name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  factory LendingRecord.fromMap(Map<String, Object?> m) => LendingRecord(
        id: m['id'] as String,
        personId: m['personId'] as String? ?? '',
        type: LendingType.values.byName(m['type'] as String? ?? 'loan'),
        originalAmount: (m['originalAmount'] as num?)?.toDouble() ?? 0,
        currency: m['currency'] as String? ?? 'PKR',
        date: DateTime.fromMillisecondsSinceEpoch(m['date'] as int? ?? 0),
        reason: m['reason'] as String? ?? '',
        dueDate: (m['dueDate'] as int?) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['dueDate'] as int),
        note: m['note'] as String? ?? '',
        receiptPath: m['receiptPath'] as String?,
        isOwedToMe: (m['isOwedToMe'] as int? ?? 1) == 1,
        status: LendingStatus.values.byName(m['status'] as String? ?? 'open'),
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int? ?? 0),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updatedAt'] as int? ?? 0),
      );
}

/// One repayment against a [LendingRecord].
class Repayment {
  final String id;
  final String lendingId;
  final double amount;
  final DateTime date;
  final String note;
  final String? transactionId; // link back to the money-in transaction

  Repayment({
    String? id,
    required this.lendingId,
    required this.amount,
    required this.date,
    this.note = '',
    this.transactionId,
  }) : id = id ?? _uuid.v4();

  Map<String, Object?> toMap() => {
        'id': id,
        'lendingId': lendingId,
        'amount': amount,
        'date': date.millisecondsSinceEpoch,
        'note': note,
        'transactionId': transactionId,
      };

  factory Repayment.fromMap(Map<String, Object?> m) => Repayment(
        id: m['id'] as String,
        lendingId: m['lendingId'] as String? ?? '',
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        date: DateTime.fromMillisecondsSinceEpoch(m['date'] as int? ?? 0),
        note: m['note'] as String? ?? '',
        transactionId: m['transactionId'] as String?,
      );
}
