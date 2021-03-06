module Poke
  module API
    class Response
      include Logging
      attr_reader :response, :request

      def initialize(response, request)
        @response = response
        @request  = request
      end

      def decode(client)
        logger.info '[+] Decoding Main RPC responses'
        logger.debug "[+] RPC response \r\n#{@response.inspect}"

        @response = POGOProtos::Networking::Envelopes::ResponseEnvelope.decode(@response)
        logger.debug "[+] Decoded RPC response \r\n#{@response.inspect}"

        store_ticket(client)
        store_endpoint(client)

        decode_response
      end

      private

      def decode_response
        logger.info '[+] Decoding Sub RPC responses'
        decoded_resp = parse_rpc_fields(decode_sub_responses)

        loop do
          break unless decoded_resp.to_s.include?('POGOProtos::')
          parse_rpc_fields(decoded_resp)
        end

        decoded_resp.merge!(status_code: @response.status_code,
                            api_url: @response.api_url, error: @response.error)

        @response = decoded_resp
        logger.debug "[+] Returned RPC response \r\n#{@response}"
      end

      def store_ticket(client)
        return unless @response.auth_ticket
        auth = @response.auth_ticket.to_hash

        if client.ticket.is_new_ticket?(auth[:expire_timestamp_ms])
          logger.info "[+] Using auth ticket instead"
          logger.debug "[+] Storing auth ticket\r\n#{auth}"
          client.ticket.set_ticket(auth)
        end
      end

      def store_endpoint(client)
        logger.debug "[+] Current endpoint #{client.endpoint}"

        if client.endpoint == 'https://pgorelease.nianticlabs.com/plfe/rpc'
          raise Errors::InvalidEndpoint if @response.api_url.empty?
        end

        return if @response.api_url.empty?

        logger.debug "[+] Setting endpoint to https://#{@response.api_url}/rpc"
        client.endpoint = "https://#{@response.api_url}/rpc"
      end

      def decode_sub_responses
        @response.returns.zip(@request).each_with_object({}) do |(resp, req), memo|
          logger.debug "[+] Decoding Sub RPC response for #{req}\r\n#{resp.inspect}"
          proto_name, entry_name = fetch_proto_response_metadata(req)

          response = begin
            POGOProtos::Networking::Responses.const_get(proto_name).decode(resp).to_hash
          rescue StandardError
            logger.error "[+] Protobuf definition mismatch/not found for #{entry_name}"
            'Mismatched/Invalid Protobuf Definition'
          end

          logger.debug "[+] Decoded Sub RPC response \r\n#{response.inspect}"
          memo[entry_name] = response
        end
      end

      def fetch_proto_response_metadata(req)
        entry_name = req.is_a?(Symbol) ? req : req.keys.first
        proto_name = Poke::API::Helpers.camel_case_lower(entry_name) + 'Response'

        [proto_name, entry_name]
      end

      def parse_rpc_fields(responses)
        responses.map! do |x|
          x = x.to_hash if x.class.name =~ /POGOProtos/
          x
        end if responses.is_a?(Array)

        responses.each do |k, v|
          parse_rpc_fields(v) if [Hash, Array].include?(v.class)
          parse_rpc_fields(k) if [Hash, Array].include?(k.class)

          responses[k] = v.to_hash if v.class.name =~ /POGOProtos/
        end
      end
    end
  end
end
