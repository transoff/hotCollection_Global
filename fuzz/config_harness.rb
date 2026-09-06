# frozen_string_literal: true

# Цель: конфигурация провайдеров. providers.json приходит от организаторов, то
# есть это ровно тот же класс входа, что дал находку с не-UTF-8 очередью.
#
# validate_provider_configuration! проверяет знак и конечность чисел, но не
# проверяет согласованность: диапазон сумм может оказаться вывернутым
# (min > max), текущие счётчики (daily_approved_amount, in_progress_*) не
# валидируются вовсе, status и типы banks/exclude_banks — тоже. Сюда и целимся.
#
# Заявки намеренно фиксированные и валидные: меняется только конфиг, чтобы
# находка указывала на него, а не на очередь.
require_relative 'common'

STATUSES = %w[active inactive disabled paused].freeze
BANK_LISTS = [%w[sberbank tinkoff vtb], %w[alfa], [], false, nil].freeze

QUEUE = [
  { 'operation_id' => 'cfg1', 'amount' => 15_000.0, 'bank' => 'sberbank', 'created_at' => START.iso8601 },
  { 'operation_id' => 'cfg2', 'amount' => 48_000.0, 'bank' => 'alfa', 'created_at' => START.iso8601 },
  { 'operation_id' => 'cfg3', 'amount' => 120_000.0, 'bank' => 'tinkoff', 'created_at' => START.iso8601 }
].freeze

test_one_input = lambda do |data|
  fdp = Ruzzy::FuzzedDataProvider.new(data)

  providers = PROVIDERS.map do |provider|
    next provider if provider['payment_system'] == 'spacepayments'

    provider.merge(
      'status' => fdp.pick_value_in_list(STATUSES),
      'limit_amount_min' => fdp.consume_int_in_range(0, 300_000),
      'limit_amount_max' => fdp.consume_int_in_range(0, 300_000),
      'daily_amount_limit' => fdp.consume_int_in_range(0, 5_000_000),
      'daily_approved_amount' => fdp.consume_int_in_range(-1_000_000, 5_000_000),
      'in_progress_count' => fdp.consume_int_in_range(-5, 20),
      'in_progress_count_limit' => fdp.consume_int_in_range(0, 20),
      'in_progress_amount' => fdp.consume_int_in_range(-500_000, 2_000_000),
      'in_progress_amount_limit' => fdp.consume_int_in_range(0, 2_000_000),
      'available_requisites' => fdp.consume_int_in_range(0, 20),
      'requests_per_minute_limit' => fdp.consume_int_in_range(0, 100),
      'priority' => fdp.consume_int_in_range(-5, 10),
      'traffic_percentage' => fdp.consume_int_in_range(0, 100),
      'banks' => fdp.pick_value_in_list(BANK_LISTS),
      'exclude_banks' => fdp.pick_value_in_list(BANK_LISTS)
    )
  end

  begin
    run = RouterRun.new(providers: providers, payments: QUEUE, history: HISTORY, settings: SETTINGS,
                        workers: fdp.consume_int_in_range(1, 4), clock: fuzz_clock(fdp)).run
  rescue ArgumentError
    return 0 # конфиг отвергнут валидатором — это штатное поведение
  end

  missing = QUEUE.map { |payment| payment['operation_id'] } - run.decisions.map { |d| d[:operation_id] }
  raise "заявки без решения: #{missing.join(', ')}" unless missing.empty?

  0
end

Ruzzy.fuzz(test_one_input)
