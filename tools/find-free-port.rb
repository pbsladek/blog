#!/usr/bin/env ruby

require "set"
require "socket"

host = ARGV.fetch(0)
start = Integer(ARGV.fetch(1))
limit = start + 100

docker_ports = Set.new

begin
  docker_output = IO.popen(["docker", "ps", "--format", "{{.Ports}}"], err: File::NULL, &:read)
  docker_output.scan(/(?:^|,\s)(?:[^,\s]*:)?(\d+)->/) do |match|
    docker_ports.add(Integer(match.first))
  end
rescue SystemCallError
  # Docker may not be running or available. The socket bind check below still
  # handles ordinary host processes.
end

port = (start..limit).find do |candidate|
  next false if docker_ports.include?(candidate)

  begin
    server = TCPServer.new(host, candidate)
    server.close
    true
  rescue SystemCallError
    false
  end
end

abort "No free port found from #{start} to #{limit}" unless port

puts port
