# Фаззинг роутера выплат (Ruzzy)

Coverage-guided фаззинг: libFuzzer мутирует входы и оставляет те, что дошли до
новых веток кода. Оракул — уже существующий `RouterRun#validate!`: он проверяет,
что бюджет не перерасходован, резервы освобождены, лимиты соблюдены, а fallback
стоит последним в каскаде. Поэтому находкой считается не только падение, но и
нарушение любого из этих инвариантов.

## Установка (один раз)

Гем с rubygems **не собирается на macOS**: его `extconf.rb` ищет статическую
`libclang_rt.asan.a`, которой на маке нет, и линкует GNU-флагами `--whole-archive`,
которых не знает `ld64`. Поддержка macOS есть только в `main`. Ставим из исходников:

```bash
brew install llvm ruby          # Apple Clang не содержит libFuzzer

git clone https://github.com/trailofbits/ruzzy.git /tmp/ruzzy-src
cd /tmp/ruzzy-src
gem build ruzzy.gemspec

MAKE="make --environment-overrides V=1" \
CC="$(brew --prefix llvm)/bin/clang" \
CXX="$(brew --prefix llvm)/bin/clang++" \
LDSHARED="$(brew --prefix llvm)/bin/clang -dynamic -bundle -undefined dynamic_lookup" \
LDSHAREDXX="$(brew --prefix llvm)/bin/clang++ -dynamic -bundle -undefined dynamic_lookup" \
    gem install ./ruzzy-0.8.0.gem
```

Проверка:

```bash
ruby -e 'require "ruzzy"; puts File.exist?(Ruzzy::ASAN_PATH)'   # => true
```

**Обязательно Ruby из brew.** Системный `/usr/bin/ruby` защищён SIP, и macOS
вырезает `DYLD_INSERT_LIBRARIES` до старта процесса — фаззер молча останется без
инструментации. По той же причине не работают шимы `rbenv`/`asdf` (они идут через
SIP-защищённый `/usr/bin/env`): либо brew-ruby, либо абсолютный путь к бинарю.

## Запуск

```bash
cd fuzz
export ASAN_OPTIONS="allocator_may_return_null=1:detect_leaks=0:use_sigaltstack=0"

DYLD_INSERT_LIBRARIES=$(ruby -e 'require "ruzzy"; print Ruzzy::ASAN_PATH') \
  ruby tracer.rb corpus \
    -artifact_prefix=findings/ \
    -max_len=64 \
    -max_total_time=1800 \
    -print_final_stats=1
```

- `corpus` — накопленные интересные входы, переиспользуются между запусками.
  Не удаляй: с ним следующий прогон стартует не с нуля.
- `findings/` — сюда падают файлы `crash-*`.
- `-max_len=64` — заявка занимает ~30 байт, длиннее генерировать бессмысленно.
- `-max_total_time` — в секундах. На macOS нет `timeout(1)`, ограничивай только так.

Другой харнесс — через переменную:

```bash
HARNESS=my_harness.rb DYLD_INSERT_LIBRARIES=... ruby tracer.rb corpus
```

## Как читать вывод

```
#1836  NEW    cov: 122 ft: 125 corp: 3/23b exec/s: 61 rss: 126Mb
```

- `cov` — покрытых точек. **Главный показатель.** Растёт → фаззер продвигается.
- `corp: 3/23b` — 3 входа в корпусе. Растёт → находятся новые пути.
- `exec/s` — прогонов в секунду. Ожидай **60–90**: один прогон роутера ~11 мс.
- `NEW` — найден вход с новым покрытием. `pulse` — просто отчёт о живости.

## Когда останавливать

Останавливай по любому из четырёх, в порядке приоритета:

1. **Найден крэш.** libFuzzer сам завершится (`exit 77`) и запишет `findings/crash-*`.
   Чини, добавляй регрессию, запускай снова — это основной рабочий цикл.

2. **Плато покрытия.** Прошло **30 минут**, а `cov:` не вырос и в `corpus/` не
   появилось новых файлов — фаззер исчерпал то, что достаёт текущий харнесс.
   Дальше жечь время бессмысленно: нужен новый харнесс на другую цель, а не
   более долгий прогон.

   Проверить объективно:
   ```bash
   ls corpus | wc -l     # запомни число, сравни через полчаса
   grep -c NEW run.log   # то же самое по логу
   ```

3. **Бюджет времени.** Ночной прогон при 70 exec/s даёт ~1,7 млн выполнений —
   для входа в ~30 байт этого более чем достаточно.

4. **Кончились идеи после плато.** Если новый харнесс писать некогда — останавливай,
   корпус останется и переиспользуется в следующий раз.

Не стоит: гонять сутками «на всякий случай». После плато новые находки даёт
изменение харнесса, а не время.

## Что делать с крэшем

Воспроизвести (мгновенно, без фаззинга):

```bash
DYLD_INSERT_LIBRARIES=$(ruby -e 'require "ruzzy"; print Ruzzy::ASAN_PATH') \
  ruby tracer.rb findings/crash-<hash>
```

Дальше: понять корень (не симптом), починить, дописать проверку в
`regression_test.rb`, перезапустить фаззер.

Игнорируй хвост вывода про `libFuzzer: fuzz target exited` и адреса
`asan_with_fuzzer.dylib` — это как процесс завершился, а не где баг. Реальная
причина — ruby-трейс выше, до строки `==NNNNN== ERROR`.

## Регрессии

```bash
ruby fuzz/regression_test.rb
```

Каждая починенная находка получает сюда проверку, чтобы не вернулась.

## Найденное

### 1. Очередь не в UTF-8 роняла весь прогон

`JSON.parse` не проверяет валидность UTF-8: возвращает строку, у которой
`valid_encoding? == false`. Дальше первый же `strip` или `JSON.generate` падает,
и обработка обрывается — `routing_decisions.json` не создаётся **вообще**.

Достижимо через файл: очередь, сохранённая в CP1251 (обычное дело с русскими
названиями банков), убивает прогон целиком. Цена по критериям — 40 баллов за
отсутствующие файлы.

Починено: `read_utf8` в `cli.rb` заменяет битые байты и предупреждает в stderr.
Заявка обрабатывается, а не теряется.
