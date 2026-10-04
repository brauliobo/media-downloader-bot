class VoiceClone
  class Case
    attr_reader :name, :parameters

    def initialize(name:, reference: false, parameters: {})
      @name       = name.to_s
      @reference  = !!reference
      @parameters = (parameters || {}).to_h.transform_keys(&:to_sym).freeze
      raise ArgumentError, 'voice clone evaluation case name is empty' if @name.empty?
    end

    def use_reference?
      @reference
    end

    def to_h
      {name: name, reference: use_reference?, parameters: parameters.transform_keys(&:to_s)}
    end
  end
end
