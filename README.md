# ScaleGuard

Клиент ScaleGuard для **Android** и **Windows** на одном Flutter-коде и одном
VPN-ядре (mihomo). Публичный репозиторий содержит исходники приложения,
собственный установщик для Windows и всё, что нужно для повторной сборки.

* Сайт: https://scaleguard.inzeworld.com
* Релизы (отсюда приложение обновляет себя): https://github.com/INZEWORLD/ScaleGuard/releases
* Поддержка: https://t.me/INZEWORLD_SUPPORT

---

## Возможности

* Один UI и одно ядро на Android и Windows; конфигурация — mihomo YAML,
  base64-обменники или Xray JSON.
* Три режима подключения: «По правилам» (TUN + российские сайты напрямую),
  «Весь трафик» (TUN) и «Системный прокси» (без прав администратора).
* Тарифы, оплата ЮKassa, триал, список устройств, вход по QR, e-mail, Яндекс и
  Telegram.
* Самообновление: проверка релизов GitHub при запуске и каждый час, загрузка и
  установка прямо из приложения.
* Прозрачные логотипы и иконки, тёмная и светлая темы.

---

## Что нужно установить

| Компонент | Версия | Зачем |
|-----------|--------|-------|
| [Flutter SDK](https://docs.flutter.dev/get-started/install/windows) | 3.35+ (stable, Dart 3.13+) | сборка UI на обе платформы |
| [Android Studio](https://developer.android.com/studio) или только Android SDK | API 35, NDK 27 | сборка APK |
| [Visual Studio Build Tools](https://visualstudio.microsoft.com/downloads/) | 2022, workload **Desktop development with C++** | сборка Windows |
| [CMake](https://cmake.org/download/) и [Ninja](https://github.com/ninja-build/ninja/releases) | любые свежие | запасной путь сборки Windows (см. ниже) |
| Python 3 | 3.10+ | `pip install cmake` для запасного пути |

Проверка окружения:

```powershell
flutter doctor -v
```

---

## Быстрый старт

```powershell
git clone https://github.com/INZEWORLD/ScaleGuard.git
cd ScaleGuard

Copy-Item .env.example .env      # адреса API и сайта
flutter pub get
```

`.env` — только публичные адреса, секретов в нём нет. Значения можно
переопределить на сборке через `--dart-define` (например, `API_URL` для
тестового стенда).

### Android

```powershell
flutter build apk --release
# build\app\outputs\flutter-apk\app-release.apk
```

Запуск на подключённом устройстве: `flutter run --release`.

### Windows

Обычный путь (нужен компонент «C++ CMake tools for Windows» в Visual Studio):

```powershell
flutter build windows --release
```

Запасной путь — когда этого компонента нет (сборка идёт standalone-CMake и
Ninja с тем же MSVC):

```powershell
tool\build_windows.bat release
```

Результат: `build\windows\x64\release\runner\ScaleGuard.exe` вместе с
`data\`, DLL движка и `core\mihomo.exe` — это и есть переносимый ПК-бандл.

### Установщик Windows

```powershell
tool\build_setup.ps1
# build\dist\ScaleGuard-Setup-<версия>.exe
```

Скрипт берёт готовый бандл из `build\windows\x64\release\runner`, упаковывает
его вместе с удалятором в один EXE (свой WinForms-установщик, не Inno Setup).
Подробнее — `docs/windows.md`.

---

## Автообновление

Приложение читает **последний релиз** GitHub (`/releases/latest`) при запуске и
далее раз в час. Версия берётся из имени файла для своей платформы:

| Платформа | Имя файла в релизе |
|-----------|--------------------|
| Windows | `ScaleGuard-Setup-<версия>.exe` |
| Android | `ScaleGuard-android-<версия>.apk` |

Если версия файла новее установленной, в центре окна появляется предложение
«Обновить / Позже»; после согласия файл скачивается, установщик запускается сам,
приложение закрывается и открывается уже новой версии.

Сайт `scaleguard.inzeworld.com` не хранит версию в ссылке: он запрашивает
последний релиз через GitHub API и подставляет точные имена файлов. Поэтому
кнопки «Скачать» обновляются сразу после публикации релиза, без пересборки
сайта.

На Android загрузка идёт в foreground-сервисе, а не в окне приложения. При
нажатии «Обновить» ScaleGuard сразу открывает экран разрешения установки из
неизвестных источников и одновременно начинает скачивание. Пока APK
скачивается, в шторке висит неубираемое уведомление с прогрессом; если его
попытаться смахнуть, оно возвращается. После завершения нажатие на уведомление
открывает системный установщик. Поэтому обновление продолжает качаться, даже
если приложение свёрнуто или Android выгрузил его окно.

Можно выпускать обновление только для одной платформы. Например, релиз с тегом
`v1.1.2`, в котором лежит старый `ScaleGuard-Setup-1.1.1.exe` и новый
`ScaleGuard-android-1.1.2.apk`, обновит только Android. Windows увидит, что её
файл всё ещё `1.1.1`, и не будет предлагать переустановку.

Порядок выпуска:

1. поднять версию в `pubspec.yaml` (`version: 1.1.2+4` — номер сборки после `+`
   должен расти, иначе Android не увидит обновление), `installer/Setup.cs`
   (`Const.Version`, `AssemblyVersion`), `installer/Uninstall.cs` и
   `tool/build_setup.ps1` (`$version`);
2. собрать APK и установщик (команды выше) и скопировать их в `build\dist\`;
3. опубликовать релиз:

```powershell
$env:GITHUB_TOKEN = "<токен с правом repo>"
tool\release.ps1 -Version 1.1.2
```

Скрипт создаёт тег `v1.1.2`, загружает
`build\dist\ScaleGuard-Setup-1.1.2.exe` и
`build\dist\ScaleGuard-android-1.1.2.apk` (APK переименовывается при загрузке)
и помечает релиз как Latest. Обновление подхватят все установленные версии ниже.

Если новая только Android-сборка, передайте старый установщик явно:

```powershell
tool\release.ps1 -Version 1.1.2 `
  -SetupPath build\dist\ScaleGuard-Setup-1.1.1.exe `
  -WindowsVersion 1.1.1
```

Сравнение версий — числовое (`lib/core/version_compare.dart`), суффикс сборки
`+N` и предрелизные хвосты не влияют на решение.

На Windows установщик обновляет копию в `%LOCALAPPDATA%\Programs\ScaleGuard`
без прав администратора и сам запускает новую версию. На Android открывается
системный установщик: в первый раз нужно разрешить ScaleGuard установку
приложений, дальше обновление ставится в два касания.

---

## Офлайн-режим

Если сервер аккаунта временно недоступен, приложение не отправляет пользователя
вводить пароль заново. На экране «Нет подключения» под кнопкой «Повторить»
появляется «Офлайн-режим». Он доступен, когда на устройстве уже есть сохранённая
сессия и последний скачанный список серверов; для этого после каждого успешного
обновления подписки клиент кладёт нормализованные конфигурации узлов в локальный
кэш.

В офлайн-режиме туннель поднимается по этим конфигурациям без запросов к API
аккаунта, поэтому сами узлы продолжают работать. Тарифы, баланс, покупки,
продление и список устройств при этом недоступны — для них нужен сервер. Когда
связь возвращается, кнопка «Проверить связь» на главном экране обновляет профиль
и узлы, не перезапуская приложение. Кэш узлов удаляется при выходе из аккаунта.

---

## Структура

```
lib/                 Dart-код: UI, состояние, сервисы, работа с ядром
  core/              движок mihomo, маршруты, обновления, платформенные мосты
  screens/           экраны
  services/          API, авторизация, оплата, обновления
  state/             AppState
android/             Android-проект (Gradle, VPN-сервис, установщик APK)
windows/             Windows-проект (runner, mihomo.exe, Wintun)
installer/           собственный установщик и удалятор (C#/WinForms)
tool/                скрипты сборки (Windows, установщик, релиз)
docs/                подробности по платформам
test/                юнит- и виджет-тесты (flutter test)
```

---

## Тесты

```powershell
flutter analyze lib
flutter test
```

---

## Источники и лицензии

* [Flutter](https://github.com/flutter/flutter) — BSD-3-Clause.
* [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo) — GPL-3.0; ядро
  `windows/runner/mihomo.exe` и `android/core/src/main/jniLibs/.../libclash.so`
  распространяются как отдельный процесс/библиотека, текст лицензии —
  `android/MIHOMO_LICENSE`, уведомление — `windows/runner/NOTICE.txt`,
  исходник нужной версии — тег upstream плюс лаунчер в `build-tools/mihomo-build/`.
* [Wintun](https://www.wintun.net/) — драйвер TUN, поставляется как `wintun.dll`.
* Пакеты Dart перечислены в `pubspec.yaml` (dio, provider, mobile_scanner,
  qr_flutter, package_info_plus и другие) — все под MIT/BSD-подобными
  лицензиями.

Код приложения © INZEWORLD. Переиспользование допускается только с уведомления
и сохранения лицензий сторонних компонентов.
