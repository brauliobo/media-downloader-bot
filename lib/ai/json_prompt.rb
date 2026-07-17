require_relative 'json_schema'

module AI
  module JSONPrompt
    def json_prompt(text, schema:, **kwargs)
      JSONSchema.parse(prompt(text, **kwargs), schema: schema)
    end
  end
end
