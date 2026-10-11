module Relay
  # What a rule lets through: one media kind of a message, or everything (including text-only messages) with 'all'.
  module Filter
    KINDS = %w[document audio video].freeze

    def self.kind(msg) = KINDS.find { |kind| msg[kind].present? }

    def self.match?(filter, msg) = filter == 'all' || filter == kind(msg)
  end
end
