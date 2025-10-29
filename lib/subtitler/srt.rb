class Subtitler
  class SRT
    BLOCK_SEPARATOR = /\r?\n\r?\n+/.freeze
    NOISE_DOTS_LINE = /\A\s*\d(?:\s*\.\s*\d){3,}\.??\s*\z/.freeze

    def self.filter_noise(srt)
      srt.split(BLOCK_SEPARATOR).reject do |block|
        content_lines = block.lines.reject do |line|
          stripped = line.strip
          stripped.empty? || stripped =~ /^\d+$/ || line.include?('-->')
        end
        content_lines.any? { |line| line.strip.match?(NOISE_DOTS_LINE) }
      end.join("\n\n")
    end
  end
end


