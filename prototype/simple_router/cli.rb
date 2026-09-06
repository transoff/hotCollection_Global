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

options = { workers: 8, seed: 8, synthetic: 100, scenario: 'size_sensitive',
            arrival_mode: 'created_at', arrival_profile: 'steady', arrival_interval_sec: 5.0,
            providers: File.join(root, 'data/providers.json'),
            history: File.join(root, 'data/operations_history.csv'),
            settings: File.join(__dir__, 'settings.json'), overrides: {}, quiet: false, files: true }

parser = OptionParser.new do |p|
  p.banner = 'Payout Router — JSON stdout, trace stderr. Defaults: 100 synthetic payouts, 4 quantiles, 1% budget.'
  p.on('-w', '--workers N', Integer, 'Parallel workers (default 8)') { |v| options[:workers] = v }
  p.on('-s', '--seed N', Integer, 'Keyed simulator/input seed (default 8)') { |v| options[:seed] = v }
  p.on('--synthetic N', Integer, 'Synthetic incoming payouts (not N per provider/group)') { |v| options[:synthetic] = v }
  p.on('-q', '--queue FILE', 'Process actual JSON queue instead of synthetic input') { |v| options[:queue] = v }
  p.on('-p', '--providers FILE', 'Provider JSON with a providers array') { |v| options[:providers] = v }
  p.on('--history FILE', 'Known CSV history, strictly before processing start') { |v| options[:history] = v }
  p.on('--settings FILE', 'Configuration JSON; see settings.json') { |v| options[:settings] = v }
  p.on('--initial-in-progress-mode MODE', 'queued: unassigned snapshot aggregates; reserved: assigned provider load') { |v| options[:overrides]['initial_in_progress_mode'] = v }
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
  p.on('--arrival-mode MODE', 'created_at replays arrivals; batch makes the whole input available now') { |v| options[:arrival_mode] = v }
  p.on('--arrival-profile PROFILE', 'Synthetic arrival profile: steady (default), batch, burst, pause') { |v| options[:arrival_profile] = v }
  p.on('--arrival-interval-sec N', Float, 'Synthetic interarrival seconds (default 5); not a measured traffic rate') { |v| options[:arrival_interval_sec] = v }
  p.on('--start-at ISO8601', 'Processing origin (default providers.snapshot_at, else now); cannot precede snapshot') { |v| options[:start_at] = v }
  p.on('--output-dir DIR', 'New directory for input, settings, decisions, report and snapshots') { |v| options[:output] = v }
  p.on('--no-files', 'Only JSON stdout; no saved artifacts') { options[:files] = false }
  p.on('--quiet', 'Suppress per-event trace') { options[:quiet] = true }
  p.on('-h', '--help', 'Show help') { puts p; exit }
end

begin
  parser.parse!
  raise ArgumentError, "Unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
  settings = RouterSettings.new(JSON.parse(read_utf8(options[:settings])).merge(options[:overrides]))
  catalog = JSON.parse(read_utf8(options[:providers]))
  providers = catalog['providers']
  unless providers.is_a?(Array) && !providers.empty?
    raise ArgumentError, "#{options[:providers]}: ожидался объект с непустым массивом providers"
  end
  snapshot_at = catalog['snapshot_at'] && Time.iso8601(catalog['snapshot_at'])
  start_at = options[:start_at] ? Time.iso8601(options[:start_at]) : (snapshot_at || Time.now)
  raise ArgumentError, 'Processing cannot start before snapshot' if snapshot_at && start_at < snapshot_at
  history = ProviderMetrics.load_history(options[:history], before: start_at)
  history = history.last(settings['calibration_operations'])
  payments = if options[:queue]
               JSON.parse(read_utf8(options[:queue]))
             else
               SyntheticData.payments(options[:synthetic], history: history, seed: options[:seed], start_at: start_at,
                 arrival_profile: options[:arrival_profile], arrival_interval_sec: options[:arrival_interval_sec])
             end
  if options[:arrival_mode] == 'created_at' && settings['sleep_scale'].zero? &&
     payments.any? { |p| p['created_at'] && Time.iso8601(p['created_at']) > start_at }
    raise ArgumentError, 'Timed arrivals require positive sleep_scale; use --arrival-mode batch for a zero-delay batch'
  end
  scale = settings['sleep_scale'] > 0 ? settings['sleep_scale'] : 1.0
  clock = SimulationClock.new(start_at, scale: scale)
  if options[:output] && File.exist?(options[:output])
    raise ArgumentError, 'Output directory already exists; choose a new one to preserve previous runs'
  end
  run = RouterRun.new(providers: providers, payments: payments, history: history, settings: settings,
                      workers: options[:workers], seed: options[:seed], scenario: options[:scenario],
                      clock: clock, arrival_mode: options[:arrival_mode], wait_until: clock.method(:wait_until),
                      snapshot_at: snapshot_at,
                      log: options[:quiet] ? nil : STDERR).run
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
      'providers_used.json' => catalog.merge('providers' => run.state.providers,
        'snapshot_at' => catalog['snapshot_at'] || run.report[:state][:initial_state][:snapshot_at]),
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
