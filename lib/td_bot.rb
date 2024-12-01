require 'tdlib-ruby'
require_relative 'td_bot/helpers'

class TDBot

  include TDBot::Helpers

  class_attribute :cthread

  def self.connect
    self.cthread = Thread.new do
      trap(:INT){ self.td.connect } # cause crash
      at_exit{ self.td.connect }
      client.connect
    end
    self.new
  end


end

