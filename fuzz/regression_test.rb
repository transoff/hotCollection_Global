# frozen_string_literal: true

# Регрессии по находкам фаззера. Запуск: ruby fuzz/regression_test.rb
require 'json'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
CLI = File.join(ROOT, 'prototype/simple_router/cli.rb')
failures = 0

def check(name)
  ok, detail = yield
  puts(ok ? "OK   #{name}" : "FAIL #{name}: #{detail}")
  ok
end

# Находка 1: очередь не в UTF-8 (например, CP1251 в названии банка) роняла весь
# прогон — JSON.parse отдаёт строку с valid_encoding? == false, дальше strip и
# JSON.generate падают, routing_decisions.json не создаётся вовсе.
failures += 1 unless check('очередь с невалидным UTF-8 обрабатывается') do
  Dir.mktmpdir do |dir|
    queue = File.join(dir, 'queue.json')
    File.binwrite(queue, %([{"operation_id":"op_201","created_at":"2026-07-30T09:05:00+03:00",) +
                         %("amount":15000,"bank":"\xEF\xF0\xE8\xE2\xE5\xF2","card_brand":null}]))
    stdout = `ruby #{CLI} --queue #{queue} --quiet --no-files 2>#{dir}/err`
    next [false, File.read("#{dir}/err").lines.first.to_s.strip] unless $?.success?

    decisions = JSON.parse(stdout)
    [decisions.length == 1 && decisions.first['operation_id'] == 'op_201',
     "получено #{decisions.length} решений"]
  end
end

# Находка 2: одна нечитаемая строка в operations_history.csv роняла весь прогон
# — Float() и Time.iso8601 на мусоре, fetch на отсутствующей колонке. История
# нужна только для калибровки, роутер работает и без неё, так что терять из-за
# неё все решения несоразмерно.
failures += 1 unless check('битая история не мешает выдать решения') do
  Dir.mktmpdir do |dir|
    history = File.join(dir, 'history.csv')
    File.write(history, <<~CSV)
      operation_id,created_at,amount,bank,card_brand,payment_system,status,latency_sec
      op_1,2026-07-29T08:00:00+03:00,НЕ_ЧИСЛО,alfa,,vipay,approved,76
      op_2,вчера,12000,alfa,,vipay,approved,76
      op_3,2026-07-29T08:02:00+03:00,12000,alfa,,vipay,approved,79
    CSV
    stdout = `ruby #{CLI} --queue #{File.join(ROOT, 'data/operations_queue_10.json')} --history #{history} --quiet --no-files 2>#{dir}/err`
    next [false, File.read("#{dir}/err").lines.first.to_s.strip] unless $?.success?

    [JSON.parse(stdout).length == 10, "получено #{JSON.parse(stdout).length} решений вместо 10"]
  end
end

# Критерий 7 ТЗ: файлы должны существовать и иметь правильную структуру, иначе
# считается, что решение не приложено. Очередь берём с граничными суммами и
# банком, которого нет ни у одного провайдера, — такие заявки обязаны получить
# решение через fallback, а не выпасть из ответа.
failures += 1 unless check('произвольная очередь даёт валидные файлы для сдачи') do
  Dir.mktmpdir do |dir|
    queue = [
      { 'operation_id' => 'edge_min', 'amount' => 1000, 'bank' => 'sberbank' },
      { 'operation_id' => 'edge_max', 'amount' => 200_000, 'bank' => 'tinkoff' },
      { 'operation_id' => 'edge_huge', 'amount' => 9_999_999, 'bank' => 'alfa' },
      { 'operation_id' => 'edge_bank', 'amount' => 5000, 'bank' => 'неизвестный_банк' }
    ]
    queue_path = File.join(dir, 'queue.json')
    File.write(queue_path, JSON.generate(queue))
    out = File.join(dir, 'out')
    `ruby #{CLI} --queue #{queue_path} --quiet --output-dir #{out} 2>#{dir}/err`
    next [false, File.read("#{dir}/err").lines.first.to_s.strip] unless $?.success?

    decisions = JSON.parse(File.read(File.join(out, 'routing_decisions_test.json')))
    report = JSON.parse(File.read(File.join(out, 'routing_report_test.json')))

    ids = decisions.map { |d| d['operation_id'] }
    missing = queue.map { |p| p['operation_id'] } - ids
    next [false, "нет решений для #{missing.join(', ')}"] unless missing.empty?

    bad = decisions.reject do |d|
      d['selected_provider'].is_a?(String) &&
        %w[approved rejected expired].include?(d['simulated_result']) &&
        d['attempts'].is_a?(Array) && !d['attempts'].empty? &&
        d['attempts'].all? { |a| a['provider'] && %w[selected skipped].include?(a['decision']) && a['reason'] }
    end
    next [false, "структура решений нарушена: #{bad.map { |d| d['operation_id'] }.join(', ')}"] unless bad.empty?

    required = %w[period total_operations distribution skip_reasons projected_daily_utilization recommendations]
    absent = required - report.keys
    [absent.empty?, "в отчёте нет полей: #{absent.join(', ')}"]
  end
end

puts(failures.zero? ? "\nвсе регрессии пройдены" : "\nпровалено: #{failures}")
exit(failures.zero? ? 0 : 1)
