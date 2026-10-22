import '../models/models.dart';
import 'api_client.dart';

class PaymentService {
  PaymentService(this._api);

  final ApiClient _api;

  Future<List<VpnPlan>> fetchPlans() async {
    final res = await _api.get<List<dynamic>>('/api/plans');
    final list = res.data ?? [];
    return list.map((e) => VpnPlan.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<PaymentProviders> fetchProviders() async {
    final res = await _api.get<Map<String, dynamic>>('/api/payment/providers');
    return PaymentProviders.fromJson(res.data ?? {});
  }

  Future<PurchaseResult> purchasePlan(int planId) async {
    try {
      final res = await _api.post<Map<String, dynamic>>('/api/payment/create', data: {
        'planId': planId,
      });
      return PurchaseResult.fromJson(res.data ?? {}, statusCode: res.statusCode ?? 200);
    } on Object catch (e) {
      final payload = _api.tryExtractErrorPayload(e);
      if (payload != null) {
        return PurchaseResult.fromJson(payload, statusCode: 409);
      }
      rethrow;
    }
  }

  Future<TopUpSession> createTopUp({
    required int amountRub,
    int? planId,
    String provider = 'yookassa',
  }) async {
    final res = await _api.post<Map<String, dynamic>>('/api/payment/topup', data: {
      'amount': amountRub,
      'planId': planId,
      'provider': provider,
    });
    final data = res.data!;
    return TopUpSession(
      paymentId: data['paymentId'] as String,
      paymentUrl: data['paymentUrl'] as String,
      provider: (data['provider'] as String?) ?? provider,
      planId: planId,
    );
  }

  Future<TopUpConfirmResult> confirmTopUp(String paymentId) async {
    final res = await _api.post<Map<String, dynamic>>('/api/payment/topup/confirm', data: {
      'paymentId': paymentId,
    });
    return TopUpConfirmResult.fromJson(res.data ?? {});
  }
}
