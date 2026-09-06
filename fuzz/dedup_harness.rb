# frozen_string_literal: true

# Цель: дедупликация operation_id под несколькими воркерами. Дубли в очереди
# идентичны по данным, поэтому конфликтов быть не должно: любое исключение —
# находка. Оракул — RouterRun#validate! ("Missing or duplicate results") плюс
# проверка счётчика duplicate_requests, которого validate! не касается.
require_relative 'common'

POOL_SIZE = 3

test_one_input = lambda do |data|
  fdp = Ruzzy::FuzzedDataProvider.new(data)

  # Уникальные id по индексу: дубль всегда полная копия, поэтому
  # "Conflicting duplicate" недостижим и не маскирует настоящие ошибки.
  pool = Array.new(POOL_SIZE) { |i| fuzz_payment(fdp, "op#{i}") }
  begin
    pool.each { |payment| ProviderState.validate_payment!(payment) }
  rescue ArgumentError
    return 0 # границы суммы и банка проверяет router_harness, здесь они только шум
  end

  queue = Array.new(fdp.consume_int_in_range(1, 5)) { pool[fdp.consume_int_in_range(0, POOL_SIZE - 1)] }
  workers = fdp.consume_int_in_range(1, 4)

  run = RouterRun.new(providers: PROVIDERS, payments: queue, history: HISTORY, settings: SETTINGS,
                      workers: workers, clock: fuzz_clock(fdp)).run

  unique = queue.map { |payment| payment['operation_id'] }.uniq.length
  duplicates = run.report[:duplicate_requests]
  raise "duplicate_requests=#{duplicates}, ожидалось #{queue.length - unique}" unless duplicates == queue.length - unique

  0
end

Ruzzy.fuzz(test_one_input)
