module TDBot
  class PostEditor
    # The TDLib content of a generated message: its media, the input file and the thumbnail.
    module MediaContent
      private

      def generated_message_content(media_type, text, parse_mode, params)
        caption    = td_payload(message_sender.send(:parse_markdown_text, text.to_s, parse_mode))
        input_file = generated_input_file(media_type, params)
        thumbnail  = generated_thumbnail(params)

        case media_type
        when 'audio'    then audio_message_content(input_file, thumbnail, caption, params)
        when 'video'    then video_message_content(input_file, thumbnail, caption, params)
        when 'document' then document_message_content(input_file, thumbnail, caption)
        else raise ArgumentError, "unsupported generated message type: #{media_type.inspect}"
        end
      end

      def audio_message_content(input_file, thumbnail, caption, params)
        {
          '@type'   => 'inputMessageAudio',
          'audio'   => {
            '@type'                 => 'inputAudio',
            'audio'                 => input_file,
            'album_cover_thumbnail' => thumbnail,
            'duration'              => params[:duration].to_i,
            'title'                 => params[:title].to_s,
            'performer'             => params[:performer].to_s
          },
          'caption' => caption
        }
      end

      def video_message_content(input_file, thumbnail, caption, params)
        {
          '@type'                    => 'inputMessageVideo',
          'video'                    => {
            '@type'                  => 'inputVideo',
            'video'                  => input_file,
            'thumbnail'              => thumbnail,
            'cover'                  => nil,
            'start_timestamp'        => 0,
            'added_sticker_file_ids' => [],
            'duration'               => params[:duration].to_i,
            'width'                  => params[:width].to_i,
            'height'                 => params[:height].to_i,
            'supports_streaming'     => params.fetch(:supports_streaming, false)
          },
          'caption'                  => caption,
          'show_caption_above_media' => false,
          'self_destruct_type'       => nil,
          'has_spoiler'              => false
        }
      end

      def document_message_content(input_file, thumbnail, caption)
        {
          '@type'    => 'inputMessageDocument',
          'document' => {
            '@type'                          => 'inputDocument',
            'document'                       => input_file,
            'thumbnail'                      => thumbnail,
            'disable_content_type_detection' => false
          },
          'caption'  => caption
        }
      end

      def generated_input_file(media_type, params)
        return { '@type' => 'inputFileRemote', 'id' => params[:remote_id].to_s } if params[:remote_id].present?

        path = generated_file_path(media_type, params)
        path = message_sender.file_manager.copy_to_safe_location(path) unless params[:copy] == false
        { '@type' => 'inputFileLocal', 'path' => path }
      end

      def generated_file_path(media_type, params)
        path = params[:file_path] || params[:file] || params[:"#{media_type}_path"] || params[media_type.to_sym]
        raise ArgumentError, "missing generated #{media_type} file path" if path.to_s.empty?
        raise ArgumentError, "generated file does not exist: #{path}" unless File.exist?(path.to_s)

        path.to_s
      end

      def generated_thumbnail(params)
        path = thumbnail_path(params)
        return unless path && File.exist?(path.to_s)

        safe_path = message_sender.file_manager.copy_to_safe_location(path.to_s)
        {
          '@type'     => 'inputThumbnail',
          'thumbnail' => { '@type' => 'inputFileLocal', 'path' => safe_path },
          'width'     => 0,
          'height'    => 0
        }
      end

      def thumbnail_path(params)
        params.values_at(:thumb_path, :thumbnail_path, :thumbnail, :thumb).compact.first
      end
    end
  end
end
