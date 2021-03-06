# encoding: utf-8

module Cql
  module Client
    # @private
    class AsynchronousPreparedStatement < PreparedStatement
      # @private
      def initialize(cql, default_consistency, connection_manager, logger)
        @cql = cql
        @default_consistency = default_consistency
        @connection_manager = connection_manager
        @logger = logger
        @request_runner = RequestRunner.new
      end

      def self.prepare(cql, default_consistency, connection_manager, logger)
        statement = new(cql, default_consistency, connection_manager, logger)
        futures = connection_manager.map do |connection|
          statement.prepare(connection)
        end
        Future.all(*futures).map { statement }
      rescue => e
        Future.failed(e)
      end

      def execute(*args)
        connection = @connection_manager.random_connection
        if connection[self]
          run(args, connection)
        else
          prepare(connection).flat_map do
            run(args, connection)
          end
        end
      rescue => e
        Future.failed(e)
      end

      # @private
      def prepare(connection)
        prepare_request = Protocol::PrepareRequest.new(@cql)
        f = connection.send_request(prepare_request)
        f.on_value do |response|
          connection[self] = response.id
          unless @raw_metadata
            # NOTE: this is not thread safe, but the worst that could happen
            # is that we assign the same data multiple times
            @raw_metadata = response.metadata
            @metadata = ResultMetadata.new(@raw_metadata)
          end
          @logger.debug('Statement prepared on new connection')
        end
        f.map { self }
      end

      private

      def run(args, connection)
        statement_id = connection[self]
        bound_args = args.shift(@raw_metadata.size)
        consistency = args.shift || @default_consistency
        statement_id = connection[self]
        request = Protocol::ExecuteRequest.new(statement_id, @raw_metadata, bound_args, consistency)
        @request_runner.execute(connection, request)
      end
    end
  end
end