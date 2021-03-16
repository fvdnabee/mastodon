# frozen_string_literal: true

require_relative '../../config/boot'
require_relative '../../config/environment'
require_relative 'cli_helper'

require 'date'
require 'json'

module Mastodon
  class IGImportCLI < Thor
    include CLIHelper

    @@logger = Logger.new($stdout)

    desc 'import posts_1.json account_name', 'Import posts from IG json into account_name.'
    def import(json_fp, account_name)
      @root_path = File.join(File.dirname(json_fp), '..')
      @account = Account.find_local(account_name)
      file = File.read(json_fp)

      posts = JSON.parse(file)
      posts = posts.sort_by { |item| item['media'][0]['creation_timestamp'] }
      posts.each { |post| handle_post(post) }
    end

    no_commands do
      def handle_post(post)
        ts = post['media'][0]['creation_timestamp']
        text = if post.key?('title') && !post['title'].empty?
                 post['title']
               else
                 post['media'][0]['title']
               end
        text = text.encode('ISO-8859-1').force_encoding('utf-8')

        if text.size > 500
          # due the pagination for a max number of blocks equal to 99, chunks should never be longer than 500 chars for chunk_size = 491
          chunk_size = 491
          text_chunks = text.scan(/.{0,#{chunk_size}}[a-z.!?,;](?:\b|$)/mi)
          n_chunks = text_chunks.size
          raise "Text too long: #{text.size} chars would become #{n_chunks} chunks" unless n_chunks < 100
          text_chunks = text_chunks.map.with_index { |s, i| "#{s.strip} (#{i + 1}/#{n_chunks})" }
          @@logger.warn "Text size #{text.size} longer than 500, splitting into #{n_chunks} chunks"
        else
          text_chunks = [text]
        end

        # Has a status with text already been created ? (false negative if the user
        # actually has two posts with the exact same title)
        return if post_exists?(text_chunks[0])

        ApplicationRecord.transaction do
          # Post first chunk:
          # Post media only on first chunk
          media = post['media'].map { |item| create_media(item) }
          status_attributes = {
            text: text_chunks[0],
            created_at: DateTime.strptime(ts.to_s, '%s'),
            media_attachments: media || [],
            thread: nil,
            sensitive: false,
            spoiler_text:  '',
            visibility: 'public',
            language: @account.user&.setting_default_language&.presence || LanguageDetector.instance.detect(text, @account),
            rate_limit: false,
          }
          status = @account.statuses.create!(status_attributes)
          @@logger.info "Created status with ID #{status.id}"

          # Post remaining chunks (if any) in same thread:
          status_attributes[:media_attachments] = []
          text_chunks[1..-1].each do |txt|
            status_attributes[:text] = txt
            # New chunk is always reply to previous chunk
            status_attributes[:thread] = status # Status.find(status.id)
            # add one second to each subsequent chunk so they show up chronologically in the feed
            status_attributes[:created_at] = status_attributes[:created_at] + Rational(1, 86_400)
            status = @account.statuses.create!(status_attributes)
            @@logger.info "Created status with ID #{status.id} (reply) "
          end
        end
      end

      def post_exists?(post_text)
        !@account.statuses.find_by(text: post_text).nil?
      end

      def create_media(media_item, mime_type = 'image/jpeg')
        path = File.join(@root_path, media_item['uri'])
        media_attachment_params = {
          file: Rack::Test::UploadedFile.new(path, mime_type),
          # thumbnail: nil,
          # description: "test",
          # focus: nil
        }

        @account.media_attachments.create!(media_attachment_params)
      end
    end
  end
end
