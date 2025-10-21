require 'json'
require 'fileutils'
require 'tmpdir'
require 'digest'
require 'puppeteer'
require_relative 'base'

module Audiobook
  module Parsers
    class PuppeteerBase < Base
      # Extracts data by driving Chromium via puppeteer-ruby.
      # Subclasses can override capture_screenshots if needed.
      def self.extract_data(target_url, stl: nil, opts: nil, **_kwargs)
        out_dir = Dir.mktmpdir('kindle_shots_')
        begin
          stl&.update "Launching capture and navigating..."
          screenshots = capture_screenshots(
            target_url,
            out_dir: out_dir,
            delay_ms: (opts&.delay_ms || 1000).to_i,
            stl: stl,
            limit: (opts&.limit || 0).to_i,
            cookies: (opts&.cookies || [])
          )
          # Compile screenshots into a single PDF and return its path; Book will parse/ocr
          stl&.update 'Compiling screenshots into PDF'
          pdf_path = File.join(out_dir, 'book.pdf')
          build_pdf_from_images(screenshots, pdf_path)
          page_count = screenshots.size
          { metadata: { page_count: page_count }, content: { pdf: pdf_path }, opts: opts }
        ensure
          # Keep images on disk for downstream references
        end
      end

      # Subclasses may override to customize capture/navigation
      def self.capture_screenshots(target_url, out_dir:, delay_ms:, stl:, limit: 0, cookies: [])
        FileUtils.mkdir_p(out_dir)
        shots = []
        browser = launch_browser
        begin
          page = setup_page(browser: browser, url: target_url, cookies: cookies, stl: stl)
          rewind_to_start(page, stl)
          shots = capture_loop(page: page, out_dir: out_dir, delay_ms: delay_ms, limit: limit, stl: stl)
        ensure
          browser.close rescue nil
        end
        shots
      end

      # Build a single PDF from the set of screenshot images.
      def self.build_pdf_from_images(images, out_pdf)
        return if images.empty?
        sorted = images.sort
        # Prefer img2pdf when available; fallback to ImageMagick convert
        if system('which img2pdf >/dev/null 2>&1')
          args = sorted.map { |p| "'#{p}'" }.join(' ')
          system("img2pdf #{args} -o '#{out_pdf}'")
        else
          args = sorted.map { |p| "'#{p}'" }.join(' ')
          system("convert #{args} '#{out_pdf}'")
        end
        out_pdf
      end

      # ---------------- helpers ----------------
      def self.launch_browser
        headless = ENV.key?('PUPPETEER_HEADLESS') ? (ENV['PUPPETEER_HEADLESS'] != '0') : true
        Puppeteer.launch(headless: headless)
      end

      def self.setup_page(browser:, url:, cookies:, stl: nil)
        page = browser.new_page
        set_viewport(page, stl)
        apply_cookies(page, cookies)
        navigate(page, url, stl)
        page
      end

      def self.set_viewport(page, stl)
        vp_w = (ENV['PUPPETEER_WIDTH']  || '800').to_i
        vp_h = (ENV['PUPPETEER_HEIGHT'] || (vp_w * 1.4142).to_i).to_i
        page.viewport = Puppeteer::Viewport.new(width: vp_w, height: vp_h, device_scale_factor: 1)
        stl&.update "Viewport set to #{vp_w}x#{vp_h}"
      rescue StandardError
      end

      def self.apply_cookies(page, cookies)
        return if cookies.nil? || cookies.empty?
        cookies.each { |c| page.set_cookie(c) }
      rescue StandardError
      end

      def self.navigate(page, url, stl)
        stl&.update 'Navigating to Kindle reader...'
        page.goto(url, wait_until: 'networkidle2', timeout: 120_000)
        stl&.update 'Navigation complete. Starting capture...'
        page.bring_to_front
        sleep 0.5
      end

      def self.rewind_to_start(page, stl)
        stl&.update 'Rewinding to the first page'
        200.times do |j|
          page.keyboard.press('PageUp'); sleep 0.1
          stl&.update "Rewinding (#{j + 1}/200)" if (j % 10).zero?
        end
      end

      def self.capture_loop(page:, out_dir:, delay_ms:, limit:, stl: nil)
        shots = []
        i = 1
        prev = nil
        same = 0
        loop do
          path = File.join(out_dir, "#{i}.png")
          page.screenshot(path: path, full_page: true)
          shots << path

          md5 = file_md5(path)
          if md5 && prev == md5 then same += 1 else same = 0; prev = md5 end

          limit_hit = limit.to_i > 0 && i >= limit.to_i
          done_repeated = same >= 2
          will_advance = !(limit_hit || done_repeated)

          stl&.update will_advance ? "Page #{i} captured; next -> #{i + 1}" : "Page #{i} captured; done"

          break unless will_advance

          sleep(delay_ms.to_i / 1000.0)
          page.keyboard.press('ArrowRight'); sleep 0.2
          i += 1
        end
        shots
      end

      def self.file_md5(path)
        Digest::MD5.file(path).hexdigest
      rescue StandardError
        nil
      end
    end
  end
end


