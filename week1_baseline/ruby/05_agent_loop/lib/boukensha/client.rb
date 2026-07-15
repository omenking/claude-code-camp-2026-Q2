require "net/http"
require "json"
require "openssl"

module Boukensha
  class Client
    RETRYABLE_STATUS_CODES = [408, 409, 429, 500, 502, 503, 504].freeze
    TRANSIENT_ERRORS = [
      EOFError,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Net::OpenTimeout,
      Net::ReadTimeout,
      OpenSSL::SSL::SSLError,
      SocketError,
      Timeout::Error
    ].freeze
    MAX_RETRIES = 3
    BASE_RETRY_DELAY = 0.5

    def initialize(builder)
      @builder = builder
    end

    def call(max_output_tokens: 1024, tools: nil)
      uri          = URI(@builder.url)
      http         = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      # NOTE: Originally set to OpenSSL::X509::DEFAULT_CERT_FILE for macOS compatibility,
      # but that path (/usr/lib/ssl/cert.pem) doesn't exist on Linux/WSL2.
      # Omitting ca_file lets OpenSSL find system certs automatically on all platforms.
      # http.ca_file = OpenSSL::X509::DEFAULT_CERT_FILE

      request      = Net::HTTP::Post.new(uri, @builder.headers)
      request.body = @builder.to_api_payload(max_output_tokens: max_output_tokens, tools: tools).to_json

      attempts = 0
      response = nil

      loop do
        attempts += 1

        begin
          response = http.request(request)
        rescue *TRANSIENT_ERRORS => e
          raise ApiError, "API request failed after #{attempts} attempts: #{e.class}: #{e.message}" if attempts > MAX_RETRIES

          sleep retry_delay(attempts)
          next
        end

        if retryable_response?(response) && attempts <= MAX_RETRIES
          sleep retry_delay(attempts)
          next
        end

        break
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise ApiError, "API request failed after #{attempts} attempt#{'s' unless attempts == 1} (#{response.code}): #{response.body}"
      end

      JSON.parse(response.body)
    end

    private

    def retryable_response?(response)
      RETRYABLE_STATUS_CODES.include?(response.code.to_i)
    end

    def retry_delay(attempt)
      BASE_RETRY_DELAY * (2**(attempt - 1))
    end
  end
end
