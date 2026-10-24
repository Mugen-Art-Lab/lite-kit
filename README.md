# Yandex Station — root / ADB kit (Windows)

Стенд для получения ADB/root на **своей** Яндекс Станции в домашней сети.
Работает на обычном **Windows 10/11 ПК**: поднимает DNS + HTTPS, в ответ на
`/get_sync_info` отдаёт `adbd.remoteActivation=true`, и колонка включает `:5555`.

> ⚠️ Только свои устройства и своя сеть. Сброс снимает привязку аккаунта,
> неудачная прошивка может превратить колонку в кирпич. Всё на свой риск.

---

## Что проверено

| Модель | Статус |
|---|---|
| Yandex Station Lite 1 (`yandexmicro`, YNDX-00025, Amlogic A113X) | ✅ работает |
| Yandex Mini (`yandexmini`, `1.305.4.16.3237824040.20250721`) | ✅ работает |
| Yandex Station Midi (`cucumber`, с часами) | ✅ работает |

- **Мини**: даунгрейд проверен до `1.305.4.16.3237824040.20250721` (ставили с `1.3.4.12…`),
  и уже с этой прошивки включается ADB через `/get_sync_info` → `:5555`.
- На живой колонке: `adb connect <IP>:5555` → `adb shell id` → `uid=0(root)`.

---

## Что нужно (Windows)

1. **Windows 10/11**, права администратора (скрипт сам попросит UAC).
2. **Python 3.8+** с python.org, при установке галочка **Add python.exe to PATH**
   (проверка: `python --version`).
3. **Роутер, где можно вручную поменять DNS** (или раздать этот ПК как DNS по DHCP).
   Это единственное жёсткое требование — железо любое.
4. Свободные порты **53 (UDP/TCP), 80, 443**. На Windows 53 иногда держит
   «Общий доступ к подключению к Интернету (ICS)» — отключи службу.
5. `adb` в PATH или `adb.exe` в папке `tools\` (для `check.ps1`).
6. Колонка в той же сети + физический доступ к ней.

`dnsmasq` не нужен: DNS-сервер встроен в `scripts/equasar_server.py` (`--dns`).

---

## Быстрый старт

Распакуй папку, например в `C:\lite-kit`, и запусти PowerShell от администратора:

```powershell
cd C:\lite-kit
.\start.ps1
```

Скрипт сам:
- проверит порты и права;
- добавит правила firewall для 53/80/443;
- поднимет DNS + HTTPS (`python scripts\equasar_server.py --dns`);
- покажет IP этой машины и проверит, что DNS отвечает.

Дальше:
1. На роутере поставь **DNS = IP этого ПК** (покажет `start.ps1`).
2. Сбрось колонку в factory: выдерни питание → включи → зажми **кнопку паузы**
   (▶/⏸) на ~7–10 с до жёлто-салатового индикатора → дождись Алисы.
3. В приложении «Дом с Алисой» добавь устройство, дойди до выбора Wi-Fi
   и подключи к своей сети (DNS уже указывает на ПК).
4. После синка в `log\server.log` появится
   `>>> [SYNC-REAL→] payload …, adbd: … =on` (или `[SYNC→]`, если Яндекс ответил 429).
5. Проверь ADB:

```powershell
.\check.ps1
# или
adb connect <IP-колонки>:5555
adb shell id
```

Остановить стенд:

```powershell
.\stop.ps1
```
и верни на роутере DNS в «Автоматически».

---

## Прошивка: скачать нужную версию

Скрипт качает прошивку с зеркала и кладёт её в `firmware\<версия>.zip`
(на зеркале файл называется `update.zip` — переименовываем), плюс пишет
`firmware\manifest.json` (version, filename, size, crc32, sha256).

**Интерактивно (меню по цифрам):**

```powershell
.\install-firmware.ps1
# 1) выбрать платформу:  1) bergamot  2) chiron  3) cucumber … 15) yandexmicro …
# 2) выбрать версию:     1) 0.372…  2) 0.369… (проверенная помечена) …
```

**Из CLI — по имени:**

```powershell
.\install-firmware.ps1 -Platform yandexmini -Version 1.305.4.16.3237824040.20250721
```

**Из CLI — по номерам из меню:**

```powershell
.\install-firmware.ps1 -Platform 15 -Version 3
```

Другие параметры:

```powershell
.\install-firmware.ps1 -List                  # только список платформ
.\install-firmware.ps1 -Mirror http://…:62891 # другое зеркало
```

Уже проверенные версии в меню помечены `<-- проверено (ADB работает)`:
`yandexmicro` → `0.369.1.46.4778262442.20261013.297`,
`yandexmini` → `1.305.4.16.3237824040.20250721`.

Старые `.zip` из `firmware\` удаляются, чтобы сервер не взял не тот файл.

### Раздать скачанную прошивку колонке

По умолчанию обновления **выключены** (колонка получает `hasUpdate:false`).
Чтобы предложить прошивку из `firmware\`:

```powershell
New-Item run\downgrade -ItemType File -Force
.\stop.ps1; .\start.ps1
```

В логе: `>>> [DOWNGRADE] Колонке отправлен манифест уязвимой прошивки!` и
`>>> [OTA] файл отдан ПОЛНОСТЬЮ`. Вернуть как было: `Remove-Item run\downgrade`
и перезапуск.

---

## Sync: что отдаётся колонке

- `200` от Яндекса → отдаём **его же ответ** (родные поля модели), но `adbd`
  **перезаписываем** на `true` в `config.system_config`, `config.device_config`,
  `config` и на верхнем уровне;
- `429`/`5xx` → до 3 повторов с паузой 2.5 с, затем локальный шаблон с `adbd`;
- не JSON/обрыв → локальный шаблон с `adbd`.

Колонка **всегда** получает `200`. Подробно — [docs/sync-adb.md](docs/sync-adb.md).

### Лог

`log\server.log`: `<<< [SYNC←]` (что спросила колонка, заголовки) и
`>>> [SYNC→] / [SYNC-REAL→]` (что ушло: размер, источник, состояние `adbd`,
сам JSON). Секреты (`*token*`, `*secret*`, `*private*`, `wifi_hash`, координаты)
заменяются на `<скрыто>`.

---

## Настройки (необязательно)

| Переменная | По умолчанию | Зачем |
|---|---|---|
| `LOCAL_IP` | определяется сам | IP, который колонка получит в манифесте (`fallbackIp`) |
| `COLUMN_IPS` | пусто | IP колонок через запятую, если автоопределение не сработало |
| `SYNC_RETRIES` / `SYNC_RETRY_DELAY` | `3` / `2.5` | повторы при 429/5xx |
| `MIRROR_URL` | `http://144.76.194.29:62891` | зеркало прошивок |

Флаг-файлы (создать пустой файл, потом перезапуск):

- `run\sync_proxy` — sync берётся у Яндекса как есть (с добавлением `adbd`);
- `run\downgrade` — раздавать прошивку из `firmware\`.

---

## Если что-то не так

| Симптом | Что смотреть |
|---|---|
| `start.ps1` просит UAC и закрывается | согласись с UAC; окно откроется заново уже от админа |
| `порт 53 уже занят` | отключи службу ICS / `mDNS`-конфликт, или освободи 53 |
| Колонка «нет интернета» | идут ли `HEAD /generate_204 → 204` в `log\server.log`; DNS на роутере точно на IP ПК |
| Нет `:5555` после ребута | был ли `[SYNC…] … adbd=on`; подожди минуту; проверь `.\check.ps1` |
| `не смог определить IP` | задай явно: `$env:LOCAL_IP="192.168.1.10"; .\start.ps1` |
| `unknown ca` | прошивка не принимает серт — ставь проверенную версию через `install-firmware` |

---

## Linux / macOS (альтернатива)

Там те же возможности скриптами `start.sh` / `stop.sh` / `check.sh` и
`install-firmware.sh`, но вместо встроенного DNS используется `dnsmasq`.

```bash
sudo ./start.sh
./install-firmware.sh          # меню: платформа (цифра) -> версия (цифра)
./install-firmware.sh -p yandexmicro -v 0.369.1.46.4778262442.20261013.297
```

---

## Состав

```
start.ps1 / stop.ps1 / check.ps1        стенд, остановка, поиск колонки (Windows)
install-firmware.ps1                   меню/CLI установки прошивки
start.sh / stop.sh / check.sh          то же для Linux/macOS
install-firmware.sh                    то же для Linux/macOS
scripts/equasar_server.py              DNS + HTTP/HTTPS, sync, OTA
scripts/sync_template.json             локальный шаблон ответа
scripts/test-429.py                    30+ проверок: 429/5xx, повторы, OTA
certs/                                 серты eMudhra (fullchain.pem + ключ)
config/dnsmasq.conf.tpl                шаблон DNS для Linux/macOS
firmware/                              прошивка (<версия>.zip) + manifest.json
```

Прошивка **не входит** в репозиторий — качается `install-firmware.*`.

---

## Сторонние проекты

- **eQuasar** (исходный вектор): https://git.gay/iwakura/eQuasar
- **babybreakfix**: https://github.com/qwikly3/babybreakfix
- **YAM**: https://github.com/nyakokitsu/yam
- Зеркало OTA: `http://144.76.194.29:62891/<platform>/<version>/update.zip`

---

## Лицензия

Код стенда — MIT. Сертификаты и прошивки — собственность правообладателей,
в репозитории только публично известный набор сертов eQuasar и метаданные.
