# frozen_string_literal: true

# Цель: одна заявка проходит весь роутинг. Оракул — RouterRun#validate!,
# который уже проверяет бюджет, лимиты, освобождение резервов и позицию
# fallback в каскаде. Всё, что не ArgumentError из входной валидации, — находка.
require_relative 'common'

PROVIDER_NAMES = ['vipay', 'payflow', 'quickpay', 'spacepayments', 'нет такого', nil].freeze
DATES = [nil, '2026-07-30T11:59:00+03:00', '2026-07-30T12:00:00+03:00', '2026-07-30T12:00:01+03:00'].freeze

test_one_input = lambda do |data|
  fdp = Ruzzy::FuzzedDataProvider.new(data)
  # scrub повторяет то, что CLI делает при чтении файла: дальше по коду
  # строка всегда валидна в UTF-8, невалидные байты — забота границы.
  id = fdp.consume_random_length_string(16).force_encoding('UTF-8').scrub
  payment = fuzz_payment(fdp, id).merge(
    # здесь, в отличие от общего сетапа, суммы намеренно выходят за границы:
    # ноль, отрицательные и запредельные должны отсекаться валидатором
    'amount' => fdp.consume_int_in_range(-100_000, 500_000_000) / 100.0,
    'created_at' => fdp.pick_value_in_list(DATES),
    'preferred_provider' => fdp.pick_value_in_list(PROVIDER_NAMES)
  )

  begin
    ProviderState.validate_payment!(payment)
  rescue ArgumentError
    return 0 # вход отвергнут валидатором — это штатное поведение, а не баг
  end

  RouterRun.new(providers: PROVIDERS, payments: [payment], history: HISTORY,
                settings: SETTINGS, workers: 1, clock: fuzz_clock(fdp)).run
  0
end

Ruzzy.fuzz(test_one_input)
