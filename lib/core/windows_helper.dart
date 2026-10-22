import 'dart:io';

import '../services/log_service.dart';
import 'powershell.dart';

/// The elevated "helper": starting the client with administrator rights without
/// a UAC prompt every single time.
///
/// A real Windows service would need its own executable, its own installer and a
/// privileged interface for the client to talk to. A scheduled task with the
/// *highest* run level achieves the same thing for this application — Windows
/// starts the process with an administrator token and never prompts — and it can
/// be registered by the elevated instance itself, which is exactly the state the
/// client is already in the first time the user connects.
///
/// The task is registered from XML rather than from `schtasks` switches, because
/// the switches cannot express what is wanted here:
///
/// * it has **no triggers at all**, so it never starts the client on its own. The
///   autostart switch is the only thing that decides that, and a second, hidden
///   launcher would be a second answer to the same question;
/// * it runs as the interactive user with [highest][1] rights, which is what
///   makes the launch promptless;
/// * it may be started on demand, which is what [launch] does.
///
/// [1]: https://learn.microsoft.com/windows/win32/taskschd/taskschedulerschema-runlevel-principaltype-element
///
/// The obvious shortcut — registering a task and then disabling it — does not
/// work, and is worth spelling out because it looks like it should: Windows
/// refuses to start a *disabled* task ("cannot run because it is disabled"), so
/// the client would ask the helper for a promptless launch, be refused every
/// time, and fall back to the UAC prompt it was installed to avoid.
class WindowsHelper {
  /// Task name. Deliberately ASCII: it travels through `schtasks`, a console
  /// tool with its own opinions about encodings.
  static const String taskName = 'ScaleGuard Helper';

  /// Set when the task could not be created, started or removed.
  String? lastError;

  bool get isSupported => Platform.isWindows;

  /// The task definition.
  ///
  /// Exposed as text so it can be checked without registering anything — see
  /// `test/helper_test.dart`.
  static String taskXml({
    required String userId,
    required String executable,
  }) {
    // The task scheduler would otherwise start the client from `system32`, and a
    // process whose working directory is somewhere else entirely is a surprise
    // waiting to happen.
    final workingDirectory = File(executable).parent.path;
    return '''
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Starts ScaleGuard with administrator rights so the tunnel does not need a UAC prompt on every launch. Registered by the client itself.</Description>
  </RegistrationInfo>
  <!-- Empty on purpose: this task is only ever started on demand. -->
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>${_xmlEscape(userId)}</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>${_xmlEscape(executable)}</Command>
      <WorkingDirectory>${_xmlEscape(workingDirectory)}</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
''';
  }

  /// Whether a task is registered that starts *this* executable.
  ///
  /// The second half matters after an update or a move: a task pointing at a path
  /// that no longer exists is a helper that silently never delivers, and it would
  /// otherwise never be repaired.
  Future<bool> isInstalled() async {
    if (!isSupported) return false;
    try {
      final result = await Process.run(
        'schtasks',
        <String>['/query', '/tn', taskName, '/xml'],
      );
      if (result.exitCode != 0) return false;
      // The output can arrive as UTF-16 read through a single-byte decoder, which
      // leaves a null before every character; dropping them is enough to compare
      // an ASCII path either way.
      final text = '${result.stdout}'.replaceAll('\u0000', '');
      return text.contains(Platform.resolvedExecutable);
    } catch (_) {
      return false;
    }
  }

  /// Registers the task. Requires an elevated caller.
  Future<bool> install() async {
    if (!isSupported) return false;
    lastError = null;
    final userId = await _currentUserId();
    if (userId == null) {
      lastError = 'Не удалось определить текущего пользователя';
      return false;
    }
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'scaleguard-helper-task.xml',
    );
    try {
      // `schtasks /xml` reads the file as Unicode, so it is written as UTF-16LE
      // with a byte-order mark rather than the UTF-8 the rest of the app uses.
      await file.writeAsBytes(
        _utf16Le(taskXml(
          userId: userId,
          executable: Platform.resolvedExecutable,
        )),
        flush: true,
      );
      final result = await Process.run(
        'schtasks',
        <String>['/create', '/f', '/tn', taskName, '/xml', file.path],
      );
      if (result.exitCode != 0) {
        lastError = _explain(result, 'создание задачи');
        return false;
      }
    } catch (error) {
      lastError = 'Не удалось создать задачу: $error';
      return false;
    } finally {
      try {
        if (file.existsSync()) await file.delete();
      } catch (_) {
        // A leftover file in the temporary directory is not worth failing over.
      }
    }
    LogService.instance
        .log('helper', 'installed for ${Platform.resolvedExecutable}');
    return true;
  }

  /// Deletes the task, restoring the ordinary UAC prompt.
  Future<bool> remove() async {
    if (!isSupported) return false;
    lastError = null;
    final result = await Process.run(
      'schtasks',
      <String>['/delete', '/f', '/tn', taskName],
    );
    if (result.exitCode != 0) {
      lastError = _explain(result, 'удаление задачи');
      return false;
    }
    LogService.instance.log('helper', 'removed');
    return true;
  }

  /// Asks Windows to start the client through the task.
  ///
  /// Returns whether the request was accepted — not whether a window came up.
  /// Whether the new instance took over is checked by the caller, which is the
  /// only real proof that the helper did its job.
  Future<bool> launch() async {
    if (!isSupported) return false;
    lastError = null;
    try {
      final result = await Process.run(
        'schtasks',
        <String>['/run', '/tn', taskName],
      );
      if (result.exitCode != 0) {
        lastError = _explain(result, 'запуск задачи');
        return false;
      }
      return true;
    } catch (error) {
      lastError = 'Не удалось обратиться к Планировщику заданий: $error';
      return false;
    }
  }

  /// The identity the task runs as, as Windows itself reports it.
  ///
  /// Read from the system rather than assembled from `USERDOMAIN` and `USERNAME`:
  /// the two disagree on a domain-joined machine — one carries the NetBIOS name,
  /// the other the DNS name — and a task whose principal cannot be resolved is not
  /// registered at all.
  Future<String?> _currentUserId() async {
    final result = await runPowerShell(
      '[System.Security.Principal.WindowsIdentity]::GetCurrent().Name',
    );
    final name = result.firstLine;
    return name.isEmpty ? null : name;
  }

  /// Turns a `schtasks` failure into something worth showing a user.
  ///
  /// The raw text is kept for the log instead: `schtasks` answers in the OEM code
  /// page, which arrives as mojibake, and an exit code is not a diagnosis.
  String _explain(ProcessResult result, String action) {
    final raw = '${result.stdout}\n${result.stderr}'.trim();
    LogService.instance
        .log('helper', '$action: exit ${result.exitCode}: $raw');
    return 'Windows отклонил $action (код ${result.exitCode})';
  }
}

/// UTF-16LE with a byte-order mark, which is what the task scheduler expects.
List<int> _utf16Le(String text) {
  // `codeUnits` is UTF-16 already, so a surrogate pair is two units and needs no
  // special handling.
  final bytes = <int>[0xFF, 0xFE];
  for (final unit in text.codeUnits) {
    bytes
      ..add(unit & 0xFF)
      ..add((unit >> 8) & 0xFF);
  }
  return bytes;
}

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
