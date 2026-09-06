# frozen_string_literal: true

# Цель: одна заявка проходит весь роутинг. Оракул — RouterRun#validate!,
# который уже проверяет бюджет, лимиты, освобождение резервов и позицию
# fallback в каскаде. Всё, что не ArgumentError из входной валидации, — находка.
require 'ruzzy'
require_relative '../prototype/simple_router/harness'

ROOT = File.expand_path('..', __dir__)
PROVIDERS = JSON.parse(File.read(File.join(ROOT, 'data/providers.json'))).fetch('providers')
START = Time.iso8601('2026-07-30T12:00:00+03:00')
HISTORY = ProviderMetrics.load_history(File.join(ROOT, 'data/operations_history.csv'), before: START)
SETTINGS = RouterSettings.new('sleep_scale' => 0.0)

BANKS = %w[sberbank alfa tinkoff vtb raiffeisen ozon].freeze
PROVIDER_NAMES = ['vipay', 'payflow', 'quickpay', 'spacepayments', 'нет такого', nil].freeze
DATES = [nil, '2026-07-30T11:59:00+03:00', '2026-07-30T12:00:00+03:00', '2026-07-30T12:00:01+03:00'].freeze

test_one_input = lambda do |data|
  fdp = Ruzzy::FuzzedDataProvider.new(data)
  payment = {
    # scrub повторяет то, что CLI делает при чтении файла: дальше по коду
    # строка всегда валидна в UTF-8, невалидные байты — забота границы.
    'operation_id' => fdp.consume_random_length_string(16).force_encoding('UTF-8').scrub,
    # ponytail: копейки целым числом, чтобы вход переживал проверку "два знака"
    # и фаззер тратил бюджет на логику, а не на формат. Дробные суммы — отдельный харнесс.
    'amount' => fdp.consume_int_in_range(-100_000, 200_000_000) / 100.0,
    'bank' => fdp.pick_value_in_list(BANKS),
    'created_at' => fdp.pick_value_in_list(DATES),
    'preferred_provider' => fdp.pick_value_in_list(PROVIDER_NAMES)
  }

  begin
    ProviderState.validate_payment!(payment)
  rescue ArgumentError
    return 0 # вход отвергнут валидатором — это штатное поведение, а не баг
  end

  RouterRun.new(providers: PROVIDERS, payments: [payment], history: HISTORY,
                settings: SETTINGS, workers: 1, clock: -> { START }).run
  0
end

Ruzzy.fuzz(test_one_input)
