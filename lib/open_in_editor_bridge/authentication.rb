# frozen_string_literal: true

require "json"
require "openssl"

class OpenInEditorBridge
  module Authentication
    def self.signature(token, direction, nonce, method_or_status, path, body)
      message = JSON.generate([direction, nonce, method_or_status.to_s, path, body])
      OpenSSL::HMAC.hexdigest("SHA256", token, message)
    end

    def self.valid?(provided, token, *message)
      return false unless provided.is_a?(String) && token.is_a?(String) && !token.empty?

      expected = signature(token, *message)
      return false unless provided.bytesize == expected.bytesize

      OpenSSL.fixed_length_secure_compare(expected, provided)
    end
  end
end
