# После root: Entware и `opkg`

Когда станция уже разлочена, удобно ставить пакеты из Entware (`opkg`).
Но в шелле после джейлбрейка почти всегда висят переменные обвязки:

- `LD_PRELOAD` — хук (shim), который подсовывается всем процессам;
- `LD_LIBRARY_PATH` — путь к библиотекам панели/обвязки.

Из-за них `opkg` грузит чужой libc или хук и падает:
`CANNOT LINK EXECUTABLE`, `Segmentation fault`, иногда просто «opkg: not found».

## Правильная обёртка

```sh
opkg() { PATH="$OPT/bin:$OPT/sbin:$PATH" env -u LD_LIBRARY_PATH -u LD_PRELOAD "$OPKG" "$@"; }
```

Почему так:

- `env -u ...` убирает переменные **только для `opkg`** (текущий шелл и обвязка не трогаются);
- `PATH` оставляем с `$OPT/bin:$OPT/sbin`, чтобы находились `opkg` и его хелперы;
- `LD_LIBRARY_PATH` не нужен: у бинарников Entware свой интерпретатор (`/opt/lib/ld-linux*`),
  он и так ищет библиотеки в `$OPT/lib`;
- `LD_PRELOAD` убирать обязательно — иначе хук ломает `opkg` даже при верном `PATH`.

В обёртке **не** должно быть `LD_LIBRARY_PATH="$OPT/lib"`: на части прошивок это
подмешивает системный libc и снова ломает `opkg`.

## Если после этого «error while loading shared libraries»

Значит конкретной сборке нужны либы Entware явно. Тогда fallback — вернуть
`$OPT/lib`, но `LD_PRELOAD` всё равно снять:

```sh
opkg() {
  PATH="$OPT/bin:$OPT/sbin:$PATH" \
  LD_LIBRARY_PATH="$OPT/lib" \
  env -u LD_PRELOAD "$OPKG" "$@"
}
```

## Куда положить

Чтобы работало в каждом шелле (Entware подхватывает `profile.d`):

```sh
cat > /opt/etc/profile.d/opkg.sh <<'EOF'
opkg() { PATH="$OPT/bin:$OPT/sbin:$PATH" env -u LD_LIBRARY_PATH -u LD_PRELOAD "$OPKG" "$@"; }
EOF
chmod +x /opt/etc/profile.d/opkg.sh
. /opt/etc/profile        # или перезайти в ssh
```

Переменные `$OPT` / `$OPKG` обычно заданы установщиком Entware
(`OPT=/opt`, `OPKG=/opt/bin/opkg`); если нет — пропиши их в том же файле.

## Проверка

```sh
opkg print-architecture
opkg update
opkg install coreutils && echo OK
```

Если всё три команды проходят без `LD_`-ошибок — обёртка работает.

> Проверено на Station Mini 2 (root, Entware): с очисткой `LD_LIBRARY_PATH`
> и `LD_PRELOAD` `opkg` ставит пакеты; с `LD_LIBRARY_PATH=$OPT/lib` и живым
> `LD_PRELOAD` — падает.
