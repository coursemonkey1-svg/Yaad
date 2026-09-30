import 'package:flutter/material.dart';

/// The fixed purpose list. Users can't delete these (keeps reports
/// consistent) but "uncategorized" is always available as a no-pressure
/// default, and tags add free-form flexibility.
///
/// ~12 life-shaped categories (research: giant lists kill adoption).
/// `hint` carries local flavor (bijli, rickshaw…) without changing the UI
/// language — professional English globally, familiar at home.
class Purpose {
  final String id;
  final String label;
  final IconData icon;
  final String hint;
  const Purpose(this.id, this.label, this.icon, [this.hint = '']);
}

/// Spending categories shown on the "I spent" capture path.
const kSpendPurposes = <Purpose>[
  Purpose('groceries', 'Groceries', Icons.shopping_cart_outlined,
      'Soda, sabzi, kitchen'),
  Purpose('food', 'Food', Icons.restaurant_outlined, 'Dhabba, cafe, delivery'),
  Purpose('transport', 'Transport', Icons.directions_car_outlined,
      'Rickshaw, bus, fuel'),
  Purpose('bills', 'Bills', Icons.receipt_long_outlined, 'Bijli, gas, water'),
  Purpose('mobile', 'Mobile', Icons.smartphone_outlined, 'Load, bundles'),
  Purpose('health', 'Health', Icons.medical_services_outlined,
      'Doctor, medicine'),
  Purpose('education', 'Education', Icons.school_outlined, 'Fees, books'),
  Purpose('rent', 'Rent', Icons.home_outlined, 'House, mess bill'),
  Purpose('shopping', 'Shopping', Icons.shopping_bag_outlined,
      'Clothes, home stuff'),
  Purpose('family', 'Family', Icons.family_restroom_outlined,
      'Parents, kids, home'),
  Purpose('personal', 'Personal', Icons.person_outline, 'Just for you'),
  Purpose('uncategorized', 'Other', Icons.help_outline, ''),
];

/// Where received money came from ("I received" path).
const kReceiveSources = <Purpose>[
  Purpose('salary', 'Salary', Icons.work_outline, 'Monthly pay'),
  Purpose('business', 'Business', Icons.store_outlined, ''),
  Purpose('gift', 'Gift', Icons.card_giftcard_outlined, ''),
  Purpose('refund', 'Refund', Icons.undo_outlined, ''),
  Purpose('other_in', 'Other', Icons.help_outline, ''),
];

/// Legacy alias: the full spend list (used by grids/filters).
const kPurposes = kSpendPurposes;

/// In-memory labels for user-created custom purposes. The fixed lists above
/// are const, so custom purposes (stored in SQLite) register here at app
/// start and after every create/delete — see [YaadDb.refreshCustomPurposeRegistry].
/// This keeps purposeLabel()/purposeIcon() synchronous for every caller
/// (txn rows, summaries, suggestions).
final _customLabels = <String, String>{};

/// Replaces the registered custom-purpose labels wholesale.
void registerCustomPurposes(Map<String, String> labels) {
  _customLabels
    ..clear()
    ..addAll(labels);
}

/// Ids the user created (deletable). The fixed list can never be deleted.
bool isCustomPurpose(String id) => _customLabels.containsKey(id);

String purposeLabel(String id) {
  for (final p in kSpendPurposes) {
    if (p.id == id) return p.label;
  }
  for (final p in kReceiveSources) {
    if (p.id == id) return p.label;
  }
  return _customLabels[id] ?? 'Other';
}

IconData purposeIcon(String id) {
  for (final p in kSpendPurposes) {
    if (p.id == id) return p.icon;
  }
  for (final p in kReceiveSources) {
    if (p.id == id) return p.icon;
  }
  // Custom purposes get the same tag icon their picker tile uses.
  if (_customLabels.containsKey(id)) return Icons.tag;
  return Icons.help_outline;
}

String purposeHint(String id) {
  for (final p in kSpendPurposes) {
    if (p.id == id) return p.hint;
  }
  for (final p in kReceiveSources) {
    if (p.id == id) return p.hint;
  }
  return '';
}
