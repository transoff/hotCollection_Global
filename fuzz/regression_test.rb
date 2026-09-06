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

puts(failures.zero? ? "\nвсе регрессии пройдены" : "\nпровалено: #{failures}")
exit(failures.zero? ? 0 : 1)
