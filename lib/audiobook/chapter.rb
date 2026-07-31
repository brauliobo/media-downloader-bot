require 'tmpdir'

require_relative 'audio_files'
require_relative 'pauses'
require_relative 'section'
require_relative '../prober'
require_relative '../zipper'

module Audiobook
  # Represents one complete discourse or chapter and its nested sections.
  class Chapter
    PAUSE = Pauses::CHAPTER

    attr_reader :title, :audio, :sections

    def initialize(title:, audio:, sections: [])
      @title    = title.to_s
      @audio    = File.expand_path(audio)
      @sections = Array(sections)
      unless @sections.all? { |section| section.is_a?(Section) }
        raise ArgumentError, 'chapter sections must be Audiobook::Section objects'
      end
    end

    def self.join(chapters, output, pause_amplitude: nil)
      chapters = Array(chapters)
      raise ArgumentError, 'chapters must not be empty' if chapters.empty?

      chapters.each do |chapter|
        raise "chapter audio not found: #{chapter.audio}" unless File.size?(chapter.audio)
      end

      Dir.mktmpdir('audiobook-chapters-') do |dir|
        pause = pause_file(chapters.first.audio, dir, amplitude: pause_amplitude) if chapters.size > 1
        inputs = chapters.each_with_index.flat_map do |chapter, index|
          [index.positive? ? pause : nil, chapter.audio].compact
        end
        Zipper.concat_audio(inputs, output)
      end
    end

    def to_h
      {
        'chapter' => {
          'title'    => title,
          'sections' => sections.map(&:to_h)
        }
      }
    end

    def self.pause_file(audio, dir, amplitude: nil)
      stream = Prober.for(audio).streams.find { |candidate| candidate.codec_type == 'audio' }
      rate   = stream&.sample_rate.to_i
      rate   = AudioFiles.sample_rate unless rate.positive?
      ext    = File.extname(audio)
      ext    = '.wav' if ext.empty?
      AudioFiles.pause(PAUSE, dir, sample_rate: rate, extension: ext, amplitude: amplitude)
    end
    private_class_method :pause_file
  end
end
