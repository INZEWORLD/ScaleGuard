import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../screens/privacy_policy_screen.dart';
import '../theme/app_colors.dart';

class LegalLinks extends StatelessWidget {
  const LegalLinks({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final style = TextStyle(
      color: c.faint,
      fontSize: compact ? 11 : 12,
      height: 1.35,
      fontWeight: FontWeight.w600,
    );
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Link(
          label: 'Условия использования',
          style: style,
          onTap: () => launchUrl(Uri.parse(AppConfig.termsUrl), mode: LaunchMode.externalApplication),
        ),
        Text('  ·  ', style: style),
        _Link(
          label: 'Политика конфиденциальности',
          style: style,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyScreen()),
            );
          },
        ),
      ],
    );
  }
}

class _Link extends StatelessWidget {
  const _Link({required this.label, required this.style, required this.onTap});
  final String label;
  final TextStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Text(label, style: style.copyWith(decoration: TextDecoration.underline)),
    );
  }
}
