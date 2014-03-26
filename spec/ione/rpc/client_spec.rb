# encoding: utf-8

require 'spec_helper'


module Ione
  module Rpc
    describe Client do
      let :client do
        ClientSpec::TestClient.new(%w[node0.example.com:4321 node1.example.com:5432 node2.example.com:6543], io_reactor: io_reactor, logger: logger, connection_timeout: 7)
      end

      let :io_reactor do
        r = double(:io_reactor)
        r.stub(:running?).and_return(false)
        r.stub(:start) do
          r.stub(:running?).and_return(true)
          Future.resolved(r)
        end
        r.stub(:stop) do
          r.stub(:running?).and_return(false)
          Future.resolved(r)
        end
        r.stub(:connect) do |host, port, _, &block|
          Future.resolved(block.call(create_raw_connection(host, port)))
        end
        r
      end

      let :logger do
        double(:logger, warn: nil, info: nil, debug: nil)
      end

      def create_raw_connection(host, port)
        connection = double("connection@#{host}:#{port}")
        connection.stub(:host).and_return(host)
        connection.stub(:port).and_return(port)
        connection
      end

      describe '#start' do
        it 'starts the reactor' do
          client.start.value
          io_reactor.should have_received(:start)
        end

        it 'returns a future that resolves to the client' do
          client.start.value.should equal(client)
        end

        it 'connects to the specified hosts and ports using the specified connection timeout' do
          client.start.value
          io_reactor.should have_received(:connect).with('node0.example.com', 4321, 7)
          io_reactor.should have_received(:connect).with('node1.example.com', 5432, 7)
          io_reactor.should have_received(:connect).with('node2.example.com', 6543, 7)
        end

        it 'creates a protocol handler for each connection' do
          client.start.value
          client.created_connections.map(&:host).should == %w[node0.example.com node1.example.com node2.example.com]
          client.created_connections.map(&:port).should == [4321, 5432, 6543]
        end

        it 'logs when the connection succeeds' do
          client.start.value
          logger.should have_received(:info).with(/connected to node0.example\.com:4321/i)
          logger.should have_received(:info).with(/connected to node1.example\.com:5432/i)
          logger.should have_received(:info).with(/connected to node2.example\.com:6543/i)
        end

        it 'attempts to connect again when a connection fails' do
          connection_attempts = 0
          attempts_by_host = Hash.new(0)
          io_reactor.stub(:schedule_timer).and_return(Future.resolved)
          io_reactor.stub(:connect) do |host, port, _, &block|
            if host == 'node1.example.com'
              Future.resolved(block.call(create_raw_connection(host, port)))
            else
              attempts_by_host[host] += 1
              if attempts_by_host[host] < 10
                Future.failed(StandardError.new('BORK'))
              else
                Future.resolved(block.call(create_raw_connection(host, port)))
              end
            end
          end
          client.start.value
          io_reactor.should have_received(:connect).with('node1.example.com', anything, anything).once
          attempts_by_host['node0.example.com'].should == 10
          attempts_by_host['node2.example.com'].should == 10
        end

        it 'doubles the time it waits between connection attempts up to 10x the connection timeout' do
          connection_attempts = 0
          timeouts = []
          io_reactor.stub(:schedule_timer) do |n|
            timeouts << n
            Future.resolved
          end
          io_reactor.stub(:connect) do |host, port, _, &block|
            if host == 'node1.example.com'
              connection_attempts += 1
              if connection_attempts < 10
                Future.failed(StandardError.new('BORK'))
              else
                Future.resolved(block.call(create_raw_connection(host, port)))
              end
            else
              Future.resolved(block.call(create_raw_connection(host, port)))
            end
          end
          client.start.value
          timeouts.should == [7, 14, 28, 56, 70, 70, 70, 70, 70]
        end

        it 'stops trying to reconnect when the reactor is stopped' do
          io_reactor.stub(:schedule_timer) do
            promise = Promise.new
            Thread.start do
              sleep(0.01)
              promise.fulfill
            end
            promise.future
          end
          io_reactor.stub(:connect).and_return(Future.failed(StandardError.new('BORK')))
          f = client.start
          io_reactor.stop
          expect { f.value }.to raise_error(Io::ConnectionError, /IO reactor stopped while connecting/i)
        end

        it 'logs each connection attempt and failure' do
          connection_attempts = 0
          io_reactor.stub(:schedule_timer).and_return(Future.resolved)
          io_reactor.stub(:connect) do |host, port, _, &block|
            if host == 'node1.example.com'
              connection_attempts += 1
              if connection_attempts < 3
                Future.failed(StandardError.new('BORK'))
              else
                Future.resolved(block.call(create_raw_connection(host, port)))
              end
            else
              Future.resolved(block.call(create_raw_connection(host, port)))
            end
          end
          client.start.value
          logger.should have_received(:debug).with(/connecting to node0\.example\.com:4321/i).once
          logger.should have_received(:debug).with(/connecting to node1\.example\.com:5432/i).exactly(3).times
          logger.should have_received(:debug).with(/connecting to node2\.example\.com:6543/i).once
          logger.should have_received(:warn).with(/failed connecting to node1\.example\.com:5432, will try again in \d+s/i).exactly(2).times
        end

        it 'calls the connection initializer implementation after the connection has been established' do
          initialized = []
          client.connection_initializer = lambda do |connection|
            initialized << connection
            Future.resolved
          end
          client.start.value
          initialized.should == client.created_connections
        end
      end

      describe '#stop' do
        it 'stops the reactor' do
          client.stop.value
          io_reactor.should have_received(:stop)
        end

        it 'returns a future that resolves to the client' do
          client.stop.value.should equal(client)
        end
      end

      describe '#send_request' do
        before do
          client.start.value
          client.created_connections.each do |connection|
            connection.stub(:send_message).with('PING').and_return(Future.resolved('PONG'))
          end
        end

        it 'returns a future that resolves to the response from the server' do
          client.send_request('PING').value.should == 'PONG'
        end

        it 'returns a failed future when called when not connected' do
          client.stop.value
          expect { client.send_request('PING').value }.to raise_error(Io::ConnectionError)
        end
      end

      describe '#connected?' do
        it 'returns false before the client is started' do
          client.should_not be_connected
        end

        it 'returns true when the client has started' do
          client.start.value
          client.should be_connected
        end

        it 'returns false when the client has been stopped' do
          client.start.value
          client.stop.value
          client.should_not be_connected
        end

        it 'returns false when the connection has closed' do
          client.start.value
          io_reactor.stub(:schedule_timer).and_return(Future.resolved)
          io_reactor.stub(:connect).and_return(Future.failed(StandardError.new('BORK')))
          client.created_connections.each { |connection| connection.closed_listener.call }
          client.should_not be_connected
        end
      end

      context 'when disconnected' do
        it 'logs that the connection closed' do
          client.start.value
          client.created_connections.find { |c| c.host == 'node1.example.com' }.closed_listener.call
          logger.should have_received(:info).with(/connection to node1\.example\.com:5432 closed/i)
          logger.should_not have_received(:info).with(/node0\.example\.com closed/i)
        end

        it 'logs that the connection closed unexpectedly' do
          client.start.value
          client.created_connections.find { |c| c.host == 'node1.example.com' }.closed_listener.call(StandardError.new('BORK'))
          logger.should have_received(:warn).with(/connection to node1\.example\.com:5432 closed unexpectedly: BORK/i)
          logger.should_not have_received(:warn).with(/node0\.example\.com/i)
        end

        it 'logs when requests fail' do
          client.start.value
          client.created_connections.each { |connection| connection.stub(:send_message).with('PING').and_return(Future.failed(StandardError.new('BORK'))) }
          client.send_request('PING')
          logger.should have_received(:warn).with(/request failed: BORK/i)
        end

        it 'attempts to reconnect' do
          client.start.value
          client.created_connections.find { |c| c.host == 'node1.example.com' }.closed_listener.call(StandardError.new('BORK'))
          io_reactor.should have_received(:connect).exactly(4).times
        end

        it 'does not attempt to reconnect on a clean close' do
          client.start.value
          client.created_connections.find { |c| c.host == 'node1.example.com' }.closed_listener.call
          io_reactor.should have_received(:connect).exactly(3).times
        end

        it 'runs the same connection logic as #connect' do
          connection_attempts = 0
          connection_attempts_by_host = Hash.new(0)
          io_reactor.stub(:schedule_timer).and_return(Future.resolved)
          io_reactor.stub(:connect) do |host, port, _, &block|
            connection_attempts_by_host[host] += 1
            if host == 'node1.example.com'
              connection_attempts += 1
              if connection_attempts > 1 && connection_attempts < 10
                Future.failed(StandardError.new('BORK'))
              else
                Future.resolved(block.call(create_raw_connection(host, port)))
              end
            else
              Future.resolved(block.call(create_raw_connection(host, port)))
            end
          end
          client.start.value
          client.created_connections.find { |c| c.host == 'node1.example.com' }.closed_listener.call(StandardError.new('BORK'))
          connection_attempts_by_host['node0.example.com'].should == 1
          connection_attempts_by_host['node1.example.com'].should == 10
          connection_attempts_by_host['node2.example.com'].should == 1
        end
      end

      context 'with multiple connections' do
        before do
          client.start.value
        end

        it 'sends requests over a random connection' do
          1000.times do
            client.send_request('PING')
          end
          request_fractions = client.created_connections.each_with_object({}) { |connection, acc| acc[connection.host] = connection.requests.size/1000.0 }
          request_fractions['node0.example.com'].should be_within(0.1).of(0.33)
          request_fractions['node1.example.com'].should be_within(0.1).of(0.33)
          request_fractions['node2.example.com'].should be_within(0.1).of(0.33)
        end

        it 'uses the provided routing strategy to pick a connection' do
          strategy = double(:strategy)
          strategy.stub(:choose_connection) do |connections, request|
            if request == 'PING'
              connections.find { |c| c.host == 'node0.example.com' }
            else
              connections.find { |c| c.host == 'node2.example.com' }
            end
          end
          client = ClientSpec::TestClient.new(%w[node0.example.com:4321 node1.example.com:5432 node2.example.com:6543], io_reactor: io_reactor, logger: logger, connection_timeout: 7, routing_strategy: strategy)
          client.start.value
          client.send_request('PING')
          client.send_request('FOO')
          client.send_request('FOO')
          request_counts = client.created_connections.each_with_object({}) { |connection, acc| acc[connection.host] = connection.requests.size }
          request_counts['node0.example.com'].should == 1
          request_counts['node1.example.com'].should == 0
          request_counts['node2.example.com'].should == 2
        end

        it 'retries the request when it failes because a connection closed' do
          promises = [Promise.new, Promise.new]
          counter = 0
          received_requests = []
          client.created_connections.each do |connection|
            connection.stub(:send_message) do |request|
              received_requests << request
              promises[counter].future.tap { counter += 1 }
            end
          end
          client.send_request('PING')
          sleep 0.01 until counter > 0
          promises[0].fail(Io::ConnectionClosedError.new('CLOSED BORK'))
          promises[1].fulfill('PONG')
          received_requests.should have(2).items
        end

        it 'logs when a request is retried' do
          client.created_connections.each { |connection| connection.stub(:send_message).and_return(Future.failed(Io::ConnectionClosedError.new('CLOSED BORK'))) }
          client.send_request('PING')
          logger.should have_received(:warn).with(/request failed because the connection closed, retrying/i).at_least(1).times
        end
      end
    end
  end
end

module ClientSpec
  class TestClient < Ione::Rpc::Client
    attr_reader :created_connections

    def initialize(*)
      super
      @created_connections = []
    end

    def connection_initializer=(initializer)
      @connection_initializer = initializer
    end

    def create_connection(connection)
      @created_connections << TestConnection.new(connection)
      @created_connections.last
    end

    def initialize_connection(connection)
      if @connection_initializer
        @connection_initializer.call(connection)
      else
        Ione::Future.resolved
      end
    end
  end

  class TestConnection
    attr_reader :closed_listener, :requests

    def initialize(raw_connection)
      @raw_connection = raw_connection
      @requests = []
    end

    def on_closed(&listener)
      @closed_listener = listener
    end

    def host
      @raw_connection.host
    end

    def port
      @raw_connection.port
    end

    def send_message(request)
      @requests << request
      Ione::Future.resolved
    end
  end
end