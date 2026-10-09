# frozen_string_literal: true

require "openssl"

class OpenInEditorBridge
  module Authentication
    def self.signature(token, direction, nonce, method_or_status, path, body)
      digest = OpenSSL::HMAC.new(token, "SHA256")
      [direction, nonce, method_or_status, path, body].each do |part|
        bytes = part.to_s
        digest << [bytes.bytesize].pack("Q>") << bytes
      end
      digest.hexdigest
    end

    def self.valid_nonce?(nonce)
      nonce.is_a?(String) && nonce.ascii_only? && nonce.match?(/\A[0-9a-f]{32}\z/)
    end

    def self.valid?(provided, token, *message)
      return false unless provided.is_a?(String) && token.is_a?(String) && !token.empty?

      expected = signature(token, *message)
      return false unless provided.bytesize == expected.bytesize

      OpenSSL.fixed_length_secure_compare(expected, provided)
    end
  end
end
