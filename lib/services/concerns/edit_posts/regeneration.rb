module Services
  class EditPosts
    module Regeneration
      def regenerate(manager, chat, post, source_post)
        service          = CaptureService::Service.new(manager)
        old_service      = Worker.service
        old_skip_cleanup = Worker.skip_cleanup
        Worker.service = service
        Worker.skip_cleanup = true

        text = worker_text(source_post)
        msg = SymMash.new(
          id:      source_post[:id] || post[:id],
          text:    text,
          caption: text,
          chat:    { id: chat[:id] },
          from:    { id: ENV['ADMIN_CHAT_ID'].to_i }
        )

        if (media = source_post[:media])
          msg[media[:kind].to_sym] = SymMash.new(file_id: media[:file_id], file_name: media[:file_name], mime_type: media[:mime_type])
        end

        Worker.new(msg).process
        service.uploads
      ensure
        Worker.service = old_service
        Worker.skip_cleanup = old_skip_cleanup
      end

      def select_upload(post, uploads)
        Array(uploads).find { |item| item[:type].to_s == post.dig(:media, :kind).to_s } || Array(uploads).first
      end

      def source_text(post)
        return @opts[:source].to_s if @opts[:source]

        text = post[:text].to_s.strip
        @opts[:source_urls].to_s == '1' ? text.scan(%r{https?://\S+}).join("\n") : text
      end

      def worker_text(post)
        [source_text(post), worker_opts_text].reject(&:blank?).join("\n")
      end
    end
  end
end
