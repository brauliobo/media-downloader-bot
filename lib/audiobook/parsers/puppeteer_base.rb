require 'json'
require 'fileutils'
require 'tmpdir'
require 'digest'
require 'puppeteer'
require_relative 'base'
require_relative '../../ocr'

module Audiobook
  module Parsers
    class PuppeteerBase < Base
      # Extracts data by driving Chromium via puppeteer-ruby.
      # Subclasses can override capture_screenshots if needed.
      def self.extract_data(target_url, stl: nil, opts: nil, **_kwargs)
        out_dir = Dir.mktmpdir('kindle_shots_')
        begin
          stl&.update "Launching capture and navigating..."
          screenshots = capture_screenshots(target_url, out_dir: out_dir, delay_ms: (opts&.delay_ms || 1000).to_i, stl: stl, limit: (opts&.limit || 0).to_i)

          stl&.update "Running OCR on captured pages..."
          images = []
          lines = []
          screenshots.sort.each_with_index do |png_path, idx|
            stl&.update "OCR page #{idx+1}/#{screenshots.size}"
            res = Ocr.transcribe(png_path, opts: opts, stl: stl)
            text = res&.dig(:content, :text) || res&.text || ''
            next if text.to_s.strip.empty?
            # Split into block lines for Book's line-based pipeline
            text.split(/\n{2,}/).each do |block|
              blk = block.strip
              next if blk.empty?
              lines << { 'text' => blk, 'font_size' => 12, 'y' => nil, 'page' => idx + 1 }
            end
            images << { 'page' => idx + 1, 'path' => png_path }
          end

          lang = Ocr.detect_language(lines.first(10).map { |l| { text: l['text'] } }) || 'en'
          {
            metadata: { language: lang, has_ocr_pages: true, page_count: [lines.map { |l| l['page'] }.max || 1, screenshots.size].max },
            content: { lines: lines, images: images },
            opts: opts
          }
        ensure
          # Keep images on disk for downstream references
        end
      end

      # Subclasses may override to customize capture/navigation
      def self.capture_screenshots(target_url, out_dir:, delay_ms:, stl:, limit: 0)
        FileUtils.mkdir_p(out_dir)
        shots = []
        Puppeteer.launch(headless: true) do |browser|
          page = browser.new_page
          page.goto(target_url, wait_until: 'networkidle2', timeout: 120_000)
          page.bring_to_front
          sleep 0.5

          i = 1
          prev_digest = nil
          identical_in_a_row = 0
          loop do
            path = File.join(out_dir, "#{i}.png")
            page.screenshot(path: path, full_page: true)
            shots << path

            digest = Digest::MD5.file(path).hexdigest rescue nil
            if digest && prev_digest == digest
              identical_in_a_row += 1
            else
              identical_in_a_row = 0
              prev_digest = digest
            end

            break if limit.to_i > 0 && i >= limit.to_i
            break if identical_in_a_row >= 2

            sleep(delay_ms.to_i / 1000.0)
            page.keyboard.press('ArrowRight')
            sleep 0.2
            i += 1
          end
        end
        shots
      end
    end
  end
end


