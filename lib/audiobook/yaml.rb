require 'addressable/uri'
require_relative '../exts/sym_mash'
require_relative '../prober'
require_relative 'book'
require_relative 'runner'

module Audiobook
  class Yaml
    def self.generate_audio(yaml_path, dir:, stl:, opts: SymMash.new)
      raise "YAML file not found: #{yaml_path}" unless File.exist?(yaml_path)
      
      book = Book.from_yaml(yaml_path, opts: opts, stl: stl)
      base = Audiobook.base_from_source(yaml_path)
      audio_out = File.join(dir, "#{base}.opus")
      
      final_audio = Runner.new(book, stl, opts).process_to_audio(audio_out)
      raise 'Failed to generate audiobook' unless File.exist?(final_audio)
      
      [
        SymMash.new(
          fn_out: final_audio,
          type: SymMash.new(name: :audio),
          info: SymMash.new(title: base, uploader: ''),
          mime: 'audio/ogg',
          opts: SymMash.new(format: SymMash.new(mime: 'audio/ogg')),
          oprobe: Prober.for(final_audio)
        )
      ]
    end
  end
end

