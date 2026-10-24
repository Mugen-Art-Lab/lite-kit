# Sync с ADB для всех моделей

Стенд больше **не проксирует** `/get_sync_info` в Яндекс (из-за этого прилетал
`429 Too Many Requests` и активация зависела от доступности API). Теперь ответ
собирается локально и одинаково подходит для Lite, Midi и Mini.

## Как это работает

1. Берётся **шаблон** ответа:
   - `scripts/sync_template.json` — базовый, от «обычных» станций (Lite/Midi), лежит в репозитории;
   - иначе `log/sync_template.json` — свой сгенерированный;
   - дамп `log/sync_real.json` используется **только** с `USE_SYNC_DUMP=1`
     (нужен, если хотите повторить ответ конкретной модели, например Mini);
   - если шаблона нет вовсе — минимальный встроенный ответ.
   По умолчанию Mini-дамп **не** подмешивается.
2. Из шаблона **вырезается приватное**:
   - `glagol.security` (локальный сертификат и приватный ключ станции);
   - `config.account_config.user_wifi_config` (хеш Wi-Fi);
   - `config.device_config.location` (координаты).
3. В ответ вписывается ADB:
   ```json
   "adbd": {"remoteActivation": true, "network": true, "fullDurationMs": 31536000000}
   ```
   сразу в `config.system_config`, `config.device_config`, `config` и на верхний уровень —
   чтобы сработало на любой ветке прошивки.
4. Служебные `POST /set_device_capability` и `/update_device_state` для колонки
   тоже отвечаются локально (`{"status":"ok"}`) — больше никаких 429.
5. Если Яндекс отвечает `429`/`5xx` на любой **другой** запрос колонки, ошибка
   не пробрасывается: sync-пути получают локальный конфиг с `adbd`, остальные —
   `200 {"status":"ok"}`. То есть колонка в любом случае видит успешный синк.

## Настоящий ответ Яндекса + ADB (рекомендуется)

Режим `SYNC_PROXY`: sync **проксируется в Яндекс**, в полученный ответ вписывается
`adbd`, и колонка получает родной ответ для своей модели (со всеми её полями).

```bash
cd ~/lite-kit
./stop.sh
touch run/sync_proxy && sudo ./start.sh   # или: SYNC_PROXY=1 sudo ./start.sh
```

- `200` от Яндекса → отдаём его же + `adbd` во всех ветках;
- `429`/`5xx` → до `SYNC_RETRIES` попыток (по умолчанию 3) с паузой `SYNC_RETRY_DELAY`
  (по умолчанию 2.5 с); если всё равно лимит — локальный шаблон с `adbd`;
- не JSON/обрыв → локальный шаблон с `adbd` (колонка всё равно видит `200`);
- сырой ответ **не сохраняется**. Нужен дамп — запусти с `DUMP_SYNC=1`
  (в нём приватные поля станции — файл не коммитить и не выкладывать).

Выключить и вернуться к чистому локальному шаблону:

```bash
rm -f run/sync_proxy
./stop.sh && sudo ./start.sh
```

## Что видно в логе

На каждый sync пишется и запрос, и то, что уходит колонке:

```
<<< [SYNC←] GET /get_sync_info?device_id=…&platform=yandexmini от 192.168.0.171
    заголовки: User-Agent: …; Accept: …
>>> [SYNC-REAL→] payload 10846b, источник: настоящий ответ Яндекса, adbd: config.system_config.adbd=on, config.device_config.adbd=on, config.adbd=on, top.adbd=on
    {"status":"ok","config":{...}}      ← тела целиком, секреты заменены на <скрыто>
```

Маскируются: `*token*`, `*secret*`, `*password*`, `*private*`, `*auth*`, `*cookie*`,
`wifi_hash`, `latitude`, `longitude`, `certificate`.

## Проверка

```bash
curl -k -s -H "Host: quasar.yandex.net" \
  "https://127.0.0.1/get_sync_info?device_id=test&platform=yandexmini" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);\
print('adbd:', d['config']['system_config']['adbd']);\
print('секреты вырезаны:', 'glagol' not in d and 'user_wifi_config' not in d['config']['account_config'])"
```

Ожидаемо: `adbd` с `remoteActivation: True`, секретов нет.

## Важно

- `log/sync_real.json` содержит приватный ключ станции — **не коммитить** и не выкладывать.
  В шаблон он не попадает (вырезается).
- Локальный sync включает ADB на прошивках, которые читают это поле (Lite проверено).
  На Mini `1.369.x` поле игнорируется — там ADB так не включить, см.
  [mini-downgrade.md](mini-downgrade.md).
