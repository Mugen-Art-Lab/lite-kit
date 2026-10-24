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

## Как получить шаблон (один раз)

Если хотите, чтобы ответ был максимально «родным» для вашей модели:

```bash
cd ~/lite-kit
./stop.sh
SYNC_PROXY=1 sudo ./start.sh      # или: touch run/sync_proxy && ./start.sh
```

Перезагрузите колонку → в логе появится:

```
>>> [DUMP] настоящий ответ сохранён: .../log/sync_real.json (10579b)
```

После этого `log/sync_template.json` создастся автоматически при первом
`/get_sync_info` (или при следующем старте). Дальше диагностика не нужна:

```bash
rm -f run/sync_proxy
./stop.sh && sudo ./start.sh
```

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
