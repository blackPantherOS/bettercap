#!/usr/bin/env ruby

=begin

  BETTERCAP

  Author : Simone 'evilsocket' Margaritelli
  Email  : evilsocket@gmail.com
  Blog   : http://www.evilsocket.net/

  This project is released under the GPL 3 license.

=end

require 'optparse'
require 'colorize'
require 'packetfu'
require 'ipaddr'

Object.send :remove_const, :Config
Config = RbConfig

require_relative 'lib/context'

require_relative 'lib/monkey/packetfu/utils'
require_relative 'lib/factories/firewall_factory'
require_relative 'lib/factories/spoofer_factory'
require_relative 'lib/factories/parser_factory'
require_relative 'lib/logger'
require_relative 'lib/shell'
require_relative 'lib/network'
require_relative 'lib/version'
require_relative 'lib/target'
require_relative 'lib/sniffer/sniffer'
require_relative 'lib/proxy/request'
require_relative 'lib/proxy/response'
require_relative 'lib/proxy/proxy'
require_relative 'lib/proxy/module'

begin

  raise 'This software must run as root.' unless Process.uid == 0

  puts '---------------------------------------------------------'.yellow
  puts "                   BETTERCAP v#{BetterCap::VERSION}\n\n".green
  puts '          by Simone "evilsocket" Margaritelli'.green
  puts '                  evilsocket@gmail.com    '.green
  puts "---------------------------------------------------------\n\n".yellow

  ctx = Context.get

  OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} [options]"

    opts.on( '-I', '--interface IFACE', 'Network interface name - default: ' + ctx.options[:iface] ) do |v|
      ctx.options[:iface] = v
    end

    opts.on( '-S', '--spoofer NAME', 'Spoofer module to use, available: ' + SpooferFactory.available.join(', ') + ' - default: ' + ctx.options[:spoofer] ) do |v|
      ctx.options[:spoofer] = v
    end

    opts.on( '-T', '--target ADDRESS', 'Target ip address, if not specified the whole subnet will be targeted.' ) do |v|
      ctx.options[:target] = v
    end

    opts.on( '-O', '--log LOG_FILE', 'Log all messagges into a file, if not specified the log messages will be only print into the shell.' ) do |v|
      ctx.options[:logfile] = v
    end

    opts.on( '-D', '--debug', 'Enable debug logging.' ) do
      ctx.options[:debug] = true
    end

    opts.on( '-L', '--local', 'Parse packets coming from/to the address of this computer ( NOTE: Will set -X to true ), default to false.' ) do
      ctx.options[:local] = true
      ctx.options[:sniffer] = true      
    end

    opts.on( '-X', '--sniffer', 'Enable sniffer.' ) do
      ctx.options[:sniffer] = true
    end

    opts.on( '-P', '--parsers PARSERS', 'Comma separated list of packet parsers to enable, "*" for all ( NOTE: Will set -X to true ), available: ' + ParserFactory.available.join(', ') + ' - default: *' ) do |v|
      ctx.options[:sniffer] = true      
      ctx.options[:parsers] = ParserFactory.from_cmdline(v)
    end

    opts.on( '--no-discovery', 'Do not actively search for hosts, just use the current ARP cache, default to false.' ) do
      ctx.options[:arpcache] = true
    end

    opts.on( '--proxy', 'Enable HTTP proxy and redirects all HTTP requests to it, default to false.' ) do
      ctx.options[:proxy] = true
    end

    opts.on( '--proxy-port PORT', 'Set HTTP proxy port, default to ' + ctx.options[:proxy_port].to_s + ' .' ) do |v|
      ctx.options[:proxy_port] = v.to_i
    end

    opts.on( '--proxy-module MODULE', 'Ruby proxy module to load.' ) do |v|
      ctx.options[:proxy_module] = v
    end
  end.parse!

  Logger.debug_enabled = true unless !ctx.options[:debug]

  Logger.logfile = ctx.options[:logfile]

  ctx.update_network
  
  if ctx.options[:target].nil?
    Logger.info "Targeting the whole subnet #{ctx.network.to_range} ..."

    ctx.start_discovery_thread

  else
    raise "Invalid target '#{ctx.options[:target]}'" unless Network.is_ip? ctx.options[:target]

    ctx.targets = [ Target.new( ctx.options[:target], nil ) ]
  end

  ctx.spoofer = SpooferFactory.get_by_name( ctx.options[:spoofer] )

  Logger.info "  Local Address : #{ctx.iface[:ip_saddr]}"
  Logger.info "  Local MAC     : #{ctx.iface[:eth_saddr]}"
  Logger.info "  Gateway       : #{ctx.gateway}"

  Logger.debug "Module: #{ctx.options[:spoofer]}"

  ctx.spoofer.start

  if ctx.options[:proxy]
    ctx.firewall.add_port_redirection( ctx.options[:iface], 'TCP', 80, ctx.iface[:ip_saddr], ctx.options[:proxy_port] )

    if not ctx.options[:proxy_module].nil?
      require_relative ctx.options[:proxy_module] 
    
      Proxy::Module.register_modules 
      
      raise "#{ctx.options[:proxy_module]} is not a valid bettercap proxy module." unless !Proxy::Module.modules.empty?
    end
    
    ctx.proxy = Proxy::Proxy.new( ctx.iface[:ip_saddr], ctx.options[:proxy_port] ) do |request,response|
      if Proxy::Module.modules.empty?
        Logger.warn 'WARNING: No proxy module loaded, skipping request.'
      else
        # loop each loaded module and execute if enabled
        Proxy::Module.modules.each do |mod|
          if mod.is_enabled?
            mod.on_request request, response
          end
        end
      end
    end

    ctx.proxy.start
  end

  if ctx.options[:sniffer]
      Sniffer.start ctx
  else
      Logger.warn 'WARNING: Sniffer module was NOT enabled ( -X argument ), this will cause the MITM to run but no data to be collected.'

      loop do
        sleep 1
      end
  end

rescue SystemExit, Interrupt

  Logger.write "\n"

rescue Exception => e
  Logger.error e.message
  Logger.error e.backtrace.join("\n")

ensure
  ctx.finalize
end
