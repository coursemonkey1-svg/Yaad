import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../models/settings.dart';

/// Pro gating + Play Billing plumbing for the one-time `yaad_pro` unlock.
///
/// Rules (ratified 2026-09-30):
/// - No ads, no tracking, no backend — ever.
/// - Billing plumbing ships from day one, but the purchase switch
///   ([AppSettings.billingEnabled]) stays OFF until retention validates.
///   While it is off, every feature is unlocked: nobody hits a paywall
///   while falling in love with the app.
/// - When billing turns on, Pro features (app lock, automatic backup,
///   statement/CSV export, custom categories, accent themes) require the
///   one-time purchase — except app lock, which is grandfathered for
///   v1.0 installs that ever enabled it.
class ProService {
  static const productId = 'yaad_pro';

  /// True when Pro features are available (billing off = everything free).
  static bool isUnlocked(AppSettings s) => !s.billingEnabled || s.proUnlocked;

  /// App lock: also free for grandfathered v1.0 users.
  static bool canUseAppLock(AppSettings s) =>
      isUnlocked(s) || s.appLockGrandfathered;

  static bool canUseBackup(AppSettings s) => isUnlocked(s);
  static bool canUseExport(AppSettings s) => isUnlocked(s);
  static bool canUseCustomCategories(AppSettings s) => isUnlocked(s);
  static bool canUseStatement(AppSettings s) => isUnlocked(s);

  /// The default teal accent is always free; others are Pro.
  static bool canUseAccent(AppSettings s, String accent) =>
      accent == 'teal' || isUnlocked(s);

  // ---------- Play Billing plumbing (dormant until billingEnabled) ----------

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  ProductDetails? _product;
  bool _storeAvailable = false;

  /// Called when a purchase is verified — the host wires this to
  /// `appState.update(settings.copyWith(proUnlocked: true))`.
  VoidCallback? onUnlocked;

  /// Starts listening to the purchase stream. Safe to call even when
  /// billing is disabled; nothing is shown to the user.
  Future<void> init() async {
    try {
      _storeAvailable = await _iap.isAvailable();
    } catch (_) {
      // Plugin unavailable (non-Play build, test environment): Pro
      // plumbing stays dormant. This runs before runApp in main() —
      // a throw here would stop the whole app from starting.
      _storeAvailable = false;
      return;
    }
    if (!_storeAvailable) return;
    _sub = _iap.purchaseStream.listen(
      _onPurchases,
      onError: (_) {},
    );
    try {
      final resp = await _iap.queryProductDetails({productId});
      if (resp.productDetails.isNotEmpty) {
        _product = resp.productDetails.first;
      }
    } catch (_) {
      // Store hiccup — purchase UI simply won't offer Pro yet.
    }
  }

  String? get priceLabel => _product?.price;

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      if (p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored) {
        if (p.productID == productId) {
          onUnlocked?.call();
        }
      }
      if (p.pendingCompletePurchase) {
        try {
          await _iap.completePurchase(p);
        } catch (_) {}
      }
    }
  }

  /// Starts the one-time Pro purchase. Returns false when the store
  /// or product is unavailable.
  Future<bool> buyPro() async {
    final product = _product;
    if (!_storeAvailable || product == null) return false;
    try {
      return await _iap.buyNonConsumable(
          purchaseParam: PurchaseParam(productDetails: product));
    } catch (_) {
      return false;
    }
  }

  Future<void> restore() async {
    try {
      await _iap.restorePurchases();
    } catch (_) {}
  }

  void dispose() => _sub?.cancel();
}
