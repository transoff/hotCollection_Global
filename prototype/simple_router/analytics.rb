# frozen_string_literal: true

require 'bigdecimal'
require 'csv'
require 'time'

class RouterSettings
  DEFAULTS = {
    'budget_pct' => 1.0, 'quantile_groups' => 4, 'calibration_operations' => 100,
    'forecast_operations' => 100, 'prior_strength' => 20.0, 'quality_history_limit' => 2000,
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
    %w[quantile_groups calibration_operations forecast_operations quality_history_limit].each do |key|
      raise ArgumentError, "#{key} must be a positive integer" unless self[key].is_a?(Integer) && self[key] > 0
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

module RouterMoney
  def self.cents(rubles)
    (BigDecimal(rubles.to_s) * 100).round(0).to_i
  end

  def self.profit_cents(amount, margin_pct)
    (BigDecimal(amount.to_s) * BigDecimal(margin_pct.to_s)).round(0).to_i
  end

  def self.margin(provider)
    # Explicit MWE assumption, consistent with the brief's negative-margin filter.
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

class ProviderMetrics
  attr_reader :events

  def initialize(history, settings)
    @settings = settings
    @events = history.last(settings['quality_history_limit']).map(&:dup)
  end

  def record(event)
    @events << event.dup
    @events.shift while @events.length > @settings['quality_history_limit']
  end

  def estimate(provider, amount, quantiles)
    rows = @events.select { |row| row['payment_system'] == provider.fetch('payment_system') }
    segment = rows.select { |row| quantiles.bucket(row.fetch('amount')) == quantiles.bucket(amount) }
    other = rows - segment
    prior = @settings['prior_strength']
    base_p = provider.fetch('conversion_24h').to_f
    global_p = (rows.count { |r| r['status'] == 'approved' } + prior * base_p) / (rows.length + prior)
    # Leave this segment out of its prior to avoid counting it twice.
    parent_p = (other.count { |r| r['status'] == 'approved' } + prior * base_p) / (other.length + prior)
    p = (segment.count { |r| r['status'] == 'approved' } + prior * parent_p) / (segment.length + prior)
    base_latency = provider.fetch('avg_latency_sec', 30).to_f
    parent_latency = (other.sum { |r| r['latency_sec'].to_f } + prior * base_latency) / (other.length + prior)
    latency = (segment.sum { |r| r['latency_sec'].to_f } + prior * parent_latency) / (segment.length + prior)
    observed = segment.select { |r| r['status'] == 'approved' && r.key?('net_margin_pct') }
    margin = (observed.sum { |r| r['net_margin_pct'] } + prior * RouterMoney.margin(provider)) / (observed.length + prior)
    { probability: p, global_probability: global_p, latency_sec: latency, margin_pct: margin,
      observed_attempts: rows.length, segment_attempts: segment.length,
      segment_successes: segment.count { |r| r['status'] == 'approved' }, bucket: quantiles.bucket(amount) }
  end

  def self.load_history(path, before:)
    seen = {}
    CSV.read(path, headers: true).map(&:to_h).select do |row|
      valid = Time.iso8601(row.fetch('created_at')) < before && %w[approved rejected expired].include?(row['status'])
      id = row.fetch('operation_id')
      valid && !seen[id] && (seen[id] = true)
    end.map do |row|
      row.merge('amount' => Float(row.fetch('amount')), 'latency_sec' => Float(row.fetch('latency_sec')))
    end.sort_by { |row| Time.iso8601(row['created_at']) }
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
    # V(first + income-sorted tail). Independent conditional attempts are a TEST MODEL.
    # This is not an exact daily optimizer under changing capacity and future traffic.
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
      # Reprice the tail after exclusions; never score an already excluded provider.
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
    # Explicit lexicographic goals. Pay only for an improvement over the profit-first choice.
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
    # Merchant preferences can only break an exact economic/router-goal tie.
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
