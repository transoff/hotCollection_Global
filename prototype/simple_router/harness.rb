# frozen_string_literal: true

require_relative 'router'

module SyntheticData
  def self.payments(count, history:, seed:, start_at:, arrival_profile: 'batch', arrival_interval_sec: 5.0)
    raise ArgumentError, 'synthetic count must be positive' unless count.is_a?(Integer) && count > 0
    raise ArgumentError, 'Synthetic generation requires known calibration amounts/banks' if history.empty?
    raise ArgumentError, 'arrival_profile must be batch, steady, burst or pause' unless %w[batch steady burst pause].include?(arrival_profile)
    unless arrival_interval_sec.is_a?(Numeric) && arrival_interval_sec.finite? && arrival_interval_sec > 0
      raise ArgumentError, 'arrival_interval_sec must be finite and positive'
    end
    random = Random.new(Zlib.crc32("input:#{seed}"))
    Array.new(count) do |index|
      sample = history[random.rand(history.length)]
      offset = case arrival_profile
               when 'batch' then 0
               when 'steady' then index * arrival_interval_sec
               when 'burst' then (index / 20) * 20 * arrival_interval_sec
               when 'pause' then index * arrival_interval_sec + (index >= count / 2 ? 7200 : 0)
               end
      { 'operation_id' => "synthetic_#{seed}_#{format('%05d', index + 1)}",
        'created_at' => (start_at + offset).iso8601(6), 'amount' => (sample['amount'] * (0.7 + random.rand * 0.6)).round(2),
        'bank' => sample['bank'], 'card_brand' => nil,
        'payout_requisite' => { 'sbp' => { 'phone' => '00000000000', 'bank_name' => "SYNTHETIC #{sample['bank']}" } } }
    end
  end
end

# Часы стенда: поступления и ответы используют один масштаб времени.
class SimulationClock
  def initialize(start_at, scale:)
    raise ArgumentError, 'clock scale must be finite and positive' unless scale.is_a?(Numeric) && scale.finite? && scale > 0
    @start_at, @scale = start_at, scale
    @epoch = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def call
    @start_at + (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @epoch) / @scale
  end

  def wait_until(target)
    loop do
      remaining = (target - call) * @scale
      break if remaining <= 0
      sleep([remaining, 0.05].min)
    end
  end
end

# Расписание принадлежит источнику сценария. Роутер не получает его будущую часть.
class ArrivalSchedule
  def initialize(payments, mode:, start_at:)
    raise ArgumentError, 'arrival_mode must be batch or created_at' unless %w[batch created_at].include?(mode)
    @batches = if mode == 'batch'
                 payments.empty? ? [] : [[start_at, payments]]
               else
                 payments.group_by do |payment|
                   timestamp = Time.iso8601(payment.fetch('created_at'))
                   [timestamp, start_at].max
                 end.sort_by(&:first)
               end
    @cursor, @mutex = 0, Mutex.new
  end

  def take_due(now)
    @mutex.synchronize do
      due = []
      while @cursor < @batches.length && @batches[@cursor][0] <= now
        due.concat(@batches[@cursor][1])
        @cursor += 1
      end
      due
    end
  end

  def next_at
    @mutex.synchronize { @batches[@cursor]&.first }
  end
end

class RouterRun
  attr_reader :decisions, :report, :state

  def initialize(providers:, payments:, history:, settings:, workers: 8, seed: 8,
                  scenario: 'size_sensitive', clock: -> { Time.now }, log: nil,
                  arrival_mode: 'batch', wait_until: nil, snapshot_at: nil)
    raise ArgumentError, 'workers must be positive' unless workers.is_a?(Integer) && workers > 0
    raise ArgumentError, 'queue must be an array' unless payments.is_a?(Array)
    # Повтор operation_id с другими данными — противоречие во входе, но ронять
    # из-за него всю очередь несоразмерно: остальные заявки останутся без
    # решений. Оставляем первую версию заявки, конфликтующую отбрасываем.
    seen = {}
    conflicts = []
    @payments = payments.select do |payment|
      ProviderState.validate_payment!(payment)
      id = payment['operation_id']
      if seen.key?(id) && seen[id] != payment
        conflicts << id
        false
      else
        seen[id] = payment
        true
      end
    end
    STDERR.puts "WARN отброшены конфликтующие дубли operation_id: #{conflicts.uniq.join(', ')}" unless conflicts.empty?
    @unique_payments = seen.values
    @settings, @workers, @seed, @scenario, @log = settings, workers, seed, scenario, log
    @clock, @arrival_mode = clock, arrival_mode
    # Расписание строится по принятым заявкам: конфликтующий дубль отброшен выше,
    # и попав сюда, он дошёл бы до receive и уронил прогон уже там.
    @schedule = ArrivalSchedule.new(@payments, mode: arrival_mode, start_at: clock.call)
    @wait_until = wait_until || ->(target) { sleep([target - clock.call, 0].max) }
    @state = ProviderState.new(providers, settings: settings, history: history, clock: clock, snapshot_at: snapshot_at)
    @simulator = ProviderSimulator.new(seed, settings: settings, scenario: scenario)
  end

  def run
    queue, results = Queue.new, Queue.new
    source = lambda do |now|
      due = @schedule.take_due(now)
      # Вызов под Mutex состояния: воркеры продолжат только после приёма всей пачки.
      due.each { |payment| queue << payment }
      due
    end
    executor = PayoutExecutor.new(@state.providers, @state, @simulator, arrival_source: source)
    lock = Mutex.new
    failures = Queue.new
    threads = @workers.times.map do |index|
      Thread.new do
        loop do
          payment = queue.pop
          break unless payment
          lock.synchronize { @log.puts "IN #{payment['operation_id']} worker=#{index + 1} amount=#{payment['amount']}" } if @log
          result = executor.execute(payment) do |event|
            next unless @log
            lock.synchronize { @log.puts trace_line(payment['operation_id'], event) }
          end
          results << result
          lock.synchronize { @log.puts "OUT #{payment['operation_id']} provider=#{result[:selected_provider]} n=#{result[:n]} approved" } if @log
        end
      rescue StandardError => error
        failures << error
      end
    end
    begin
      loop do
        @state.receive_available(&source)
        timestamp = @schedule.next_at
        break unless timestamp && failures.empty?
        while @clock.call < timestamp && failures.empty?
          @wait_until.call([timestamp, @clock.call + 60].min)
        end
        break unless failures.empty?
      end
      # Если последнюю пачку забрал воркер, дождаться её публикации до маркеров END.
      @state.receive_available(&source) if failures.empty?
    rescue StandardError => error
      failures << error
    ensure
      @workers.times { queue << nil }
    end
    # Ждём все потоки даже при ошибке, чтобы не сохранить частичный успех.
    errors = []
    threads.each do |thread|
      begin
        thread.value
      rescue StandardError => error
        errors << error
      end
    end
    errors << failures.pop until failures.empty?
    raise errors.first unless errors.empty?
    completed = []
    completed << results.pop until results.empty?
    @decisions = completed.uniq { |row| row[:operation_id] }.sort_by { |row| row[:operation_id] }
    snapshot = @state.snapshot
    validate!(snapshot)
    @report = build_report(snapshot)
    self
  end

  private

  def trace_line(id, event)
    prefix = "#{event[:type].to_s.upcase} #{id} provider=#{event[:provider]}"
    case event[:type]
    when 'try'
      choice = event[:ranking].first
      format('%s n=%d order=%s p=%.3f margin=%.3f%% concession=%.2f RUB Q%d reason=%s', prefix,
             event[:attempt], event[:ranking].map { |r| r[:provider] }.join('>'), choice[:probability],
             choice[:margin_pct], choice[:concession_cents] / 100.0, choice[:bucket] + 1, event[:reason])
    when 'metrics'
      update = event[:update]
      format('%s status=%s approved=%.2f RUB p=%.3f version=%d', prefix,
             update[:status], update[:approved_amount], update[:probability], update[:metrics_version])
    else
      "#{prefix} reason=#{event[:reason]}#{event[:type] == 'cascade' ? ' -> rerank' : ''}"
    end
  end

  def validate!(snapshot)
    expected = @unique_payments.map { |payment| payment['operation_id'] }.sort
    raise 'Missing or duplicate results' unless @decisions.map { |d| d[:operation_id] }.sort == expected
    raise 'Unreleased reservations' unless snapshot[:active_attempts].empty?
    @decisions.each do |decision|
      sent = decision[:attempts].select { |attempt| attempt[:decision] == 'selected' }
      names = sent.map { |attempt| attempt[:provider] }
      raise 'Repeated provider in cascade' unless names.uniq == names
      raise 'Incorrect n or final status' unless sent.length == decision[:n] && decision[:simulated_result] == 'approved'
      raise 'Incorrect final provider' unless names.last == decision[:selected_provider]
      raise 'Fallback is not last' if names.include?('spacepayments') && names.last != 'spacepayments'
    end
    snapshot[:days].each_value do |day|
      raise 'Budget overspent' if day[:budget_spent_cents] > day[:budget_limit_cents]
      @state.providers.each do |provider|
        next if provider['payment_system'] == 'spacepayments'
        stats = day[:providers].fetch(provider['payment_system'])
        cap = ProviderState.daily_limit(provider)
        # Перегрузка, уже присутствовавшая в снимке, не считается новой отправкой.
        allowed_peak = cap ? [RouterMoney.cents(cap), stats[:opening_exposure_cents]].max : nil
        raise 'Daily exposure limit violated' if allowed_peak && stats[:peak_exposure_cents] > allowed_peak
      end
    end
  end

  def build_report(snapshot)
    days = snapshot[:days]
    all_stats = @state.providers.each_with_object({}) do |provider, hash|
      name = provider['payment_system']
      hash[name] = days.values.map { |day| day[:providers][name] }
    end
    external_count = @decisions.count { |d| d[:selected_provider] != 'spacepayments' }
    amounts = @unique_payments.each_with_object({}) { |p, h| h[p['operation_id']] = p['amount'] }
    external_volume = @decisions.reject { |d| d[:selected_provider] == 'spacepayments' }.sum { |d| amounts[d[:operation_id]] }
    distribution, utilization, goal_status = {}, {}, {}
    recommendations = []
    reasons = Hash.new(0)
    @state.providers.each do |provider|
      name = provider['payment_system']
      rows = all_stats[name]
      count = rows.sum { |row| row[:approved] }
      volume = rows.sum { |row| row[:approved_cents] - row[:initial_approved_cents] } / 100.0
      completed = rows.sum { |row| row[:completed] }
      provider_reasons = Hash.new(0)
      rows.each { |row| row[:reasons].each { |reason, n| provider_reasons[reason] += n } }
      provider_reasons.each { |reason, n| reasons[reason] += n }
      next if name == 'spacepayments'
      share = external_count.zero? ? 0 : count * 100.0 / external_count
      volume_share = external_volume.zero? ? 0 : volume * 100.0 / external_volume
      distribution[name] = { count: count, share_pct: share.round(3), target_pct: provider['traffic_percentage'].to_f,
        deviation_pp: (share - provider['traffic_percentage'].to_f).round(3), volume_rub: volume,
        volume_share_pct: volume_share.round(3), volume_target_pct: provider['volume_share_pct'],
        sent: rows.sum { |r| r[:sent] }, rejected: rows.sum { |r| r[:rejected] }, expired: rows.sum { |r| r[:expired] },
        observed_conversion: completed.zero? ? nil : count.to_f / completed,
        avg_latency_sec: completed.zero? ? nil : rows.sum { |r| r[:latency_sum_sec] } / completed,
        profit_rub: rows.sum { |r| r[:profit_cents] } / 100.0,
        peak_active_count: rows.map { |r| r[:peak_active_count] }.max || 0 }
      current = days.fetch(snapshot[:current_day])[:providers][name]
      used = current[:approved_cents] / 100.0
      cap = ProviderState.daily_limit(provider)
      utilization[name] = { used: used, limit: cap, utilization_pct: cap && cap > 0 ? used * 100 / cap : nil,
        initial_approved_rub: current[:initial_approved_cents] / 100.0,
        new_approved_rub: (current[:approved_cents] - current[:initial_approved_cents]) / 100.0,
        reserved_rub: snapshot[:provider_load][name][:in_progress_amount_cents] / 100.0,
        basis: 'current-day imported approved plus new approvals; reservations shown separately' }
      goal_status[name] = days.transform_values do |day|
        stats = day[:providers][name]
        target = provider['daily_turnover_min'].to_f
        external = day[:providers].reject { |key, _| key == 'spacepayments' }.values
        day_count = external.sum { |s| s[:approved] }
        day_volume = external.sum { |s| s[:approved_cents] }
        day_count_share = day_count.zero? ? 0 : stats[:approved] * 100.0 / day_count
        day_volume_share = day_volume.zero? ? 0 : stats[:approved_cents] * 100.0 / day_volume
        { minimum_target_rub: target, approved_rub: stats[:approved_cents] / 100.0,
          minimum_deficit_rub: [target - stats[:approved_cents] / 100.0, 0].max.round(2),
          count_share_pct: day_count_share, count_target_pct: provider['traffic_percentage'].to_f,
          count_basis: 'new observed approvals; initial approved count is not supplied',
          count_deviation_pp: day_count_share - provider['traffic_percentage'].to_f,
          volume_share_pct: day_volume_share, volume_target_pct: provider['volume_share_pct'],
          volume_basis: 'current-day imported approved plus new approvals',
          volume_deviation_pp: provider['volume_share_pct'] ? day_volume_share - provider['volume_share_pct'] : nil,
          observed_obstacles: stats[:reasons] }
      end
      # Каждая рекомендация называет наблюдение с числом и параметр конфигурации,
      # который предлагается изменить. Оговорки о модели учёта живут в limitations.
      obstacles = provider_reasons.reject { |reason, _| %w[approved rejected expired].include?(reason) }
      top_obstacle, top_obstacle_count = obstacles.max_by { |_, total| total }
      target_pct = provider['traffic_percentage'].to_f

      used_pct = utilization[name][:utilization_pct]
      if used_pct && used_pct >= 85
        blocked = provider_reasons['daily_amount_limit']
        recommendations << "#{name}: дневной лимит выработан на #{used_pct.round(1)}% (#{used.round(2)} из #{cap} ₽)" \
          "#{blocked.positive? ? ", #{blocked} раз заявка отклонена по daily_amount_limit" : ''}. " \
          "Снизить traffic_percentage с #{target_pct}% или поднять daily_amount_limit."
      end

      deviation = distribution[name][:deviation_pp]
      if deviation <= -5
        recommendations << "#{name}: доля #{share.round(1)}% против цели traffic_percentage #{target_pct}% (#{deviation.round(1)} pp)" \
          "#{top_obstacle ? ". Основная причина исключений — #{top_obstacle} (#{top_obstacle_count} раз)" : ''}. " \
          "Ослабить это ограничение в настройках #{name} или снизить traffic_percentage до #{share.round}%."
      elsif deviation >= 5
        recommendations << "#{name}: доля #{share.round(1)}% против цели traffic_percentage #{target_pct}% (+#{deviation.round(1)} pp). " \
          "Поднять traffic_percentage до #{share.round}% либо расширить лимиты и banks у остальных провайдеров, чтобы разгрузить #{name}."
      end

      volume_target = provider['volume_share_pct']
      if volume_target && (volume_share - volume_target) <= -10
        recommendations << "#{name}: доля по объёму #{volume_share.round(1)}% против цели volume_share_pct #{volume_target}% " \
          "(#{(volume_share - volume_target).round(1)} pp) при обороте #{volume.round(2)} ₽. " \
          "Поднять limit_amount_max или переставить volume_share_pct выше в goal_order."
      end

      goal_status[name].each do |day_id, goal|
        next unless goal[:minimum_deficit_rub] > 0
        recommendations << "#{name}: дневной минимум daily_turnover_min #{goal[:minimum_target_rub]} ₽ за #{day_id} не набран, " \
          "недобор #{goal[:minimum_deficit_rub]} ₽. Поднять daily_turnover_min в goal_order выше traffic_percentage " \
          "или увеличить budget_pct (сейчас #{@settings['budget_pct']}%)."
      end

      observed = distribution[name][:observed_conversion]
      declared = provider['conversion_24h'].to_f
      if observed && observed < declared - 0.05
        recommendations << "#{name}: наблюдаемая конверсия #{observed.round(3)} ниже заявленной conversion_24h #{declared} " \
          "на #{((declared - observed) * 100).round(1)} п.п. Снизить traffic_percentage с #{target_pct}% " \
          "или поднять min_conversion (сейчас #{@settings['min_conversion']})."
      end

      sent_total = rows.sum { |row| row[:sent] }
      failed_total = rows.sum { |row| row[:rejected] + row[:expired] }
      if sent_total.positive? && failed_total * 100.0 / sent_total >= 20
        recommendations << "#{name}: #{failed_total} неуспешных попыток из #{sent_total} отправок " \
          "(#{(failed_total * 100.0 / sent_total).round(1)}%), каждая добавляет шаг каскада. " \
          "Сузить limit_amount_min/limit_amount_max под сегменты с высокой конверсией или снизить traffic_percentage."
      end

      %w[in_progress_count in_progress_amount].each do |field|
        limit = provider["#{field}_limit"]
        initial_value = snapshot[:initial_state][:providers][name][field.to_sym]
        next unless snapshot[:initial_state][:reservations_imported] && limit && initial_value > limit
        recommendations << "#{name}: импортированная нагрузка #{field}=#{initial_value} превышает #{field}_limit #{limit}, " \
          "новые отправки заблокированы. Сверить фактическое состояние провайдера или поднять #{field}_limit."
      end
    end
    fallback = @decisions.select { |d| d[:selected_provider] == 'spacepayments' }
    budget_days = days.transform_values do |day|
      { reference_profit_rub: day[:profit_reference_cents] / 100.0, limit_rub: day[:budget_limit_cents] / 100.0,
        target_rub: day[:budget_target_cents] / 100.0,
        spent_above_target_rub: [day[:budget_spent_cents] - day[:budget_target_cents], 0].max / 100.0,
        spent_rub: day[:budget_spent_cents] / 100.0,
        remaining_rub: (day[:budget_limit_cents] - day[:budget_spent_cents]) / 100.0 }
    end
    if fallback.any?
      fallback_pct = fallback.length * 100.0 / @decisions.length
      recommendations << "spacepayments принял #{fallback.length} из #{@decisions.length} заявок (#{fallback_pct.round(1)}%) " \
        "как self-provider: для них не осталось ни одного допустимого внешнего провайдера. " \
        "Расширить banks или ослабить limit_amount_min/limit_amount_max у внешних провайдеров, чтобы вернуть этот трафик."
    end

    top_reason, top_reason_count = reasons.reject { |reason, _| %w[approved rejected expired].include?(reason) }
                                          .max_by { |_, total| total }
    if top_reason
      recommendations << "Главная причина исключений по всем провайдерам — #{top_reason} (#{top_reason_count} раз из " \
        "#{reasons.reject { |r, _| %w[approved rejected expired].include?(r) }.values.sum}). " \
        "Это самый дешёвый параметр для пересмотра: он отсекает кандидатов до того, как заработают soft-цели."
    end

    budget_days.each do |day_id, budget|
      next unless budget[:limit_rub] > 0 && budget[:spent_rub] >= budget[:limit_rub] * 0.8
      recommendations << "Бюджет уступок за #{day_id} израсходован на #{(budget[:spent_rub] * 100 / budget[:limit_rub]).round(1)}% " \
        "(#{budget[:spent_rub]} из #{budget[:limit_rub]} ₽). Поднять budget_pct с #{@settings['budget_pct']}%, " \
        "чтобы soft-цели могли перебивать выбор по прибыли чаще."
    end

    predictions = @decisions.flat_map { |d| d[:attempts] }.select { |a| a[:decision] == 'selected' && a[:provider] != 'spacepayments' }
    brier = predictions.sum do |attempt|
      details = attempt[:details]
      p = details[:ranking].find { |row| row[:provider] == attempt[:provider] }[:probability]
      (p - (details[:outcome] == 'approved' ? 1 : 0))**2
    end
    { period: days.length == 1 ? snapshot[:current_day] : "#{days.keys.min}/#{days.keys.max}",
      total_operations: @decisions.length, received_requests: @payments.length,
      duplicate_requests: @payments.length - @decisions.length,
      distribution: distribution, distribution_basis: 'new final approved external payouts only; initial turnover and fallback excluded',
      fallback: { count: fallback.length, share_of_all_pct: @decisions.empty? ? 0 : fallback.length * 100.0 / @decisions.length,
                  profit_rub: fallback.sum { |d| RouterMoney.cents(d[:profit_rub]) } / 100.0 },
      skip_reasons: @decisions.flat_map { |d| d[:attempts] }.select { |a| a[:decision] == 'skipped' }
                             .each_with_object(Hash.new(0)) { |a, h| h[a[:reason]] += 1 },
      observed_obstacles: reasons, projected_daily_utilization: utilization,
      recommendations: recommendations, goals: goal_status,
      budget: { basis: @settings['budget_rub'] ? 'explicit_fixed_rubles' : 'dynamic_flow_times_fixed_daily_profit_per_operation',
                percentage: @settings['budget_pct'], days: budget_days },
      flow_forecast: days.transform_values { |day| day[:flow_forecast] },
      quantiles: days.transform_values { |day| day[:quantiles] },
      quality: { external_brier_score: predictions.empty? ? nil : brier / predictions.length,
                 avg_payout_latency_sec: @decisions.empty? ? 0 : @decisions.sum { |d| d[:latency_sec] } / @decisions.length,
                 avg_queue_wait_sec: @decisions.empty? ? 0 : @decisions.sum { |d| d[:queue_wait_sec] } / @decisions.length,
                 avg_end_to_end_latency_sec: @decisions.empty? ? 0 : @decisions.sum { |d| d[:end_to_end_latency_sec] } / @decisions.length,
                 total_sends: @decisions.sum { |d| d[:n] },
                 payouts_over_target_latency: @decisions.count { |d| d[:latency_sec] > @settings['max_expected_latency_sec'] } },
      profit_rub: @decisions.sum { |d| RouterMoney.cents(d[:profit_rub]) } / 100.0,
      external_profit_rub: distribution.values.sum { |row| RouterMoney.cents(row[:profit_rub]) } / 100.0,
      peak_parallel: snapshot[:peak_parallel], seed: @seed, workers: @workers, scenario: @scenario,
      arrivals: { mode: @arrival_mode, visibility: 'all received operations; no future arrivals; workers limit execution only' },
      settings: @settings.to_h, state: snapshot,
      limitations: ['Synthetic experiment, not real economic evidence.',
        '100 known operations is a calibration/forecast setting, not a provider count or queue limit.',
        'Reference is a sample-based forecast, not an oracle or a capacity-aware optimal day.',
        'Cascade comparison assumes conditional independence and an income-sorted tail; actual next step is reranked.',
        'Model concession budget does not bound realized counterfactual profit loss.',
        'Single-process memory only; no restart recovery, real bank calls or multi-process guarantees.',
        'Reservation-day accounting; late results append corrections to immutable closed-day snapshots.',
        'Initial aggregate in-progress has no IDs/outcomes and remains reserved, including across midnight; it is not simulated or automatically settled.',
        'Initial approved count, profit and prior RPM send timestamps are not supplied; no counters are fabricated from aggregate money or calibration history.',
        'Snapshot turnover is applied only on its MSK calendar day; starting on a later day discards old daily turnover but retains unresolved exposure.',
        'Budget/minimum/quality/smoothing defaults are explicit test assumptions, not organizer-provided benefits.'] }
  end
end
