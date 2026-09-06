#!/bin/sh
# Запуск фаззера: ./run.sh [харнесс] [секунды]
#   ./run.sh queue_harness.rb 3600
# Корпус и находки — свои для каждого харнесса, корпус переиспользуется.
set -e
cd "$(dirname "$0")"

harness="${1:-router_harness.rb}"
seconds="${2:-1800}"
name=$(basename "$harness" _harness.rb)

mkdir -p "corpus_$name" "findings_$name"

asan=$(ruby -e 'require "ruzzy"; print Ruzzy::ASAN_PATH')

# DYLD_INSERT_LIBRARIES задаётся только команде ruby, а не экспортируется:
# системные бинари (/bin/sh, mkdir) собраны под arm64e, а dylib под arm64,
# и глобальный экспорт роняет их все с "incompatible architecture".
#
# -len_control=0 обязателен: иначе libFuzzer подолгу держит вход на 8 байтах,
# структурированному харнессу этого не хватает даже на первые поля.
# -timeout не добавлять: на macOS он валит прогон по SIGALRM.
exec env \
  ASAN_OPTIONS="allocator_may_return_null=1:detect_leaks=0:use_sigaltstack=0" \
  DYLD_INSERT_LIBRARIES="$asan" \
  HARNESS="$harness" \
  ruby tracer.rb "corpus_$name" \
  -artifact_prefix="findings_$name/" \
  -max_len=128 \
  -len_control=0 \
  -max_total_time="$seconds" \
  -rss_limit_mb=4096
