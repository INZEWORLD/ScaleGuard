# ScaleGuard на Apple (iOS / macOS)

Клиент использует **то же ядро mihomo и тот же UI**, что на Windows и Android.
Отличие только в одном: Apple не разрешает приложению создавать туннель
самостоятельно — трафик обязан обрабатываться **Network Extension**
(`NEPacketTunnelProvider`) в отдельном процессе. Поэтому ядро живёт в
расширении, а Flutter-код общается с ним через тот же RESTful-контроллер mihomo,
что и на других платформах.

```
Flutter UI ─┐
            ├─ lib/core/engines/apple_vpn_engine.dart
            │        │ MethodChannel "com.scaleguard.app/core"
            │        ▼
            │  ios/Runner/ScaleGuardCorePlugin.swift   (TunnelManager)
            │        │ NETunnelProviderSession + App Group group.com.scaleguard.app
            │        ▼
            └─ ios/ScaleGuardPacketTunnel/PacketTunnelProvider.swift
                     │ CoreHost.swift → C-шим → mihomo (стат. библиотека)
                     ▼
                 RESTful controller на 127.0.0.1 → тот же Dart-клиент
```

## Что уже лежит в репозитории

| Файл | Назначение |
|------|-----------|
| `ios/Runner/ScaleGuardCorePlugin.swift` | регистрация MethodChannel, установка VPN-профиля, запуск/остановка туннеля, ожидание готовности ядра |
| `ios/ScaleGuardPacketTunnel/PacketTunnelProvider.swift` | сам туннель: настройка `NEPacketTunnelNetworkSettings`, старт ядра, публикация счётчиков |
| `ios/ScaleGuardPacketTunnel/CoreHost.swift` | мост Swift → C → Go, плюс чтение счётчиков через контроллер |
| `lib/core/engines/apple_vpn_engine.dart` | Dart-движок; без собранного расширения сообщает точную причину, а не «висит» |

## Сборка (только macOS + Xcode)

> Собрать iOS-часть на Windows невозможно: `GOOS=ios` требует SDK Xcode.
> Всё, что ниже, выполняется на Mac (или в облаке: Codemagic, GitHub Actions
> с раннером `macos-latest`).

### 1. Собрать ядро в статическую библиотеку

```bash
git clone https://github.com/MetaCubeX/mihomo.git
cd mihomo
# Требуется Go 1.21+ и Xcode Command Line Tools.
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
  CC="$(xcrun --sdk iphoneos --find clang)" \
  CGO_CFLAGS="-isysroot $(xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=15.0 -arch arm64" \
  CGO_LDFLAGS="-isysroot $(xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=15.0 -arch arm64" \
  go build -tags with_gvisor -buildmode=c-archive -o libmihomo-ios.a ./...
```

Ту же команду повторите с `GOOS=ios GOARCH=amd64` и `--sdk iphonesimulator`
(as `libmihomo-sim.a`), затем объедините в один `Libcore.xcframework`:

```bash
xcodebuild -create-xcframework \
  -library libmihomo-ios.a -headers include \
  -library libmihomo-sim.a -headers include \
  -output ios/Frameworks/Libcore.xcframework
```

### 2. Добавить C-шим

Создайте `ios/ScaleGuardCore/ScaleGuardCore.h` и `.c`, экспортирующие три
функции, которые вызывает `CoreHost.swift`:

```c
int  ScaleGuardCoreStart(const char *configPath, int controllerPort, const char *secret);
void ScaleGuardCoreAttachTun(int tunnelFileDescriptor);
void ScaleGuardCoreStop(void);
```

`ScaleGuardCoreStart` — тонкая обёртка над `hub.Parse(...)` из `hub/hub.go`
(сигнатура: `Parse(configBytes []byte, options ...Option) error`). Готовый
пример на Go смотрите в `build-tools/mihomo-build/main.go` — это тот же запуск,
что используется на Windows, только собранный как библиотека.

### 3. Добавить таргет расширения в Xcode

1. Откройте `ios/Runner.xcworkspace`.
2. **File → New → Target… → Network Extension**, имя — `ScaleGuardPacketTunnel`,
   тип — **Packet Tunnel**.
3. В `ScaleGuardPacketTunnel` добавьте файлы `PacketTunnelProvider.swift` и
   `CoreHost.swift`, а также `Libcore.xcframework` и C-шим.
4. **Signing & Capabilities** для **обоих** таргетов:
   * `App Groups` → `group.com.scaleguard.app`
   * `Network Extensions` → `Packet Tunnel`
   * `com.apple.developer.networking.networkextension` = `packet-tunnel-provider`
5. В `Info.plist` расширения добавьте:
   ```xml
   <key>NSExtension</key>
   <dict>
     <key>NSExtensionPointIdentifier</key>
     <string>com.apple.networkextension.packet-tunnel</string>
   </dict>
   ```
6. В настройках сборки расширения задайте `SCALEGUARD_CORE_AVAILABLE` (компилятор
   определяет его наличием шима) и bundle id `com.scaleguard.app.packet-tunnel`
   — он должен совпадать со `providerBundleIdentifier` в `TunnelManager`.
7. В `Runner` таргете добавьте `ScaleGuardCorePlugin.swift` и зарегистрируйте
   плагин в `AppDelegate.swift`:
   ```swift
   if let registrar = self.registrar(forPlugin: "ScaleGuardCorePlugin") {
       ScaleGuardCorePlugin.register(with: registrar)
   }
   ```

### 4. Проверка

```bash
flutter build ios --debug --no-codesign   # компиляция
flutter run -d <iphone>                   # реальное устройство
```

Туннель **не проверяется** на симуляторе: Network Extension там ограничен.

## Ограничения, о которых нужно знать заранее

1. **Лимит памяти расширения.** iOS убивает packet-tunnel провайдера, который
   превысил бюджет (по сообществу разработчиков — 15–50 МБ). Go-рантайм сам по
   себе занимает заметную часть. Поэтому в `PacketTunnelProvider`:
   * профиль передаётся ядру файлом, а не через Swift-структуры;
   * geo-базы не используются (правила маршрутизации — только CIDR);
   * публикуются лишь небольшие JSON-счётчики.
   Если туннель «отваливается» на слабых устройствах — сокращайте число серверов
   в профиле и интервал `url-test`.
2. **App Store, правило 5.4 (VPN Apps).** Нужен аккаунт разработчика
   **организации**, экран с описанием собираемых данных **до** покупки, запрет
   на продажу/передачу данных третьим лицам. Правило 4.2.7 — про Remote Desktop,
   к VPN отношения не имеет.
3. **Лицензии.** mihomo — GPL-3.0. На Windows ядро поставляется отдельным
   процессом (`windows/runner/mihomo.exe`) и оформлено как отдельный продукт
   (см. `windows/runner/NOTICE.txt`). На iOS ядро линкуется в расширение —
   это производная работа, поэтому **всё приложение должно распространяться под
   GPL-3.0** с предоставлением исходников. Если нужна закрытая лицензия —
   единственный чистый путь на iOS — отдельное коммерческое соглашение с
   авторами mihomo, либо другое ядро.

## Диагностика

| Симптом | Причина |
|---------|---------|
| `Pоссийский` — «Расширение недоступно» | таргет `ScaleGuardPacketTunnel` не добавлен в Xcode |
| «Профиль mihomo не найден» | приложение не записало `config.yaml` в App Group — проверьте entitlement в **обоих** таргетах |
| «Ядро не запустилось за 20 секунд» | не собран `Libcore.xcframework` или не выставлен `providerBundleIdentifier` |
| Туннель поднимается и падает | исчерпан лимит памяти расширения — см. пункт 1 |
