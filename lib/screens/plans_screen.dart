import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';

/// The tariffs page: what the account can afford, what it is on, and the way to
/// pay.
///
/// The page used to be a list of plans plus a balance, which left the two things
/// a paying user actually needs — how to top up, and whether the payment they
/// just made has landed — to a single button that appeared only while a payment
/// happened to be pending. Both live here now, and a payment that is open in the
/// browser reports itself.
class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = context.read<AppState>();
      if (!state.offlineMode) state.loadPlans();
    });
  }

  Future<void> _openTopUpSheet(int? suggested) async {
    final state = context.read<AppState>();
    final amount = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TopUpSheet(suggested: suggested),
    );
    if (amount == null) return;
    await state.startTopUp(amount);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final plans = state.plans;
    final balance = (state.user?.balance ?? 0).toDouble();
    final c = SgColors.of(context);
    final trialAvailable = state.trial?.available == true;
    final subscription = state.tunnel;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (!widget.embedded) const AuroraBackdrop(),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                if (!widget.embedded)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.arrow_back_rounded, color: c.ink),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
                  child: Row(
                    children: [
                      Text(
                        'Тарифы',
                        style: TextStyle(
                          color: c.ink,
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.8,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Обновить',
                        onPressed: state.busy || state.offlineMode
                            ? null
                            : () => state.loadPlans(),
                        icon: Icon(Icons.refresh_rounded, color: c.muted),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 108),
                    children: [
                      _BalanceCard(
                        balance: balance,
                        onTopUp: state.busy || state.offlineMode
                            ? null
                            : () => _openTopUpSheet(null),
                      ),
                      if (subscription != null && subscription.hasActiveSubscription) ...[
                        const SizedBox(height: 12),
                        _SubscriptionCard(tunnel: subscription),
                      ],
                      if (!state.offlineMode &&
                          state.pendingTopUpPaymentId != null) ...[
                        const SizedBox(height: 12),
                        _PaymentPendingCard(
                          onCheck: state.busy ? null : () => state.confirmPendingTopUp(),
                          onCancel: state.busy ? null : state.cancelTopUpWait,
                        ),
                      ] else if (!state.offlineMode && trialAvailable) ...[
                        const SizedBox(height: 12),
                        _TrialCard(
                          days: state.trial?.durationDays,
                          busy: state.busy,
                          onActivate: state.activateTrial,
                        ),
                      ],
                      if (state.offlineMode) ...[
                        const SizedBox(height: 18),
                        _OfflinePlansNotice(
                          busy: state.busy,
                          onRetry: state.retryOfflineConnection,
                        ),
                      ] else ...[
                        const SizedBox(height: 18),
                        Text(
                          'Подключить тариф',
                          style: TextStyle(
                            color: c.ink,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (state.plansLoading && plans.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 32),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else
                          ...plans.map(
                            (plan) => _PlanCard(
                              plan: plan,
                              balance: balance,
                              busy: state.busy,
                              onBuy: () => state.purchasePlan(plan.id),
                              onTopUp: () => _openTopUpSheet(
                                plan.chargeRub > balance
                                    ? (plan.chargeRub - balance).ceil()
                                    : null,
                              ),
                            ),
                          ),
                      ],
                      if (state.error != null) ...[
                        const SizedBox(height: 12),
                        _Message(text: state.error!, color: SgColors.red),
                      ],
                      if (state.info != null) ...[
                        const SizedBox(height: 12),
                        _Message(text: state.info!, color: SgColors.green),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Money on the account and the way to add more.
class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.balance, this.onTopUp});

  final double balance;
  final VoidCallback? onTopUp;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            SgColors.blue.withValues(alpha: 0.16),
            SgColors.violet.withValues(alpha: 0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: c.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Баланс',
                  style: TextStyle(
                    color: c.muted,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_money(balance)} ₽',
                  style: TextStyle(
                    color: c.ink,
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Оплата банковской картой через ЮKassa',
                  style: TextStyle(color: c.faint, fontSize: 12.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: onTopUp,
            icon: const Icon(Icons.add_card_rounded, size: 18),
            label: const Text('Пополнить'),
          ),
        ],
      ),
    );
  }
}

/// The subscription this account is on, in one line.
class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.tunnel});

  final TunnelInfo tunnel;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final limit = (tunnel.trafficLimitBytes ?? 0).toDouble();
    final used = (tunnel.usedTrafficBytes ?? 0).toDouble();
    final rows = <String>[
      if ((tunnel.expireAt ?? '').trim().isNotEmpty)
        'Активна до ${_date(tunnel.expireAt!)}',
      if (limit > 0) 'Трафик ${_traffic(used)} из ${_traffic(limit)}',
      if (tunnel.username != null && tunnel.username!.trim().isNotEmpty)
        'Логин ${tunnel.username}',
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: SgColors.green.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _IconBox(icon: Icons.verified_rounded, color: SgColors.green),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Подписка активна',
                  style: TextStyle(
                    color: c.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      row,
                      style: TextStyle(color: c.muted, fontSize: 13, height: 1.35),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Practice access for an account that has never had any.
class _TrialCard extends StatelessWidget {
  const _TrialCard({required this.busy, required this.onActivate, this.days});

  final bool busy;
  final VoidCallback onActivate;
  final int? days;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: SgColors.violet.withValues(alpha: 0.35)),
      ),
      child: _iconRow(
        c,
        icon: Icons.card_giftcard_rounded,
        color: SgColors.violet,
        title: 'Пробный доступ',
        text: days != null && days! > 0
            ? 'Бесплатно на $days ${_days(days!)} — без карты и без оплаты'
            : 'Бесплатный пробный период — без карты и без оплаты',
        action: FilledButton(
          onPressed: busy ? null : onActivate,
          child: Text(busy ? 'Подождите…' : 'Получить'),
        ),
      ),
    );
  }
}

/// A payment that is open in the browser right now.
class _PaymentPendingCard extends StatelessWidget {
  const _PaymentPendingCard({this.onCheck, this.onCancel});

  final VoidCallback? onCheck;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: SgColors.blue.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Ждём оплату',
                  style: TextStyle(
                    color: c.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Оплатите в открывшемся окне. Тариф включится автоматически, как '
            'только платёж пройдёт — приложение проверяет это само.',
            style: TextStyle(color: c.muted, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton(onPressed: onCancel, child: const Text('Отменить')),
              const SizedBox(width: 8),
              FilledButton(onPressed: onCheck, child: const Text('Проверить сейчас')),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.balance,
    required this.busy,
    required this.onBuy,
    required this.onTopUp,
  });

  final VpnPlan plan;
  final double balance;
  final bool busy;
  final VoidCallback onBuy;
  final VoidCallback onTopUp;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final affordable = balance >= plan.chargeRub;
    final hasDiscount =
        plan.promoDiscountPercent != null && plan.promoDiscountPercent! > 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: plan.isPopular ? SgColors.blue : c.line,
          width: plan.isPopular ? 1.4 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  plan.title,
                  style: TextStyle(
                    color: c.ink,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (plan.isPopular)
                _Tag(text: 'Популярный', color: SgColors.green),
              if (hasDiscount) ...[
                const SizedBox(width: 6),
                _Tag(text: '−${plan.promoDiscountPercent}%', color: SgColors.violet),
              ],
            ],
          ),
          if (plan.description.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              plan.description,
              style: TextStyle(color: c.muted, height: 1.35),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${plan.chargeRub} ₽',
                style: TextStyle(
                  color: c.ink,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 8),
              if (plan.listPriceRub > plan.chargeRub)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '${plan.listPriceRub} ₽',
                    style: TextStyle(
                      color: c.faint,
                      fontSize: 13,
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          if (plan.periodLabel.trim().isNotEmpty)
            Text(
              plan.periodLabel,
              style: TextStyle(color: c.faint, fontSize: 12.5),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : onBuy,
                  child: Text(
                    affordable
                        ? 'Оплатить с баланса'
                        : 'Оплатить ${plan.chargeRub} ₽',
                  ),
                ),
              ),
              if (!affordable) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: busy ? null : onTopUp,
                  child: const Text('Пополнить'),
                ),
              ],
            ],
          ),
          if (!affordable) ...[
            const SizedBox(height: 8),
            Text(
              'На балансе ${_money(balance)} ₽ — при оплате откроется страница '
              'ЮKassa, и тариф включится сам после платежа.',
              style: TextStyle(color: c.faint, fontSize: 12, height: 1.35),
            ),
          ],
        ],
      ),
    );
  }
}

/// The amount picker for a top-up that is not tied to a plan.
class _TopUpSheet extends StatefulWidget {
  const _TopUpSheet({this.suggested});

  /// What the balance is short of, when the sheet was opened from a plan.
  final int? suggested;

  @override
  State<_TopUpSheet> createState() => _TopUpSheetState();
}

class _TopUpSheetState extends State<_TopUpSheet> {
  /// The smallest top-up the server accepts, and the number the button leans
  /// on. Ten rubles is what covers a shortfall on the cheapest plan without
  /// sending the user off to pay more than they owe.
  static const int minTopUpRub = 10;

  static const List<int> _presets = [10, 100, 500, 1000, 2000];
  final _customCtrl = TextEditingController();
  int? _selected;

  @override
  void initState() {
    super.initState();
    final suggested = widget.suggested;
    if (suggested != null && suggested > 0) {
      // The exact shortfall is offered first: paying the difference is what the
      // user came for, and the round numbers are the alternative.
      final rounded = ((suggested + 99) ~/ 100) * 100;
      _selected = rounded;
      if (!_presets.contains(rounded)) {
        _customCtrl.text = '$rounded';
      }
    }
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  int? get _amount {
    final custom = int.tryParse(_customCtrl.text.trim());
    if (custom != null && custom >= minTopUpRub) return custom;
    return _selected;
  }

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final amount = _amount;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: c.sheet,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          border: Border.all(color: c.line),
        ),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: c.line,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Пополнение баланса',
              style: TextStyle(
                color: c.ink,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Оплата картой через ЮKassa. Деньги придут на баланс, тариф '
              'можно будет подключить сразу.',
              style: TextStyle(color: c.muted, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final preset in _presets)
                  _AmountChip(
                    label: '$preset ₽',
                    selected: _selected == preset && _customCtrl.text.trim().isEmpty,
                    onTap: () => setState(() {
                      _selected = preset;
                      _customCtrl.clear();
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _customCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Своя сумма, ₽',
                hintText: 'Например, 750',
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(88, 52),
                maximumSize: const Size(2000, 52),
              ),
              onPressed: amount == null || amount < minTopUpRub
                  ? null
                  : () => Navigator.of(context).pop(amount),
              child: Text(
                amount == null || amount < minTopUpRub
                    ? 'Минимум $minTopUpRub ₽'
                    : 'Оплатить $amount ₽',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AmountChip extends StatelessWidget {
  const _AmountChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? SgColors.blue.withValues(alpha: 0.18)
              : c.pill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? SgColors.blue : c.line,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? SgColors.blue : c.ink,
            fontWeight: FontWeight.w700,
            fontSize: 14.5,
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _IconBox extends StatelessWidget {
  const _IconBox({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }
}

/// What the tariffs page becomes when the account API is unreachable.
///
/// The plans are not cached — prices and payment providers change too often to
/// pretend otherwise — so the page explains the gap and points back at the
/// action that can close it instead of showing a blank list or a raw timeout.
class _OfflinePlansNotice extends StatelessWidget {
  const _OfflinePlansNotice({required this.busy, required this.onRetry});

  final bool busy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SgColors.violet.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: SgColors.violet.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _IconBox(icon: Icons.cloud_off_rounded, color: SgColors.violet),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Тарифы недоступны в офлайн-режиме',
                  style: TextStyle(
                    color: c.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Сохранённые серверы работают, но баланс, покупки и '
                  'продление требуют связи с сервером аккаунта.',
                  style: TextStyle(
                    color: c.muted,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: busy ? null : onRetry,
                  style: TextButton.styleFrom(
                    foregroundColor: SgColors.violet,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                  ),
                  icon: busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              SgColors.violet,
                            ),
                          ),
                        )
                      : const Icon(Icons.refresh_rounded, size: 17),
                  label: Text(busy ? 'Проверяем…' : 'Проверить связь'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: TextStyle(color: color, height: 1.35));
  }
}

/// Icon, title, body and one action — the shape two cards on this page share.
Widget _iconRow(
  SgColors c, {
  required IconData icon,
  required Color color,
  required String title,
  required String text,
  required Widget action,
}) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _IconBox(icon: icon, color: color),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: c.ink,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 3),
            Text(text, style: TextStyle(color: c.muted, fontSize: 13, height: 1.4)),
          ],
        ),
      ),
      const SizedBox(width: 10),
      action,
    ],
  );
}

String _money(double value) {
  final rounded = value.round();
  final text = rounded.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (i > 0 && (text.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(text[i]);
  }
  return buffer.toString();
}

String _traffic(double bytes) {
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(bytes / gb >= 10 ? 0 : 1)} ГБ';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(0)} МБ';
  return '${(bytes / 1024).toStringAsFixed(0)} КБ';
}

String _date(String raw) {
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return raw;
  final local = parsed.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year}';
}

String _days(int count) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod10 == 1 && mod100 != 11) return 'день';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'дня';
  return 'дней';
}
