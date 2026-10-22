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
далее раз в час. Если тег новее установленной версии, в центре окна появляется
предложение «Обновить / Позже»; после согласия файл скачивается, установщик
запускается сам, приложение закрывается и открывается уже новой версии.

Чтобы выпустить обновление, достаточно опубликовать релиз с новым тегом и
двумя вложениями:

| Платформа | Имя файла в релизе | Постоянная ссылка для сайта |
|-----------|--------------------|-----------------------------|
| Windows | `ScaleGuard-Setup-<версия>.exe` + `ScaleGuard-Setup.exe` | `/releases/latest/download/ScaleGuard-Setup.exe` |
| Android | `ScaleGuard-android.apk` | `/releases/latest/download/ScaleGuard-android.apk` |

`ScaleGuard-Setup.exe` — копия установщика под стабильным именем. Сайт ссылается
именно на неё, поэтому кнопки «Скачать» на `scaleguard.inzeworld.com` начинают
отдавать новую версию сразу после публикации релиза, без пересборки сайта.

Порядок выпуска:

1. поднять версию в `pubspec.yaml` (`version: 1.1.2+4` — номер сборки после `+`
   должен расти, иначе Android не увидит обновление), `installer/Setup.cs`
   (`Const.Version`, `AssemblyVersion`), `installer/Uninstall.cs` и
   `tool/build_setup.ps1` (`$version`);
2. собрать APK и установщик (команды выше) и скопировать их в `build\dist\`;
3. опубликовать релиз:

```powershell
$env:GITHUB_TOKEN = "<токен с правом repo>"
tool\release.ps1 -Version 1.1.1
```

Скрипт создаёт тег `v1.1.1`, загружает `build\dist\ScaleGuard-Setup-1.1.1.exe`
и `build\dist\ScaleGuard-android.apk` и помечает релиз как Latest. Обновление
подхватят все установленные версии ниже.

Сравнение версий — числовое (`lib/core/version_compare.dart`), суффикс сборки
`+N` и предрелизные хвосты не влияют на решение.

На Windows установщик обновляет копию в `%LOCALAPPDATA%\Programs\ScaleGuard`
без прав администратора и сам запускает новую версию. На Android открывается
системный установщик: в первый раз нужно разрешить ScaleGuard установку
приложений, дальше обновление ставится в два касания.

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
