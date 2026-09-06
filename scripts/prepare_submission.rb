#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'tmpdir'

module Submission
  ROOT = File.expand_path('..', __dir__)
  FILENAMES = %w[routing_decisions_test.json routing_report_test.json].freeze

  def self.prepare(queue:, destination: ROOT, workers: 8, seed: 8, **inputs)
    raise ArgumentError, 'Укажите существующий файл --queue' unless queue && File.file?(queue)
    raise ArgumentError, 'Каталог назначения не существует' unless File.directory?(destination)
    destination = File.expand_path(destination)
    targets = FILENAMES.map { |name| File.join(destination, name) }
    if targets.any? { |path| File.exist?(path) || File.symlink?(path) }
      raise ArgumentError, 'Файлы сдачи уже существуют; сохраните предыдущую версию перед новым запуском'
    end

    # Временные результаты лежат на том же диске, что и файлы сдачи.
    Dir.mktmpdir('.router-submission-', destination) do |temporary|
      output = File.join(temporary, 'run')
      command = [RbConfig.ruby, File.join(ROOT, 'prototype/simple_router/cli.rb'), '--queue', File.expand_path(queue),
                 '--workers', workers.to_s, '--seed', seed.to_s, '--quiet', '--output-dir', output]
      inputs.each { |name, value| command.concat(["--#{name.to_s.tr('_', '-')}", value]) if value }
      stdout, stderr, status = Open3.capture3(*command)
      raise "Ошибка роутинга: #{stderr.strip}" unless status.success?

      decisions = JSON.parse(File.read(File.join(output, FILENAMES.first)))
      report = JSON.parse(File.read(File.join(output, FILENAMES.last)))
      expected_ids = JSON.parse(File.read(queue)).map { |payment| payment.fetch('operation_id') }.uniq.sort
      unless decisions == JSON.parse(stdout) && decisions.map { |row| row.fetch('operation_id') }.sort == expected_ids &&
             report.fetch('total_operations') == decisions.length
        raise 'Решения, исходная очередь и отчёт не согласованы'
      end

      created = []
      begin
        FILENAMES.zip(targets).each do |name, target|
          source = File.join(output, name)
          # link не перезаписывает файл, появившийся после начальной проверки.
          File.link(source, target)
          created << [source, target]
        end
      rescue SystemCallError
        created.each { |source, target| File.unlink(target) if File.exist?(target) && File.identical?(source, target) }
        raise
      end
      { total_operations: decisions.length, files: targets }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { queue: nil }
  parser = OptionParser.new do |parser_options|
    parser_options.banner = 'Подготовка двух JSON-файлов сдачи из указанной очереди; существующие файлы не перезаписываются.'
    parser_options.on('--queue FILE', 'Входная очередь JSON (обязательно)') { |value| options[:queue] = value }
    parser_options.on('--destination DIR', 'Каталог сдачи; по умолчанию корень проекта') { |value| options[:destination] = value }
    parser_options.on('--workers N', Integer, 'Количество потоков (8)') { |value| options[:workers] = value }
    parser_options.on('--seed N', Integer, 'Seed симулятора (8)') { |value| options[:seed] = value }
    %w[providers history settings start-at].each do |name|
      parser_options.on("--#{name} VALUE") { |value| options[name.tr('-', '_').to_sym] = value }
    end
    parser_options.on('-h', '--help') { puts parser_options; exit }
  end

  begin
    parser.parse!
    raise ArgumentError, "Неизвестные аргументы: #{ARGV.join(' ')}" unless ARGV.empty?
    puts JSON.pretty_generate(Submission.prepare(**options))
  rescue StandardError => error
    warn "ERROR #{error.class}: #{error.message}"
    exit 1
  end
end
