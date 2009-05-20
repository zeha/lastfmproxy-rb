#!/usr/bin/ruby

username = 'USERNAME'
password = 'PASSWORD'
station = 'lastfm://user/'+username+'/personal'
api_key = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
api_secret = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'

# don't need to change anything below

require 'net/http'
require 'uri'
require 'digest/md5'
require 'rexml/document'
require 'webrick'

class LastFmResponse
  attr_accessor :xml, :status
  def initialize(xml_data)
    @xml = REXML::Document.new(xml_data)
    @xml.elements.each('lfm') do |elem|
      if elem.attribute('status').to_s == 'ok'
        @status = true
      else
        @status = false
      end
    end
  end
end

class LastFmTrack
  attr_accessor :location, :title, :album, :creator, :duration
  def initialize(args)
    @location = args[:location]
    @title = args[:title]
    @album = args[:album]
    @creator = args[:creator]
    @duration = args[:duration]
  end
  def fetch(&block)
    fetch_uri(@location, &block)
  end
  private
  def fetch_uri(uri_str, limit = 10, &block)
    raise ArgumentError, 'HTTP redirect too deep' if limit == 0
    puts 'fetching from %s' % uri_str
    uri = URI.parse(uri_str)
    http = Net::HTTP.new(uri.host, uri.port)
    response = http.get(uri.path, &block)
    case response
    when Net::HTTPSuccess     then response
    when Net::HTTPRedirection then fetch_uri(response['location'], limit - 1, &block)
    else
      response.error!
    end
  end
end

class LastFmWebservice
  attr_accessor :radio_tracks, :sk

  def initialize(api_key, api_secret)
    @http = Net::HTTP.new('ws.audioscrobbler.com')
    @api_key = api_key
    @api_secret = api_secret
    @sk = nil
    @radio_tracks = nil
    @last_radio_rtp = nil
    @last_radio_discovery = nil
  end

  def request(method, readwrite, args = {})
    args[:method] = method
    args[:api_key] = @api_key
    args[:sk] = @sk unless @sk.nil?

    # build the args_string, including signing string
    args_string = ""
    signing_string = ""
    arg_keys = []
    args.keys.each {|k| arg_keys << k.to_s }
    arg_keys.sort!
    arg_keys.each do |k|
      v = args[k.to_sym]
      args_string = "%s&%s=%s" % [args_string, k.to_s, v.to_s]
      signing_string = signing_string + k.to_s + v.to_s
    end
    signing_string = signing_string + @api_secret
    # add signature
    args_string = "%s&api_sig=%s" % [args_string, Digest::MD5.hexdigest(signing_string)]
    # escape
    args_string = URI.escape(args_string)

    if readwrite == :read
      uri = "/2.0/?" + args_string
      rsp = @http.get(uri)
    elsif readwrite == :write
      uri = "/2.0/"
      rsp = @http.post(uri, args_string)
    else
      raise "Unknown readwrite '%s' specified" % readwrite.to_s
    end
    LastFmResponse.new(rsp.body)
  end

  def handle_error(response)
    puts "ERROR ERROR ERROR ERROR ERROR ERROR"
    puts response
    puts "-----------------------------------"
    raise response.xml.to_s
  end

  def auth(username, password)
    authtoken = Digest::MD5.hexdigest('%s%s' % [username, Digest::MD5.hexdigest(password)])
    response = request('auth.getMobileSession', :read, {:username => username, :authToken => authtoken})
    handle_error(response) unless response.status
    response.xml.elements.each('lfm/session/key') do |elem|
      @sk = elem.text
    end
  end

  def radio_tune(station)
    response = request('radio.tune', :write, {:station => station})
    handle_error(response) unless response.status
    r = {}
    response.xml.elements.each('lfm/station') do |stations|
      stations.elements.each do |elem|
        r[elem.name.to_sym] = elem.text
      end
    end
    r
  end

  def radio_getPlaylist(rtp, discovery)
    puts "fetching new tracks"
    response = request('radio.getPlaylist', :read, {:rtp => rtp, :discovery => discovery})
    handle_error(response) unless response.status
    @radio_tracks = [] if @radio_tracks.nil?
    response.xml.elements.each('lfm/playlist/trackList/track') do |track|
      args = {}
      track.elements.each do |elem|
        args[elem.name.to_sym] = elem.text
      end
      @radio_tracks << LastFmTrack.new(args)
    end
    @last_radio_rtp = rtp
    @last_radio_discovery = discovery
    response
  end

  def radio_nextTrack()
    if @radio_tracks.nil? or @radio_tracks.count < 2
      response = radio_getPlaylist(@last_radio_rtp, @last_radio_discovery)
      if @radio_tracks.nil? or @radio_tracks.count == 0
        begin
          yield response
        rescue
        end
        return nil
      end
    end
    @radio_tracks.shift
  end

end

class LastFmWebserver < WEBrick::GenericServer
  def initialize(lastfm, args)
    @lastfm = lastfm
    @want_shutdown = false
    super(args)
  end
  def run(sock)
    begin
      sock.read_nonblock(2000)
    rescue
    end
    sock.print "HTTP/1.0 200 OK\r\n"
    sock.print "Connection: close\r\n"
    sock.print "Content-Type: audio/mpeg\r\n"
    sock.print "\r\n"
    track = 0
    while !track.nil? and !@want_shutdown do
      track = @lastfm.radio_nextTrack do |error|
        puts "error:"
        puts error.xml
        exit
      end
      puts "playing: %s" % track.title
      puts ""
      len = 0
      track.fetch do |segment|
        sock.write segment
        sock.flush
        len = len + segment.length
        $stdout.write "\r %d bytes already..." % len if len > 0
      end
      puts "\r"
    end
  end
  def shutdown
    @want_shutdown = true
    super()
  end
end

lfm = LastFmWebservice.new(api_key, api_secret)
lfm.auth(username, password)
lfm.radio_tune(station)

server = LastFmWebserver.new( lfm, :Port => 2000 )
trap("INT") { server.shutdown }
server.start

