module Services
  class EditPosts
    module PostSelection
      ALL_MESSAGES_QUERY = ' '.freeze

      def fetch_posts(manager, chat)
        return manager.chat_messages(chat_id: chat[:id], limit: fetch_limit, query: @opts[:query], filter: @opts[:media]) unless reply_to_pdf?

        # TDLib treats a whitespace query as an all-message search while preserving the media filter.
        manager.chat_messages(chat_id: chat[:id], limit: fetch_limit, query: ALL_MESSAGES_QUERY, filter: 'audio')
      end

      def select_posts(posts)
        posts = posts.select { |post| generated_post?(post) } unless @opts[:all].to_s == '1'
        posts = posts.sort_by { |post| post[:id].to_i }
        posts.reverse! if order == 'newest'
        posts = posts.drop(start_index(posts)) if start_at
        posts
      end

      def select_pdf_audio_replies(manager, chat, posts)
        posts.filter_map do |post|
          source = source_post(manager, chat, post)
          [post, source] if post.dig(:media, :kind) == 'audio' && source.dig(:media, :kind) == 'document' && source.dig(:media, :file_name).to_s.downcase.end_with?('.pdf')
        end
      end

      def resolve_chat(manager)
        raw = @opts[:chat] || @opts[:channel] || abort('chat= or channel= is required')
        return { id: raw.to_i, title: raw, type: 'Chat' } if raw.to_s.match?(/\A-?\d+\z/)
        return manager.resolve_chat_identifier(raw) if TDBot::ChatIdentifier.public_username(raw)

        chats = manager.find_chats(raw.to_s.delete_prefix('@'), limit: 10, public: @opts[:public].to_s == '1')
        abort "no chat found for #{raw.inspect}" if chats.empty?
        abort "multiple chats found; use chat=<id>: #{chats.inspect}" if chats.size > 1

        chats.first
      end

      def source_post(manager, chat, post)
        return post if @opts[:source] || !post[:reply_to_message_id]

        reply = manager.chat_message(chat_id: chat[:id], message_id: post[:reply_to_message_id])
        source_usable?(reply) ? reply : post
      end

      def source_label(post)
        media = post[:media]
        text  = source_text(post)
        parts = ["message=#{post[:id]}", "type=#{post[:type]}"]
        parts << "media=#{media[:kind]}:#{media[:file_name]}" if media
        parts << "text=#{text.inspect}" if text.present?
        parts.join(' ')
      end

      private

      def generated_post?(post) = post[:reply_to_message_id].present? && post[:media].present?
      def reply_to_pdf? = @opts[:reply_to_pdf].to_s == '1'
      def order = @opts[:order] || 'oldest'
      def start_at
        value = (@opts[:start_at] || @opts[:from_post] || @opts[:from_message_id]).to_s.to_i
        value if value.positive?
      end

      def start_index(posts)
        posts.index { |post| post[:id].to_i == start_at } || abort("start_at=#{start_at} not found in selected posts")
      end

      def source_usable?(post)
        post && (source_text(post).present? || post[:media].present?)
      end
    end
  end
end
