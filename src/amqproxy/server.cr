require "socket"
require "openssl"
require "logger"
require "amq-protocol"
require "./pool"
require "./client"
require "./upstream"

module AMQProxy
  class Server
    @running = true

    def initialize(upstream_host, upstream_port, upstream_tls, log_level = Logger::INFO)
      @log = Logger.new(STDOUT)
      @log.level = log_level
      @log.formatter = Logger::Formatter.new do |severity, datetime, progname, message, io|
        io << message
      end
      @client_connections = 0
      @pool = Pool.new(upstream_host, upstream_port, upstream_tls, @log)
      @log.info "Proxy upstream: #{upstream_host}:#{upstream_port} #{upstream_tls ? "TLS" : ""}"
    end

    getter :client_connections

    def upstream_connections
      @pool.size
    end

    def listen(address, port)
      @socket = socket = TCPServer.new(address, port)
      @log.info "Proxy listening on #{socket.local_address}"
      while @running
        if client = socket.accept?
          spawn handle_connection(client, client.remote_address)
        else
          break
        end
      end
      @log.info "Proxy stopping accepting connections"
    end

    def listen_tls(address, port, cert_path : String, key_path : String)
      @socket = socket = TCPServer.new(address, port)
      context = OpenSSL::SSL::Context::Server.new
      context.private_key = key_path
      context.certificate_chain = cert_path
      log.info "Proxy listening on #{socket.local_address}:#{port} (TLS)"
      while @running
        if client = socket.accept?
          begin
            ssl_client = OpenSSL::SSL::Socket::Server.new(client, context)
            ssl_client.sync_close = true
            spawn handle_connection(ssl_client, client.remote_address)
          rescue e : OpenSSL::SSL::Error
            @log.error "Error accepting OpenSSL connection from #{client.remote_address}: #{e.inspect}"
          end
        else
          break
        end
      end
      @log.info "Proxy stopping accepting connections"
    end

    def close
      @running = false
      @socket.try &.close
    end

    def handle_connection(socket, remote_address)
      socket.sync = false
      socket.linger = 0
      socket.keepalive = true
      socket.tcp_nodelay = true
      socket.tcp_keepalive_idle = 60
      socket.tcp_keepalive_count = 3
      socket.tcp_keepalive_interval = 10
      @client_connections += 1
      @log.debug { "Client connection accepted from #{remote_address}" }
      c = Client.new(socket)
      @pool.borrow(c.user, c.password, c.vhost) do |u|
        if u.nil?
          f = AMQ::Protocol::Frame::Connection::Close.new(403_u16,
                                                          "ACCESS_REFUSED",
                                                          0_u16, 0_u16)
          f.to_io socket, IO::ByteFormat::NetworkEndian
          next
        end
        upstream = u.not_nil!
        upstream.current_client = c
        spawn c.decode_frames(upstream)
        idx, _ = Channel.select([
          upstream.close_channel.receive_select_action,
          c.close_channel.receive_select_action
        ])
        case idx
        when 0 then c.upstream_disconnected
        when 1 then upstream.client_disconnected
        end
      end
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      @log.debug { "Client connection error from #{remote_address}: #{ex.inspect}" }
    ensure
      @log.debug { "Client connection closed from #{remote_address}" }
      socket.close
      @client_connections -= 1
    end
  end
end
