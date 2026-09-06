# frozen_string_literal: true

require 'json'
require 'thread'
require 'zlib'
require_relative 'analytics'

# Общее состояние провайдеров для воркеров одного процесса.
class ProviderState
  attr_reader :settings, :providers

  def initialize(providers, settings: RouterSettings.new, history: [], clock: -> { Time.now })
    @settings = settings
    @clock = clock
    @providers = copy(providers) # Настройки целей не должны менять исходный каталог.
    validate_provider_configuration!
    @by_name = @providers.each_with_object({}) do |provider, index|
      index[provider['payment_system']] = provider
    end

    @mutex = Mutex.new
    @changed = ConditionVariable.new
    @jobs = {}      # Одна выплата на operation_id; дубли ждут общий результат.
    @active = {}    # Незавершённые попытки, удерживающие лимиты провайдеров.
    @finished = {}  # Учтённые результаты попыток: защита от повторного завершения.
    @days = {}      # Учёт по дню резервирования, включая поздние корректировки.
    @snapshots = {} # Неизменяемые снимки дней на момент их закрытия.
    @rpm = Hash.new { |timestamps, name| timestamps[name] = [] }

    # История обучает оценщик, но не заполняет дневной оборот.
    initial_time = @clock.call
    known_history = history.select { |row| !row['created_at'] || Time.iso8601(row['created_at']) < initial_time }
                           .select { |row| %w[approved rejected expired].include?(row['status']) }
                           .uniq { |row| row['operation_id'] }
    @metrics = ProviderMetrics.new(known_history, settings)
    @calibration = known_history.last(settings['calibration_operations']).map(&:dup)
    @policy = RoutingPolicy.new(settings)
    @version = 0
    @peak_parallel = 0
    ensure_day(initial_time)
  end

  def self.validate_payment!(payment)
    raise ArgumentError, 'Payment must be an object' unless payment.is_a?(Hash)
    id, amount, bank = payment.values_at('operation_id', 'amount', 'bank')
    raise ArgumentError, 'operation_id must be nonempty string' unless id.is_a?(String) && !id.strip.empty?
    raise ArgumentError, 'amount must be finite and positive (>= 0.01)' unless amount.is_a?(Numeric) && amount.finite? && amount >= 0.01
    raise ArgumentError, 'amount must have at most two decimal places' unless (BigDecimal(amount.to_s) * 100).frac.zero?
    raise ArgumentError, 'bank must be nonempty string' unless bank.is_a?(String) && !bank.strip.empty?
    Time.iso8601(payment['created_at']) if payment['created_at']
    true
  end

  # Поступление регистрируется до очереди; повторные отправки не увеличивают входящий поток.
  def receive(payment)
    self.class.validate_payment!(payment)
    @mutex.synchronize do
      id = payment.fetch('operation_id')
      existing = @jobs[id]
      if existing
        raise ArgumentError, "operation_id conflict: #{id}" unless existing[:payment] == payment
        return
      end
      now = @clock.call
      day = ensure_day(now, refresh: false)
      @jobs[id] = { payment: copy(payment), accepted_day: day[:id], running: false }
      day[:received] += 1
      day[:queued] += 1
      day[:flow].record(now)
      refresh_forecast(day, now)
      @calibration << payment.dup
      @calibration.shift while @calibration.length > settings['calibration_operations']
    end
    nil
  end

  # Дубли operation_id ждут результат первого исполнителя.
  def run_once(payment)
    receive(payment)
    id = payment.fetch('operation_id')
    owner = false
    @mutex.synchronize do
      existing = @jobs[id]
      if existing[:running]
        @changed.wait(@mutex) until existing[:result] || existing[:error]
        raise existing[:error] if existing[:error]
        return copy(existing[:result])
      end
      existing[:running] = true
      @days.fetch(existing[:accepted_day])[:queued] -= 1
      owner = true
    end
    result = yield
    @mutex.synchronize do
      @jobs[id][:result] = copy(result)
      @changed.broadcast
    end
    result
  rescue StandardError => error
    if owner
      @mutex.synchronize do
        @jobs[id][:error] = error
        @changed.broadcast
      end
    end
    raise
  end

  # Выбор и резерв неделимы для других воркеров; ожидание ответа — вне Mutex.
  def reserve_next(payment, excluded)
    @mutex.synchronize do
      now = @clock.call
      day = ensure_day(now)
      skipped, candidates = [], []
      @providers.each do |provider|
        name = provider['payment_system']
        next if name == 'spacepayments' || excluded.include?(name)
        reasons = HardRules.reasons(payment, provider) + capacity_reasons(provider, payment['amount'], day, now)
        estimate = @metrics.estimate(provider, payment['amount'], day[:quantiles])
        reasons << 'conversion_below_quality_floor' if estimate[:probability] < settings['min_conversion']
        if reasons.any?
          skipped << { provider: name, decision: 'skipped', reason: reasons.first, details: reasons.join(', ') }
          reasons.each { |reason| day[:providers][name][:reasons][reason] += 1 }
        else
          candidates << estimate.merge(provider: name)
        end
      end
      rows, quality_excluded = @policy.admissible_options(candidates, payment)
      quality_excluded.each do |name|
        skipped << { provider: name, decision: 'skipped', reason: 'expected_latency_above_quality_limit' }
        day[:providers][name][:reasons]['expected_latency_above_quality_limit'] += 1
      end
      rows.each { |row| row[:goals] = goal_values(@by_name[row[:provider]], row, payment, day, now) }
      selected, ranking = @policy.choose(rows, day[:budget_limit_cents] - day[:budget_spent_cents], payment)
      ranking.each do |row|
        day[:providers][row[:provider]][:reasons]['budget_insufficient_for_concession'] += 1 unless row[:budget_allowed]
      end
      selected ||= { provider: 'spacepayments', concession_cents: 0, probability: 1.0,
                     choice_reason: 'eligible_pool_exhausted', bucket: day[:quantiles].bucket(payment['amount']) }
      name = selected[:provider]
      key = JSON.generate([payment.fetch('operation_id'), name])
      raise 'Repeated logical attempt' if @active.key?(key) || @finished.key?(key)
      # Уступка учитывает принятое решение и не возвращается при отказе.
      day[:budget_spent_cents] += selected[:concession_cents]
      @rpm[name].reject! { |timestamp| timestamp <= now.to_f - 60 }
      @rpm[name] << now.to_f
      token = { key: key, operation_id: payment['operation_id'], provider: name,
                day_id: day[:id], amount_cents: RouterMoney.cents(payment['amount']),
                probability: selected[:probability], selection: copy(selected),
                metrics_version: @version, quantile_version: day[:id], started_at: now.iso8601,
                skipped: skipped, ranking: copy(ranking) }
      @active[key] = token
      @peak_parallel = [@peak_parallel, @active.length].max
      stats = day[:providers][name]
      stats[:sent] += 1
      stats[:peak_active_count] = [stats[:peak_active_count], exposure(name)[:count]].max
      stats[:peak_exposure_cents] = [stats[:peak_exposure_cents], stats[:approved_cents] + exposure(name)[:amount]].max
      @version += 1
      copy(token)
    end
  end

  def finish(token, payment, outcome)
    @mutex.synchronize do
      return copy(@finished[token[:key]]) if @finished.key?(token[:key])
      active = @active.fetch(token[:key])
      raise 'Attempt/payment mismatch' unless active[:operation_id] == payment['operation_id'] && active[:amount_cents] == RouterMoney.cents(payment['amount'])
      status = outcome.fetch(:status)
      raise ArgumentError, 'Only approved/rejected/expired are supported' unless %w[approved rejected expired].include?(status)
      latency = outcome.fetch(:latency_sec)
      raise ArgumentError, 'Invalid latency' unless latency.is_a?(Numeric) && latency.finite? && latency >= 0
      raise 'Fallback must approve in this simulator contract' if active[:provider] == 'spacepayments' && status != 'approved'
      margin = status == 'approved' ? outcome.fetch(:net_margin_pct) : 0.0
      raise ArgumentError, 'Invalid margin' unless margin.is_a?(Numeric) && margin.finite?
      now = @clock.call
      ensure_day(now)
      # Учёт относится ко дню резерва; поздний исход не перезаписывает закрытый снимок.
      day = @days.fetch(active[:day_id])
      stats = day[:providers][active[:provider]]
      stats[:completed] += 1
      stats[status.to_sym] += 1
      stats[:latency_sum_sec] += latency
      profit = status == 'approved' ? RouterMoney.profit_cents(payment['amount'], margin) : 0
      if status == 'approved'
        stats[:approved_cents] += active[:amount_cents]
        stats[:profit_cents] += profit
      else
        stats[:reasons][status] += 1
      end
      @active.delete(token[:key])
      # Качество учитывает все завершения, деньги — только approved.
      event = { 'operation_id' => payment['operation_id'], 'payment_system' => active[:provider],
                'amount' => payment['amount'], 'bank' => payment['bank'], 'status' => status,
                'latency_sec' => latency, 'created_at' => now.iso8601 }
      event['net_margin_pct'] = margin if status == 'approved'
      @metrics.record(event)
      @version += 1
      result = { status: status, profit_cents: profit, net_margin_pct: status == 'approved' ? margin : nil,
                 metrics_version: @version, approved_amount: stats[:approved_cents] / 100.0,
                 probability: @metrics.estimate(@by_name[active[:provider]], payment['amount'], day[:quantiles])[:probability] }
      if @snapshots.key?(day[:id])
        day[:corrections] << { attempt_id: token[:key], applied_at: now.iso8601, result: result }
      end
      @finished[token[:key]] = copy(result)
      result
    end
  end

  def snapshot
    @mutex.synchronize do
      ensure_day(@clock.call)
      copy({ current_day: @current_day, version: @version, peak_parallel: @peak_parallel,
             active_attempts: @active.values, days: @days.transform_values { |day| export_day(day) },
             closed_day_snapshots: @snapshots })
    end
  end

  private

  def validate_provider_configuration!
    names = @providers.map { |provider| provider.fetch('payment_system') }
    unless names.uniq == names && names.include?('spacepayments')
      raise ArgumentError, 'Provider names must be unique; spacepayments is required'
    end

    goals = settings['provider_goals']
    unless goals.is_a?(Hash) && (goals.keys - names).empty?
      raise ArgumentError, 'provider_goals must reference configured providers'
    end

    @providers.each do |provider|
      name = provider.fetch('payment_system')
      provider.merge!(goals.fetch(name, {})) unless name == 'spacepayments'

      %w[conversion_24h merchant_margin_pct provider_margin_pct].each do |field|
        value = provider[field]
        raise ArgumentError, "#{name}.#{field} must be finite" unless value.is_a?(Numeric) && value.finite?
      end
      raise ArgumentError, 'conversion_24h must be in 0..1' unless (0..1).cover?(provider['conversion_24h'])

      %w[limit_amount_min limit_amount_max daily_amount_limit daily_turnover_max daily_turnover_min
         in_progress_count_limit in_progress_amount_limit requests_per_minute_limit available_requisites
         traffic_percentage volume_share_pct avg_latency_sec].each do |field|
        value = provider[field]
        unless value.nil? || (value.is_a?(Numeric) && value.finite? && value >= 0)
          raise ArgumentError, "#{name}.#{field} must be nonnegative"
        end
      end
      %w[traffic_percentage volume_share_pct].each do |field|
        raise ArgumentError, "#{field} must be <= 100" if provider[field] && provider[field] > 100
      end
    end
  end

  def copy(value)
    Marshal.load(Marshal.dump(value))
  end

  # Резервы удерживают полную сумму, включая попытки предыдущего дня.
  def exposure(name)
    active = @active.values.select { |row| row[:provider] == name }
    { count: active.length, amount: active.sum { |row| row[:amount_cents] },
      expected_count: active.sum { |row| row[:probability] },
      expected_amount: active.sum { |row| row[:probability] * row[:amount_cents] } }
  end

  def daily_limit(provider)
    [provider['daily_amount_limit'], provider['daily_turnover_max']].compact.min
  end

  def capacity_reasons(provider, amount, day, now)
    name = provider['payment_system']
    reserved = exposure(name)
    requested_cents = RouterMoney.cents(amount)
    reasons = []
    limit = daily_limit(provider)
    daily_exposure_cents = day[:providers][name][:approved_cents] + reserved[:amount] + requested_cents
    active_count_after_send = reserved[:count] + 1
    active_amount_after_send = reserved[:amount] + requested_cents
    reasons << 'daily_amount_limit' if limit && daily_exposure_cents > RouterMoney.cents(limit)
    reasons << 'in_progress_count_limit' if provider['in_progress_count_limit'] && active_count_after_send > provider['in_progress_count_limit']
    reasons << 'in_progress_amount_limit' if provider['in_progress_amount_limit'] && active_amount_after_send > RouterMoney.cents(provider['in_progress_amount_limit'])
    reasons << 'no_available_requisites' if active_count_after_send > provider['available_requisites'].to_i
    # RPM считает отправки, а не успехи.
    @rpm[name].reject! { |timestamp| timestamp <= now.to_f - 60 }
    reasons << 'requests_per_minute_limit' if provider['requests_per_minute_limit'] && @rpm[name].length >= provider['requests_per_minute_limit']
    reasons
  end

  def ensure_day(now, refresh: true)
    # Новые сутки MSK не сбрасывают активные резервы и историю качества.
    id = now.getlocal('+03:00').strftime('%Y-%m-%d')
    raise ArgumentError, 'Router clock cannot go backwards across days' if @current_day && id < @current_day
    if @days.key?(id)
      refresh_forecast(@days[id], now) if refresh
      return @days[id]
    end
    if @current_day
      previous = @days[@current_day]
      refresh_forecast(previous, previous[:flow].closes_at)
      @snapshots[@current_day] = copy(export_day(previous))
    end
    quantiles = AmountQuantiles.new(@calibration.map { |r| r['amount'] }, groups: settings['quantile_groups'])
    samples = copy(@calibration)
    estimates = samples.map do |payment|
      candidates = @providers.reject { |p| p['payment_system'] == 'spacepayments' }.map do |provider|
        next unless HardRules.reasons(payment, provider).empty?
        estimate = @metrics.estimate(provider, payment['amount'], quantiles)
        next if estimate[:probability] < settings['min_conversion']
        estimate.merge(provider: provider['payment_system'])
      end.compact
      rows, = @policy.admissible_options(candidates, payment)
      rows.map { |row| row[:expected_profit_cents] }.max || 0
    end
    # Доход на выплату фиксируется на день; прогноз количества адаптируется к потоку.
    unit_profit = samples.empty? ? 0 : [estimates.sum / samples.length, 0].max
    reference = (unit_profit * settings['forecast_operations']).floor
    budget = settings['budget_rub'] ? RouterMoney.cents(settings['budget_rub']) : (reference * settings['budget_pct'] / 100).floor
    provider_stats = @providers.each_with_object({}) do |provider, result|
      result[provider['payment_system']] = { sent: 0, completed: 0, approved: 0, rejected: 0, expired: 0,
        approved_cents: 0, profit_cents: 0, latency_sum_sec: 0.0, peak_active_count: 0, peak_exposure_cents: 0,
        reasons: Hash.new(0) }
    end
    @current_day = id
    @days[id] = { id: id, received: 0, queued: 0, providers: provider_stats, quantiles: quantiles,
                  calibration: samples, profit_reference_cents: reference, budget_limit_cents: budget,
                  budget_target_cents: budget, unit_profit_cents: unit_profit,
                  mean_amount: samples.empty? ? 0 : samples.sum { |r| r['amount'] }.fdiv(samples.length),
                  flow: FlowForecast.new(now, settings),
                  budget_spent_cents: 0, corrections: [],
                  forecast_operations: settings['forecast_operations'],
                  forecast_volume: samples.empty? ? 0 : samples.sum { |r| r['amount'] }.fdiv(samples.length) * settings['forecast_operations'] }
  end

  def refresh_forecast(day, now)
    day[:flow].update(now)
    count = day[:flow].operations
    day[:forecast_operations] = count
    day[:forecast_volume] = day[:mean_amount] * count
    day[:profit_reference_cents] = (day[:unit_profit_cents] * count).floor
    target = settings['budget_rub'] ? RouterMoney.cents(settings['budget_rub']) :
      (day[:profit_reference_cents] * settings['budget_pct'] / 100).floor
    day[:budget_target_cents] = target
    # Снижение прогноза не отменяет прошлые уступки, но ограничивает новые.
    day[:budget_limit_cents] = [target, day[:budget_spent_cents]].max
  end

  def goal_values(provider, row, payment, day, now)
    name = provider['payment_system']
    stats = day[:providers][name]
    load = exposure(name)
    external = day[:providers].reject { |key, _| key == 'spacepayments' }
    # В план текущего дня входят только его резервы, без fallback.
    pending = @active.values.select { |entry| entry[:provider] != 'spacepayments' && entry[:day_id] == day[:id] }
    own_pending = pending.select { |entry| entry[:provider] == name }
    goal_pending_count = own_pending.sum { |entry| entry[:probability] }
    goal_pending_amount = own_pending.sum { |entry| entry[:probability] * entry[:amount_cents] }
    count_total = external.values.sum { |s| s[:approved] } + pending.sum { |entry| entry[:probability] } + 1
    volume_total = external.values.sum { |s| s[:approved_cents] } / 100.0 +
                   pending.sum { |entry| entry[:probability] * entry[:amount_cents] } / 100.0 + payment['amount']
    compatible = day[:calibration].select { |sample| HardRules.reasons(sample, provider).empty? }
    fraction = compatible.length.to_f / [day[:calibration].length, 1].max
    mean_amount = compatible.empty? ? payment['amount'] : compatible.sum { |sample| sample['amount'] }.fdiv(compatible.length)
    queued = day[:queued]
    remaining_count = ([day[:forecast_operations] - day[:received], 0].max + queued) * fraction * row[:probability]
    remaining_volume = remaining_count * mean_amount
    cap = daily_limit(provider)
    remaining_volume = [remaining_volume, [cap - stats[:approved_cents] / 100.0 - load[:amount] / 100.0, 0].max].min if cap
    settings['goal_order'].map do |goal|
      target, done, progress, capacity = case goal
      when 'daily_turnover_min'
        [provider[goal].to_f, (stats[:approved_cents] + goal_pending_amount) / 100.0,
         payment['amount'] * row[:probability], remaining_volume]
      when 'traffic_percentage'
        [count_total * provider[goal].to_f / 100, stats[:approved] + goal_pending_count, row[:probability], remaining_count]
      when 'volume_share_pct'
        [volume_total * provider[goal].to_f / 100, (stats[:approved_cents] + goal_pending_amount) / 100.0,
         payment['amount'] * row[:probability], remaining_volume]
      end
      next 0.0 unless target > 0
      deficit = [target - done, 0].max
      # Срочность растёт с недобором относительно оставшегося подходящего потока.
      urgency = 1 + deficit / [capacity, progress, 1e-9].max
      [progress, deficit].min / target * urgency
    end
  end

  def export_day(day)
    { id: day[:id], received: day[:received], queued: day[:queued], providers: day[:providers], quantiles: day[:quantiles].to_h,
      profit_reference_cents: day[:profit_reference_cents], budget_limit_cents: day[:budget_limit_cents],
      budget_spent_cents: day[:budget_spent_cents], forecast_operations: day[:forecast_operations],
      budget_target_cents: day[:budget_target_cents], flow_forecast: day[:flow].to_h,
      forecast_volume: day[:forecast_volume], calibration_operation_ids: day[:calibration].map { |r| r['operation_id'] },
      corrections: day[:corrections],
      active_attempts: @active.values.select { |row| row[:day_id] == day[:id] } }
  end
end

class SimpleRouter
  def initialize(providers, state)
    @state = state
  end

  def plan(payment, excluded = [])
    @state.reserve_next(payment, excluded)
  end
end

# Симулятор ответов провайдеров, без реальных платёжных вызовов.
class ProviderSimulator
  def initialize(seed, settings: RouterSettings.new, scenario: 'size_sensitive')
    @seed, @settings, @scenario = seed, settings, scenario
    raise ArgumentError, 'Unknown scenario' unless %w[flat size_sensitive degraded all_reject].include?(scenario)
  end

  def call(payment, provider)
    name = provider.fetch('payment_system')
    # Seed исхода не зависит от порядка потоков и выбранной стратегии.
    random = Random.new(Zlib.crc32("#{@seed}:#{payment.fetch('operation_id')}:#{name}"))
    success_draw, timeout_draw, latency_draw, margin_draw = Array.new(4) { random.rand }
    success_probability = provider.fetch('conversion_24h').to_f
    if @scenario == 'size_sensitive'
      # Зависимость от суммы не использует квантили роутера.
      provider_size_sensitivity = (Zlib.crc32(name) % 2001) / 1000.0 - 1
      normalized_amount = Math.tanh(Math.log([payment['amount'], 1].max / 20_000.0))
      size_adjustment = provider_size_sensitivity * normalized_amount * @settings['simulation_size_effect']
      success_probability = [[success_probability + size_adjustment, 0.01].max, 0.99].min
    elsif @scenario == 'degraded'
      success_probability *= 0.55
    elsif @scenario == 'all_reject'
      success_probability = 0
    end

    # Fallback гарантирован моделью; expired означает подтверждённое неисполнение.
    status = if name == 'spacepayments' || success_draw < success_probability
               'approved'
             elsif timeout_draw < 0.25
               'expired'
             else
               'rejected'
             end
    latency = provider.fetch('avg_latency_sec', 30).to_f * (0.6 + latency_draw * 0.8)
    latency *= 2 if status == 'expired'
    margin = RouterMoney.margin(provider) * (1 + (margin_draw * 2 - 1) * @settings['simulation_margin_jitter'])
    # sleep_scale сокращает ожидание теста, но не задержку в отчёте.
    sleep(latency * @settings['sleep_scale']) if @settings['sleep_scale'] > 0
    { status: status, latency_sec: latency.round(3), net_margin_pct: margin }
  end
end

class PayoutExecutor
  def initialize(providers, state, simulator)
    @providers = providers.each_with_object({}) { |p, hash| hash[p['payment_system']] = p }
    @state, @simulator = state, simulator
    @router = SimpleRouter.new(providers, state)
  end

  def execute(payment, _legacy_plan = nil)
    @state.run_once(payment) do
      attempts, excluded = [], []
      elapsed = 0.0
      sent = 0
      loop do
        token = @router.plan(payment, excluded)
        token[:skipped].each do |skip|
          attempts << skip
          excluded << skip[:provider]
          yield(type: 'skip', provider: skip[:provider], reason: skip[:reason]) if block_given?
        end
        name = token[:provider]
        sent += 1
        yield(type: name == 'spacepayments' ? 'fallback' : 'try', provider: name, attempt: sent,
              ranking: token[:ranking], reason: token[:selection][:choice_reason]) if block_given?
        outcome = @simulator.call(payment, @providers.fetch(name))
        update = @state.finish(token, payment, outcome)
        elapsed += outcome[:latency_sec]
        attempts << { provider: name, decision: 'selected', reason: token[:selection][:choice_reason],
          details: { attempt_id: token[:key], attempt_number: sent, outcome: outcome[:status],
            latency_sec: outcome[:latency_sec], priority: token[:selection][:priority],
            quantile: token[:selection][:bucket] + 1, quantile_version: token[:quantile_version],
            metrics_version_before: token[:metrics_version], metrics_version_after: update[:metrics_version],
            concession_rub: token[:selection][:concession_cents] / 100.0, ranking: token[:ranking] } }
        yield(type: 'metrics', provider: name, update: update) if block_given?
        if outcome[:status] == 'approved'
          break({ operation_id: payment['operation_id'], selected_provider: name, attempts: attempts,
                  simulated_result: 'approved', latency_sec: elapsed.round(3), n: sent,
                  profit_rub: update[:profit_cents] / 100.0, day_id: token[:day_id] })
        end
        excluded << name
        yield(type: 'cascade', provider: name, reason: outcome[:status]) if block_given?
      end
    end
  end
end
