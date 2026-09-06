# frozen_string_literal: true

require 'bigdecimal'
require 'csv'
require 'time'

class RouterSettings
  DEFAULTS = {
    'initial_in_progress_mode' => 'queued',
    'budget_pct' => 1.0, 'quantile_groups' => 4, 'calibration_operations' => 100,
    'forecast_operations' => 100, 'prior_strength' => 20.0, 'quality_history_limit' => 2000,
    'forecast_window_sec' => 3600, 'forecast_warmup_sec' => 300, 'forecast_update_sec' => 60,
    'min_conversion' => 0.5, 'max_expected_latency_sec' => 180.0,
    'goal_order' => %w[daily_turnover_min traffic_percentage volume_share_pct],
    'provider_goals' => {}, 'budget_rub' => nil,
    'simulation_size_effect' => 0.15, 'simulation_margin_jitter' => 0.1,
    'sleep_scale' => 0.0001
  }.freeze

  def initialize(overrides = {})
    unknown = overrides.keys - DEFAULTS.keys
    raise ArgumentError, "Unknown settings: #{unknown.join(', ')}" unless unknown.empty?
    @values = DEFAULTS.merge(overrides)
    unless %w[queued reserved].include?(self['initial_in_progress_mode'])
      raise ArgumentError, 'initial_in_progress_mode must be queued or reserved'
    end
    %w[quantile_groups calibration_operations forecast_operations quality_history_limit
       forecast_window_sec forecast_warmup_sec forecast_update_sec].each do |key|
      raise ArgumentError, "#{key} must be a positive integer" unless self[key].is_a?(Integer) && self[key] > 0
    end
    unless self['forecast_update_sec'] <= self['forecast_warmup_sec'] && self['forecast_warmup_sec'] <= self['forecast_window_sec']
      raise ArgumentError, 'forecast intervals must satisfy update <= warmup <= window'
    end
    %w[budget_pct prior_strength min_conversion max_expected_latency_sec simulation_size_effect simulation_margin_jitter sleep_scale].each do |key|
      value = self[key]
      raise ArgumentError, "#{key} must be finite and nonnegative" unless value.is_a?(Numeric) && value.finite? && value >= 0
    end
    raise ArgumentError, 'budget_pct must be <= 100' if self['budget_pct'] > 100
    raise ArgumentError, 'probability/jitter must be <= 1' if %w[min_conversion simulation_size_effect simulation_margin_jitter].any? { |k| self[k] > 1 }
    raise ArgumentError, 'prior_strength must be > 0' unless self['prior_strength'] > 0
    raise ArgumentError, 'goal_order must list each supported goal once' unless self['goal_order'].is_a?(Array) && self['goal_order'].sort == DEFAULTS['goal_order'].sort
    unless self['budget_rub'].nil? || (self['budget_rub'].is_a?(Numeric) && self['budget_rub'].finite? && self['budget_rub'] >= 0)
      raise ArgumentError, 'budget_rub must be nonnegative or null'
    end
  end

  def [](key)
    @values.fetch(key)
  end

  def to_h
    Marshal.load(Marshal.dump(@values))
  end
end

# Прогноз по входящим выплатам, без учёта повторных отправок и скорости обработки.
class FlowForecast
  attr_reader :operations, :received, :closes_at

  def initialize(now, settings)
    @settings = settings
    @started_at = @updated_at = now.to_f
    local = now.getlocal('+03:00')
    @closes_at = Time.new(local.year, local.month, local.day, 0, 0, 0, '+03:00') + 86_400
    @initial = @operations = settings['forecast_operations']
    @prior_rate = @initial / (@closes_at.to_f - @started_at)
    @received = 0
    @buckets = Hash.new(0)
  end

  def record(now)
    @received += 1
    @buckets[now.to_i] += 1
    # Прогноз не может быть меньше уже полученного количества выплат.
    @operations = [@operations, @received].max
    update(now)
  end

  def update(now)
    timestamp = [now.to_f, @closes_at.to_f].min
    elapsed = timestamp - @started_at
    if timestamp >= @closes_at.to_f
      @operations = @received
    elsif elapsed >= @settings['forecast_warmup_sec'] && timestamp - @updated_at >= @settings['forecast_update_sec']
      window = @settings['forecast_window_sec']
      @buckets.delete_if { |second, _| second < timestamp - window }
      observed_seconds = [elapsed, window].min
      # Приор сглаживает первые поступления и короткие всплески.
      rate = (@buckets.values.sum + @prior_rate * window) / (observed_seconds + window)
      @operations = @received + (rate * (@closes_at.to_f - timestamp)).round
    else
      return
    end
    @updated_at = timestamp
  end

  def to_h
    { initial_operations: @initial, operations: @operations, received: @received,
      remaining_operations: [@operations - @received, 0].max,
      observation_started_at: Time.at(@started_at).getlocal('+03:00').iso8601,
      updated_at: Time.at(@updated_at).getlocal('+03:00').iso8601,
      window_sec: @settings['forecast_window_sec'], warmup_sec: @settings['forecast_warmup_sec'],
      update_sec: @settings['forecast_update_sec'], basis: 'unique_ingress_smoothed_window_rate' }
  end
end

module RouterMoney
  def self.cents(rubles)
    (BigDecimal(rubles.to_s) * 100).round(0).to_i
  end

  def self.profit_cents(amount, margin_pct)
    (BigDecimal(amount.to_s) * BigDecimal(margin_pct.to_s)).round(0).to_i
  end

  def self.margin(provider)
    # Комиссии считаются включёнными в маржу.
    provider.fetch('merchant_margin_pct').to_f - provider.fetch('provider_margin_pct').to_f
  end
end

class AmountQuantiles
  attr_reader :boundaries, :sample_size

  def initialize(amounts, groups: 4)
    raise ArgumentError, 'groups must be positive' unless groups.is_a?(Integer) && groups > 0
    values = amounts.sort
    @sample_size = values.length
    @boundaries = if values.empty?
                    []
                  else
                    (1...groups).map { |i| values[(values.length * i.to_f / groups).ceil - 1] }
                               .uniq.reject { |edge| edge >= values.last }
                  end
    @counts = Array.new(self.groups, 0)
    values.each { |amount| @counts[bucket(amount)] += 1 }
  end

  def bucket(amount)
    @boundaries.index { |edge| amount <= edge } || @boundaries.length
  end

  def groups
    @boundaries.length + 1
  end

  def to_h
    { boundaries: boundaries, effective_groups: groups, sample_size: sample_size, calibration_counts: @counts,
      rule: 'nearest_rank_by_count; equal amounts stay together; upper edge inclusive' }
  end
end

# Оценки провайдера по завершённым попыткам и размеру выплаты.
class ProviderMetrics
  attr_reader :events

  def initialize(history, settings)
    @settings = settings
    @events = history.last(settings['quality_history_limit']).map(&:dup)
  end

  def record(event)
    # Окно общее для всех провайдеров и не сбрасывается в полночь.
    @events << event.dup
    @events.shift while @events.length > @settings['quality_history_limit']
  end

  def estimate(provider, amount, quantiles)
    amount_bucket = quantiles.bucket(amount)
    provider_events = @events.select { |event| event['payment_system'] == provider.fetch('payment_system') }
    segment_events = provider_events.select { |event| quantiles.bucket(event.fetch('amount')) == amount_bucket }
    other_events = provider_events - segment_events
    prior_strength = @settings['prior_strength']

    # Приор из каталога сглаживает оценку при малой выборке.
    base_probability = provider.fetch('conversion_24h').to_f
    provider_successes = provider_events.count { |event| event['status'] == 'approved' }
    segment_successes = segment_events.count { |event| event['status'] == 'approved' }
    other_successes = other_events.count { |event| event['status'] == 'approved' }
    global_probability = (provider_successes + prior_strength * base_probability) / (provider_events.length + prior_strength)

    # Исключаем текущий сегмент из его приора, чтобы не учесть события дважды.
    parent_probability = (other_successes + prior_strength * base_probability) / (other_events.length + prior_strength)
    segment_probability = (segment_successes + prior_strength * parent_probability) / (segment_events.length + prior_strength)

    base_latency = provider.fetch('avg_latency_sec', 30).to_f
    other_latency_sum = other_events.sum { |event| event['latency_sec'].to_f }
    segment_latency_sum = segment_events.sum { |event| event['latency_sec'].to_f }
    parent_latency = (other_latency_sum + prior_strength * base_latency) / (other_events.length + prior_strength)
    segment_latency = (segment_latency_sum + prior_strength * parent_latency) / (segment_events.length + prior_strength)

    # Отказы не являются наблюдениями нулевой маржи.
    observed_margins = segment_events.select { |event| event['status'] == 'approved' && event.key?('net_margin_pct') }
    margin_sum = observed_margins.sum { |event| event['net_margin_pct'] }
    margin = (margin_sum + prior_strength * RouterMoney.margin(provider)) / (observed_margins.length + prior_strength)

    { probability: segment_probability, global_probability: global_probability, latency_sec: segment_latency, margin_pct: margin,
      observed_attempts: provider_events.length, segment_attempts: segment_events.length,
      segment_successes: segment_successes, bucket: amount_bucket }
  end

  # Нечитаемая строка истории пропускается, а не роняет прогон: история нужна
  # только для калибровки, и терять из-за неё все решения несоразмерно — без
  # истории роутер работает на априорных оценках.
  def self.load_history(path, before:)
    rows = begin
      CSV.read(path, headers: true).map(&:to_h)
    rescue CSV::MalformedCSVError => error
      STDERR.puts "WARN #{path}: #{error.message.lines.first.to_s.strip}; история не используется"
      []
    end

    seen = {}
    skipped = 0
    parsed = rows.filter_map do |row|
      begin
        next unless %w[approved rejected expired].include?(row['status'])
        next unless Time.iso8601(row.fetch('created_at')) < before

        id = row.fetch('operation_id')
        next if seen[id]

        seen[id] = true
        row.merge('amount' => Float(row.fetch('amount')), 'latency_sec' => Float(row.fetch('latency_sec')))
      rescue ArgumentError, KeyError, TypeError
        skipped += 1
        nil
      end
    end
    STDERR.puts "WARN #{path}: пропущено нечитаемых строк истории: #{skipped}" if skipped.positive?

    parsed.sort_by { |row| Time.iso8601(row['created_at']) }
  end
end

module HardRules
  def self.reasons(payment, provider)
    amount = payment.fetch('amount')
    reasons = []
    reasons << 'provider_inactive' unless provider['status'] == 'active'
    reasons << 'amount_below_min' if provider['limit_amount_min'] && amount < provider['limit_amount_min']
    reasons << 'amount_exceeds_limit' if provider['limit_amount_max'] && amount > provider['limit_amount_max']
    reasons << 'no_available_requisites' if provider['available_requisites'].to_i <= 0
    banks = provider['banks'] || []
    # Пустой список разрешает все банки; exclude_banks инвертирует непустой список.
    if banks.any?
      rejected = provider['exclude_banks'] ? banks.include?(payment['bank']) : !banks.include?(payment['bank'])
      reasons << 'bank_not_supported' if rejected
    end
    reasons << 'negative_margin' if RouterMoney.margin(provider) < 0 && !provider['allow_negative_agreement']
    reasons
  end
end

class RoutingPolicy
  def initialize(settings)
    @settings = settings
  end

  def financial_options(candidates, payment)
    rows = candidates.map do |candidate|
      candidate.merge(income_cents: RouterMoney.profit_cents(payment['amount'], candidate[:margin_pct]))
    end
    # Ожидаемый доход каскада при условно независимых попытках, без fallback.
    rows.map do |first|
      route = [first] + (rows - [first]).sort_by { |r| [-r[:income_cents], r[:latency_sec], r[:provider]] }
      reach = 1.0
      value = latency = 0.0
      route.each do |row|
        value += reach * row[:probability] * row[:income_cents]
        latency += reach * row[:latency_sec]
        reach *= 1 - row[:probability]
      end
      first.merge(expected_profit_cents: value, expected_cascade_latency_sec: latency,
                  external_success_probability: 1 - reach, comparison_tail: route.drop(1).map { |r| r[:provider] })
    end
  end

  def admissible_options(candidates, payment)
    remaining, excluded = candidates.dup, []
    loop do
      rows = financial_options(remaining, payment)
      rejected = rows.select { |row| row[:expected_cascade_latency_sec] > @settings['max_expected_latency_sec'] }
      return [rows, excluded] if rejected.empty?
      names = rejected.map { |row| row[:provider] }
      excluded.concat(names)
      remaining.reject! { |row| names.include?(row[:provider]) }
      # Пересчитываем хвост без исключённых провайдеров.
    end
  end

  def choose(rows, budget_remaining, payment)
    return [nil, []] if rows.empty?
    best = rows.min_by { |r| [-r[:expected_profit_cents], r[:expected_cascade_latency_sec], r[:provider]] }
    rows.each do |row|
      row[:concession_cents] = [(best[:expected_profit_cents] - row[:expected_profit_cents] - 1e-9).ceil, 0].max
      row[:budget_allowed] = row[:concession_cents] <= budget_remaining
    end
    selected = best
    # Цели сравниваются по порядку: уступка допустима только за улучшение цели.
    @settings['goal_order'].each_with_index do |goal, index|
      upgrades = rows.select do |row|
        row[:budget_allowed] && row[:goals][index] > best[:goals][index] + 1e-12 &&
          (0...index).all? { |j| row[:goals][j] >= best[:goals][j] - 1e-12 }
      end
      next if upgrades.empty?
      selected = upgrades.min_by do |row|
        gain = row[:goals][index] - best[:goals][index]
        [row[:concession_cents] / gain, -gain, row[:expected_cascade_latency_sec], row[:provider]]
      end
      selected[:choice_reason] = "soft_goal:#{goal}"
      break
    end
    selected[:choice_reason] ||= 'profit_first'
    # Предпочтение мерчанта разрешает только равенство экономики и целей роутера.
    preferred = payment['preferred_provider']
    tie = rows.find do |row|
      row[:provider] == preferred && row[:concession_cents] == selected[:concession_cents] && row[:goals] == selected[:goals]
    end
    if tie && (tie[:expected_profit_cents] - selected[:expected_profit_cents]).abs < 1e-9
      selected = tie
      selected[:choice_reason] = 'merchant_tie_break'
    end
    ordered = [selected] + (rows - [selected]).sort_by { |r| [-r[:expected_profit_cents], r[:provider]] }
    ordered.each_with_index { |row, index| row[:priority] = index + 1 }
    [selected, ordered]
  end
end
