# frozen_string_literal: true

# Ruzzy требует отдельный трейсер: покрытие включается до загрузки харнесса.
# HARNESS позволяет гонять любой харнесс из fuzz/ без второго трейсера.
require 'ruzzy'

Ruzzy.trace(ENV.fetch('HARNESS', 'router_harness.rb'))
