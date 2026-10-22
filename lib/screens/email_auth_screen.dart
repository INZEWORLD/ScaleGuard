import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/legal_links.dart';

enum _EmailStep { email, login, register, resetRequest, resetConfirm }

class EmailAuthScreen extends StatefulWidget {
  const EmailAuthScreen({super.key});

  @override
  State<EmailAuthScreen> createState() => _EmailAuthScreenState();
}

class _EmailAuthScreenState extends State<EmailAuthScreen> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _codeFocus = FocusNode();
  _EmailStep _step = _EmailStep.email;
  bool _obscure = true;
  bool _newObscure = true;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _newPasswordCtrl.dispose();
    _codeCtrl.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  ButtonStyle get _wideButton => FilledButton.styleFrom(
        minimumSize: const Size(88, 52),
        maximumSize: const Size(2000, 52),
      );

  Future<void> _continueFromEmail() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) return;
    final result = await context.read<AppState>().lookupEmail(email);
    if (!mounted || result == null) return;
    if (result.exists) {
      if (!result.hasPassword) {
        context.read<AppState>().setError(
          'Этот email привязан к Яндексу или Telegram. Войдите через них.',
        );
        return;
      }
      setState(() => _step = _EmailStep.login);
      return;
    }
    setState(() => _step = _EmailStep.register);
    final sent = await context.read<AppState>().requestEmailCode(email, register: true);
    if (sent && mounted) {
      _codeFocus.requestFocus();
    }
  }

  Future<void> _submit() async {
    final state = context.read<AppState>();
    final ok = _step == _EmailStep.register
        ? await state.registerWithEmail(
            email: _emailCtrl.text.trim(),
            password: _passwordCtrl.text,
            code: _codeCtrl.text.trim(),
          )
        : await state.loginWithEmail(
            _emailCtrl.text.trim(),
            _passwordCtrl.text,
          );
    if (ok && mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _requestResetCode() async {
    final sent = await context.read<AppState>().requestPasswordResetCode(
      _emailCtrl.text.trim(),
    );
    if (sent && mounted) {
      setState(() => _step = _EmailStep.resetConfirm);
      _codeFocus.requestFocus();
    }
  }

  Future<void> _confirmReset() async {
    final state = context.read<AppState>();
    final ok = await state.confirmPasswordReset(
      email: _emailCtrl.text.trim(),
      verificationCode: _codeCtrl.text.trim(),
      newPassword: _newPasswordCtrl.text,
    );
    if (ok && mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = SgColors.of(context);
    final title = switch (_step) {
      _EmailStep.email => 'Почта',
      _EmailStep.login => 'Вход',
      _EmailStep.register => 'Регистрация',
      _EmailStep.resetRequest => 'Восстановление пароля',
      _EmailStep.resetConfirm => 'Новый пароль',
    };

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
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          _step == _EmailStep.email
                              ? Icons.close_rounded
                              : Icons.arrow_back_rounded,
                          color: c.ink,
                        ),
                        onPressed: () {
                          if (_step == _EmailStep.email) {
                            Navigator.pop(context);
                          } else if (_step == _EmailStep.resetRequest) {
                            setState(() => _step = _EmailStep.login);
                            state.clearMessages();
                          } else if (_step == _EmailStep.resetConfirm) {
                            setState(() => _step = _EmailStep.resetRequest);
                            state.clearMessages();
                          } else {
                            setState(() => _step = _EmailStep.email);
                            state.clearMessages();
                          }
                        },
                      ),
                      Expanded(
                        child: Text(
                          title,
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
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: c.card,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: c.line),
                          boxShadow: [
                            BoxShadow(
                              color: SgColors.blue.withValues(alpha: 0.08),
                              blurRadius: 24,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _buildStepSubtitle(),
                              style: TextStyle(color: c.muted, height: 1.4, fontSize: 15),
                            ),
                            const SizedBox(height: 18),
                            TextField(
                              controller: _emailCtrl,
                              enabled: _step == _EmailStep.email ||
                                  _step == _EmailStep.resetRequest,
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [AutofillHints.email],
                              decoration: const InputDecoration(labelText: 'Email'),
                              onSubmitted: (_) => _onPrimaryAction(),
                            ),
                            if (_step == _EmailStep.register) ...[
                              const SizedBox(height: 14),
                              TextField(
                                controller: _codeCtrl,
                                focusNode: _codeFocus,
                                keyboardType: TextInputType.number,
                                maxLength: 6,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                  LengthLimitingTextInputFormatter(6),
                                ],
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 6,
                                ),
                                decoration: const InputDecoration(
                                  labelText: 'Код из письма',
                                  counterText: '',
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: state.busy
                                      ? null
                                      : () => state.requestEmailCode(
                                            _emailCtrl.text.trim(),
                                            register: true,
                                          ),
                                  child: const Text('Отправить ещё раз'),
                                ),
                              ),
                            ],
                            if (_step == _EmailStep.resetConfirm) ...[
                              const SizedBox(height: 14),
                              TextField(
                                controller: _codeCtrl,
                                focusNode: _codeFocus,
                                keyboardType: TextInputType.number,
                                maxLength: 6,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                  LengthLimitingTextInputFormatter(6),
                                ],
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 6,
                                ),
                                decoration: const InputDecoration(
                                  labelText: 'Код из письма',
                                  counterText: '',
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: state.busy ? null : _requestResetCode,
                                  child: const Text('Отправить ещё раз'),
                                ),
                              ),
                            ],
                            if (_step != _EmailStep.email &&
                                _step != _EmailStep.resetRequest) ...[
                              const SizedBox(height: 8),
                              TextField(
                                controller: _step == _EmailStep.resetConfirm
                                    ? _newPasswordCtrl
                                    : _passwordCtrl,
                                obscureText: _step == _EmailStep.resetConfirm
                                    ? _newObscure
                                    : _obscure,
                                autofillHints: _step == _EmailStep.resetConfirm
                                    ? const [AutofillHints.newPassword]
                                    : const [AutofillHints.password],
                                decoration: InputDecoration(
                                  labelText: _step == _EmailStep.resetConfirm
                                      ? 'Новый пароль'
                                      : 'Пароль',
                                  suffixIcon: IconButton(
                                    onPressed: () => setState(
                                      () => _step == _EmailStep.resetConfirm
                                          ? _newObscure = !_newObscure
                                          : _obscure = !_obscure,
                                    ),
                                    icon: Icon(
                                      (_step == _EmailStep.resetConfirm ? _newObscure : _obscure)
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            if (_step == _EmailStep.login) ...[
                              const SizedBox(height: 6),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: state.busy
                                      ? null
                                      : () {
                                          state.clearMessages();
                                          setState(
                                            () => _step = _EmailStep.resetRequest,
                                          );
                                        },
                                  child: const Text('Забыл пароль?'),
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            FilledButton(
                              style: _wideButton,
                              onPressed: state.busy || state.cooldownActive
                                  ? null
                                  : _onPrimaryAction,
                              child: Text(
                                state.busy
                                    ? 'Подождите…'
                                    : state.cooldownActive
                                        ? 'Повторите через ${state.cooldownLabel}'
                                        : _primaryButtonLabel(),
                              ),
                            ),
                            if (state.cooldownActive) ...[
                              const SizedBox(height: 12),
                              Text(
                                'Пять попыток уже израсходованы. Вход и отправка '
                                'письма снова станут доступны через '
                                '${state.cooldownLabel}.',
                                style: TextStyle(
                                  color: c.faint,
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (state.error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          state.error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: SgColors.red),
                        ),
                      ],
                      if (state.info != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          state.info!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: SgColors.green),
                        ),
                      ],
                      const SizedBox(height: 28),
                      const LegalLinks(compact: true),
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

  String _buildStepSubtitle() {    return switch (_step) {
      _EmailStep.email => 'Укажите email — мы определим, есть ли аккаунт',
      _EmailStep.login => 'Аккаунт найден. Введите пароль',
      _EmailStep.register => 'Новый аккаунт. Код уже отправлен на почту',
      _EmailStep.resetRequest =>
        'Введите email, на который зарегистрирован аккаунт — отправим код для сброса пароля',
      _EmailStep.resetConfirm =>
        'Код отправлен. Введите код из письма и задайте новый пароль',
    };
  }

  String _primaryButtonLabel() {
    return switch (_step) {
      _EmailStep.email => 'Продолжить',
      _EmailStep.login => 'Войти',
      _EmailStep.register => 'Создать аккаунт',
      _EmailStep.resetRequest => 'Отправить код',
      _EmailStep.resetConfirm => 'Сохранить пароль и войти',
    };
  }

  void _onPrimaryAction() {
    if (_step == _EmailStep.email) {
      _continueFromEmail();
    } else if (_step == _EmailStep.resetRequest) {
      _requestResetCode();
    } else if (_step == _EmailStep.resetConfirm) {
      _confirmReset();
    } else {
      _submit();
    }
  }
}
