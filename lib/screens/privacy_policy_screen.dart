import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const AuroraBackdrop(),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(Icons.close_rounded, color: c.ink),
                      ),
                      Expanded(
                        child: Text(
                          'Конфиденциальность',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.ink, fontSize: 17, fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                    children: [
                      Text(
                        'Редакция от 21 сентября 2026 года. Сервис ScaleGuard.',
                        style: TextStyle(color: c.muted, height: 1.4),
                      ),
                      const SizedBox(height: 16),
                      _p(c, 'ScaleGuard предоставляет защищённый прокси-доступ к сети Интернет. Здесь описано, какие данные нужны сервису и зачем.'),
                      _h(c, 'Какие данные обрабатываются'),
                      _p(c, 'Email, пароль в защищённом виде, код из письма; вход через Яндекс или Telegram, если вы его выбрали; тариф, баланс и статус оплаты; служебные идентификаторы доступа и объём трафика в рамках тарифа; токен уведомлений и версия приложения.'),
                      _h(c, 'Зачем'),
                      _p(c, 'Чтобы вести аккаунт, пустить в сервис, принять оплату, прислать код, напомнить об окончании доступа и ответить в поддержке. Рекламным сетям данные не продаём и списки посещённых сайтов не собираем.'),
                      _h(c, 'Кому может понадобиться передача'),
                      _p(c, 'Платёжным партнёрам — для оплаты. Яндексу и Telegram — только при входе через них. Почте — чтобы доставить код. По закону — если это прямо требуется.'),
                      _h(c, 'Как долго'),
                      _p(c, 'Пока вы пользуетесь сервисом и разумный срок после удаления аккаунта. Коды из писем живут минуты.'),
                      _h(c, 'Ваши возможности'),
                      _p(c, 'Исправить email, выйти из приложения и запросить удаление учётки через поддержку.'),
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

  Widget _h(SgColors c, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Text(text, style: TextStyle(color: c.ink, fontSize: 16, fontWeight: FontWeight.w800)),
    );
  }

  Widget _p(SgColors c, String text) {
    return Text(text, style: TextStyle(color: c.muted, height: 1.5, fontSize: 15));
  }
}
