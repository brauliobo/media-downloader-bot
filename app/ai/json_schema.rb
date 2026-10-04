require 'json'
require 'json_schemer'

module AI
  module JSONSchema
    def self.ask(backend:, task:, schema:, input: nil, **kwargs)
      raw = backend.prompt(schema_prompt(task, schema, input), **kwargs)
      parse(raw, schema: schema)
    end

    def self.object(required: nil, **properties)
      required ||= properties.keys
      {
        type:                 'object',
        additionalProperties: false,
        properties:           properties,
        required:             required.map(&:to_s),
      }
    end

    def self.parse(raw, schema:)
      data = JSON.parse(strip_fences(raw.to_s))
      validate!(data, schema: schema)
      data
    end

    def self.validate!(data, schema:)
      errors = JSONSchemer.schema(schema).validate(data).to_a
      return data if errors.empty?

      details = errors.map { |error| pointer = error['data_pointer'].to_s; pointer.empty? ? '/' : pointer }.join(', ')
      raise "AI JSON schema validation failed: #{details}"
    end

    def self.strip_fences(raw)
      raw.strip.gsub(/\A```json\s*/i, '').gsub(/\A```\s*/, '').gsub(/```\s*\z/, '').strip
    end

    def self.schema_prompt(task, schema, input)
      [task, '', 'Return only JSON matching this schema:', JSON.dump(schema), input].compact.join("\n")
    end
  end
end
