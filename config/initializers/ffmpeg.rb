Rails.application.config.after_initialize { FFmpeg.verify! }
