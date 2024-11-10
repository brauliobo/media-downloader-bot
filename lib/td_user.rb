require 'tdlib-ruby'
require_relative 'tdlib/helpers'

class TdUser

  include Tdlib::Helpers

  class_attribute :cthread

  def self.connect
    self.cthread = Thread.new do
      trap(:INT){ self.td.connect } # cause crash
      client.connect
    end
  end

end

