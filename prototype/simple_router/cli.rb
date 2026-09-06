#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'fileutils'
require 'tmpdir'
require_relative 'harness'

root = File.expand_path('../..', __dir__)

# Входные файлы приходят извне и не обязаны быть в UTF-8: JSON.parse пропускает
# битые байты дальше, а первый же strip/JSON.generate роняет весь прогон. Терять
# все решения из-за одного символа дороже, чем обработать заявку с заменой.
def read_utf8(path)
  raw = File.read(path)
  clean = raw.scrub
  STDERR.puts "WARN #{path}: невалидные байты UTF-8 заменены" unless clean == raw
  clean
end
options = { workers: 4, seed: 8, synthetic: 100, scenario: 'size_sensitive',
            providers: File.join(root, 'data/providers.json'),
            history: File.join(root, 'data/operations_history.csv'),
            settings: File.join(__dir__, 'settings.json'), overrides: {}, quiet: false, files: true }

parser = OptionParser.new do |p|
  p.banner = 'Payout Router — JSON stdout, trace stderr. Defaults: 100 synthetic payouts, 4 quantiles, 1% budget.'
  p.on('-w', '--workers N', Integer, 'Parallel workers (default 4)') { |v| options[:workers] = v }
  p.on('-s', '--seed N', Integer, 'Keyed simulator/input seed (default 8)') { |v| options[:seed] = v }
  p.on('--synthetic N', Integer, 'Synthetic incoming payouts (not N per provider/group)') { |v| options[:synthetic] = v }
  p.on('-q', '--queue FILE', 'Process actual JSON queue instead of synthetic input') { |v| options[:queue] = v }
  p.on('-p', '--providers FILE', 'Provider JSON with a providers array') { |v| options[:providers] = v }
  p.on('--history FILE', 'Known CSV history, strictly before processing start') { |v| options[:history] = v }
  p.on('--settings FILE', 'Configuration JSON; see settings.json') { |v| options[:settings] = v }
  p.on('--budget-pct N', Float, 'Daily modeled concession budget as percent of reference PROFIT') { |v| options[:overrides]['budget_pct'] = v }
  p.on('--budget-rub N', Float, 'Explicit fixed daily ruble budget, overrides percentage') { |v| options[:overrides]['budget_rub'] = v }
  p.on('--quantiles N', Integer, 'Requested equal-count groups; 1 disables segmentation') { |v| options[:overrides]['quantile_groups'] = v }
  p.on('--known-operations N', Integer, 'Historical operations used to fit boundaries (default 100)') { |v| options[:overrides]['calibration_operations'] = v }
  p.on('--forecast-operations N', Integer, 'Initial flow forecast, dynamically updated from unique ingress') { |v| options[:overrides]['forecast_operations'] = v }
  p.on('--forecast-window-sec N', Integer, 'Arrival-rate window and smoothing exposure (default 3600)') { |v| options[:overrides]['forecast_window_sec'] = v }
  p.on('--forecast-warmup-sec N', Integer, 'Minimum observation time before extrapolation (default 300)') { |v| options[:overrides]['forecast_warmup_sec'] = v }
  p.on('--forecast-update-sec N', Integer, 'Minimum time between forecast updates (default 60)') { |v| options[:overrides]['forecast_update_sec'] = v }
  p.on('--sleep-scale N', Float, 'Wall delay / simulated latency; zero for reproducible single-worker comparisons') { |v| options[:overrides]['sleep_scale'] = v }
  p.on('--scenario NAME', 'flat | size_sensitive | degraded | all_reject') { |v| options[:scenario] = v }
  p.on('--start-at ISO8601', 'Simulated processing clock origin; advances with monotonic wall time') { |v| options[:start_at] = v }
  p.on('--output-dir DIR', 'New directory for input, settings, decisions, report and snapshots') { |v| options[:output] = v }
  p.on('--no-files', 'Only JSON stdout; no saved artifacts') { options[:files] = false }
  p.on('--quiet', 'Suppress per-event trace') { options[:quiet] = true }
  p.on('--json', 'Compatibility flag: stdout is always JSON') {}
  p.on('-h', '--help', 'Show help') { puts p; exit }
end

begin
  parser.parse!
  raise ArgumentError, "Unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
  settings = RouterSettings.new(JSON.parse(File.read(options[:settings])).merge(options[:overrides]))
  providers = JSON.parse(read_utf8(options[:providers])).fetch('providers')
  start_at = options[:start_at] ? Time.iso8601(options[:start_at]) : Time.now
  epoch = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  clock = -> { start_at + Process.clock_gettime(Process::CLOCK_MONOTONIC) - epoch }
  history = ProviderMetrics.load_history(options[:history], before: start_at)
  history = history.last(settings['calibration_operations'])
  payments = if options[:queue]
               JSON.parse(read_utf8(options[:queue]))
             else
               SyntheticData.payments(options[:synthetic], history: history, seed: options[:seed], start_at: start_at)
             end
  if options[:output] && File.exist?(options[:output])
    raise ArgumentError, 'Output directory already exists; choose a new one to preserve previous runs'
  end
  run = RouterRun.new(providers: providers, payments: payments, history: history, settings: settings,
                      workers: options[:workers], seed: options[:seed], scenario: options[:scenario],
                      clock: clock, log: options[:quiet] ? nil : STDERR).run
  if options[:files]
    if options[:output]
      output = File.expand_path(options[:output])
      FileUtils.mkdir_p(File.dirname(output))
      Dir.mkdir(output)
    else
      runs = File.join(__dir__, 'runs')
      FileUtils.mkdir_p(runs)
      output = Dir.mktmpdir("run-#{Time.now.strftime('%Y%m%d-%H%M%S')}-", runs)
    end
    artifacts = {
      'routing_decisions_test.json' => run.decisions,
      'routing_report_test.json' => run.report,
      'operations_input.json' => payments,
      'settings_used.json' => settings.to_h,
      'providers_used.json' => { 'providers' => run.state.providers },
      'history_used.json' => history
    }
    artifacts.each { |name, content| File.write(File.join(output, name), JSON.pretty_generate(content) + "\n") }
    snapshots = run.report[:state][:closed_day_snapshots]
    unless snapshots.empty?
      Dir.mkdir(File.join(output, 'snapshots'))
      snapshots.each { |day, snapshot| File.write(File.join(output, 'snapshots', "#{day}.json"), JSON.pretty_generate(snapshot) + "\n") }
    end
    STDERR.puts "ARTIFACTS #{output}"
  end
  STDERR.puts "DONE operations=#{run.decisions.length} peak_parallel=#{run.report[:peak_parallel]} external_profit=#{run.report[:external_profit_rub].round(2)} fallback=#{run.report[:fallback][:count]}"
  STDOUT.puts JSON.pretty_generate(run.decisions)
rescue StandardError => error
  STDERR.puts "ERROR #{error.class}: #{error.message}"
  exit 1
end
