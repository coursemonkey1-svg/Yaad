import 'package:flutter/material.dart';

/// The fixed purpose list. Users can't delete these (keeps reports
/// consistent) but "uncategorized" is always available as a no-pressure
/// default, and tags add free-form flexibility.
class Purpose {
  final String id;
  final String label;
  final IconData icon;
  const Purpose(this.id, this.label, this.icon);
}

const kPurposes = <Purpose>[
  Purpose('groceries', 'Groceries', Icons.shopping_cart_outlined),
  Purpose('food', 'Food', Icons.restaurant_outlined),
  Purpose('transport', 'Transport', Icons.directions_car_outlined),
  Purpose('bills', 'Bills', Icons.receipt_long_outlined),
  Purpose('shopping', 'Shopping', Icons.shopping_bag_outlined),
  Purpose('health', 'Health', Icons.medical_services_outlined),
  Purpose('education', 'Education', Icons.school_outlined),
  Purpose('rent', 'Rent', Icons.home_outlined),
  Purpose('family', 'Family', Icons.family_restroom_outlined),
  Purpose('personal', 'Personal', Icons.person_outline),
  Purpose('loan', 'Loan to friend', Icons.handshake_outlined),
  Purpose('repaymentIn', 'Repayment received', Icons.payments_outlined),
  Purpose('reimbursement', 'Reimbursement', Icons.swap_horiz_outlined),
  Purpose('gift', 'Gift', Icons.card_giftcard_outlined),
  Purpose('uncategorized', 'Uncategorized', Icons.help_outline),
];

String purposeLabel(String id) =>
    kPurposes.firstWhere((p) => p.id == id, orElse: () => kPurposes.last).label;

IconData purposeIcon(String id) =>
    kPurposes.firstWhere((p) => p.id == id, orElse: () => kPurposes.last).icon;
