# frozen_string_literal: true

# Цель: очередь целиком, как на сдаче — несколько разных заявок за один прогон.
# Оракул — RouterRun#validate!, где живут hard-constraints из ТЗ: бюджет не
# перерасходован, дневная экспозиция в пределах лимита, провайдер не повторяется
# в каскаде, fallback стоит последним. Плюс проверка, что решение получила
# каждая заявка: по критерию 7 в ответе должны быть все.
#
# Дневные лимиты провайдеров подменяются фаззером на маленькие. С настоящими
# (3–8 млн против 200 тыс. на заявку) исчерпание требует десятков заявок и
# роняет скорость до пары прогонов в секунду, а логика лимитов при этом та же.
require_relative 'common'

test_one_input = lambda do |data|
  fdp = Ruzzy::FuzzedDataProvider.new(data)

  providers = PROVIDERS.map do |provider|
    next provider if provider['payment_system'] == 'spacepayments'

    provider.merge('daily_amount_limit' => fdp.consume_int_in_range(50_000, 2_000_000))
  end

  # Суммы сразу в рабочем диапазоне провайдеров (limit_amount_min = 1000):
  # с копеечным минимумом все прогоны отсекались hard-constraint'ом и уходили
  # в fallback одним и тем же путём, покрытие не двигалось вовсе.
  queue = Array.new(fdp.consume_int_in_range(1, 6)) do |i|
    fuzz_payment(fdp, "op#{i}").merge('amount' => fdp.consume_int_in_range(100_000, 25_000_000) / 100.0)
  end
  begin
    queue.each { |payment| ProviderState.validate_payment!(payment) }
  rescue ArgumentError
    return 0 # границы суммы проверяет router_harness
  end

  settings = RouterSettings.new('sleep_scale' => 0.0,
                                'budget_pct' => fdp.consume_int_in_range(0, 10_000) / 100.0)

  run = RouterRun.new(providers: providers, payments: queue, history: HISTORY, settings: settings,
                      workers: fdp.consume_int_in_range(1, 4), clock: fuzz_clock(fdp)).run

  missing = queue.map { |payment| payment['operation_id'] }.uniq - run.decisions.map { |d| d[:operation_id] }
  raise "заявки без решения: #{missing.join(', ')}" unless missing.empty?

  0
end

Ruzzy.fuzz(test_one_input)
