# frozen_string_literal: true

# Общий сетап харнессов: каталог провайдеров и история читаются один раз,
# дальше каждый прогон отличается только тем, что нагенерил фаззер.
require 'ruzzy'
require_relative '../prototype/simple_router/harness'

ROOT = File.expand_path('..', __dir__)
PROVIDERS = JSON.parse(File.read(File.join(ROOT, 'data/providers.json'))).fetch('providers')
START = Time.iso8601('2026-07-30T12:00:00+03:00')
HISTORY = ProviderMetrics.load_history(File.join(ROOT, 'data/operations_history.csv'), before: START)
SETTINGS = RouterSettings.new('sleep_scale' => 0.0)
BANKS = %w[sberbank alfa tinkoff vtb raiffeisen ozon].freeze

# Часы монотонно идут вперёд с шагом от фаззера: в CLI они тоже монотонные, а
# застывшее время отрезает смену дня, прогноз потока и окно RPM-лимитов.
def fuzz_clock(fdp)
  step = fdp.consume_int_in_range(0, 50_000)
  elapsed = 0
  -> { START + (elapsed += step) }
end

# ponytail: копейки целым числом, чтобы вход переживал проверку "два знака"
# и фаззер тратил бюджет на логику, а не на формат.
#
# Минимум диапазона обязан быть валидной заявкой: на коротких входах, с которых
# libFuzzer начинает, FuzzedDataProvider отдаёт именно минимум. Если он не
# проходит валидацию, отсеивается всё подряд и покрытие не растёт. Границы
# суммы проверяет router_harness, подменяя поле через merge.
def fuzz_payment(fdp, id)
  { 'operation_id' => id,
    'amount' => fdp.consume_int_in_range(1, 200_000_000) / 100.0,
    'bank' => fdp.pick_value_in_list(BANKS),
    'created_at' => START.iso8601 }
end
