#!/usr/bin/ruby
#
# lastfmproxy-rb
#
# An HTTP stream proxy for last.fm radio.
#
# You must be a last.fm subscriber and must get an API Key from last.fm, or
# this will not work. See http://last.fm/api for the API Key application.
#
# Clients currently tested: SqueezeBox.
#
# ----------------------------------------------------------------------------
# Copyright (c) 2009 Christian Hofstaedtler <ch+lastfmproxy@zeha.at>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
# ----------------------------------------------------------------------------
#
# Configuration:
# Copy the following section to ./config.rb and edit it there.
config = {
  :username => 'USERNAME',
  :password => 'PASSWORD',
  :station => 'lastfm://artist/moloko/similarartists',
  :api_key => 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
  :api_secret => 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
}
# ----------------------------------------------------------------------------
#
# don't need to change anything below
#


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
  attr_reader :location, :title, :album, :creator, :duration, :artistpage, :trackpage
  def initialize(args)
    @location = args[:location]
    @title = args[:title]
    @album = args[:album]
    @creator = args[:creator]
    @duration = args[:duration]
    @artistpage = args[:artistpage]
    @trackpage = args[:trackpage]
  end
end

class LastFmWebservice
  attr_accessor :radio_tracks, :sk
  attr_reader :radio_title

  def initialize(api_key, api_secret)
    @api_key = api_key
    @api_secret = api_secret
    @sk = nil
    @radio_tracks = nil
    @radio_title = nil
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

    http = Net::HTTP.new('ws.audioscrobbler.com')
    if readwrite == :read
      uri = "/2.0/?" + args_string
      rsp = http.get(uri)
    elsif readwrite == :write
      uri = "/2.0/"
      rsp = http.post(uri, args_string)
    else
      raise "Unknown readwrite '%s' specified" % readwrite.to_s
    end
    LastFmResponse.new(rsp.body)
  end

  def handle_error(response)
    puts "ERROR ERROR ERROR ERROR ERROR ERROR"
    puts "XML Response: %s" % response.xml.to_s
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
    @radio_title = station
    @radio_title = r[:name] if r.has_key?(:name)
    r
  end

  def radio_getPlaylist(rtp, discovery)
    response = request('radio.getPlaylist', :read, {:rtp => rtp, :discovery => discovery})
    handle_error(response) unless response.status
    @radio_tracks = [] if @radio_tracks.nil?
    response.xml.elements.each('lfm/playlist/title') do |elem|
      @radio_title = elem.text if !elem.text.nil?
    end
    puts "fetched new tracks for radio %s" % @radio_title
    response.xml.elements.each('lfm/playlist/trackList/track') do |track|
      args = {}
      track.elements.each do |elem|
        if elem.name == 'extension'
          elem.elements.each do |extelem|
            args[extelem.name.to_sym] = extelem.text
          end
        else
          args[elem.name.to_sym] = elem.text
        end
      end
      @radio_tracks << LastFmTrack.new(args)
    end
    @last_radio_rtp = rtp
    @last_radio_discovery = discovery
    response
  end

  def radio_nextTrack()
    if @radio_tracks.nil? or @radio_tracks.length < 2
      response = radio_getPlaylist(@last_radio_rtp, @last_radio_discovery)
      if @radio_tracks.nil? or @radio_tracks.length == 0
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

class LastFmProxyServer < WEBrick::GenericServer
  attr_accessor :default_radio_station
  def initialize(lastfm, args)
    @lastfm = lastfm
    @want_shutdown = false
    @default_radio_station = nil
    @metadata_interval = 8192
    @bitrate = 128
    super(args)
  end
  def run(sock)
    begin
      sock.read_nonblock(2000)
    rescue
    end

    radio_station = @default_radio_station
    puts ""
    puts ""
    puts "Starting radio (URL %s) ..." % radio_station
    @lastfm.radio_tune(radio_station)
    @lastfm.radio_getPlaylist(0, 0)

    sock.print "ICY 200 OK\r\n"
    sock.print "Content-Type: audio/mpeg\r\n"
    sock.print "icy-notice1: This stream requires <a href=\"http://www.winamp.com/\">Winamp</a>\r\n"
    sock.print "icy-notice2: lastfmproxy-rb\r\n"
    sock.print "icy-name: Last.FM: %s\r\n" % @lastfm.radio_title
    sock.print "icy-url: %s\r\n" % radio_station
    sock.print "icy-genre: Unknown Genre\r\n"
    sock.print "icy-pub: 0\r\n"
    sock.print "icy-br: %d\r\n" % @bitrate
    sock.print "\r\n"
    track = 0
    while !track.nil? and !@want_shutdown do
      track = @lastfm.radio_nextTrack do |error|
        puts "error:"
        puts error.xml
        exit
      end
      puts ""
      puts "playing: %s - %s" % [track.creator, track.title]
      puts "artist info: %s" % track.artistpage
      puts "track info: %s" % track.trackpage
      puts ""
      fetch_and_send_track track.location, track, sock
    end
    puts "Quitting radio."
  end
  def shutdown
    exit if @want_shutdown
    @want_shutdown = true
    super()
  end

  # the real main method
  def LastFmProxyServer.main(config)
    if File.exists?('./config.rb')
      eval(File.read('./config.rb'))
    end

    lfm = LastFmWebservice.new(config[:api_key], config[:api_secret])
    lfm.auth(config[:username], config[:password])

    server = LastFmProxyServer.new( lfm, :Port => 2000 )
    server.default_radio_station = config[:station]
    puts "Default radio station: %s" % server.default_radio_station
    trap("INT") {
      puts "(caught SIGINT, shutting down; do it again to try harder)"
      server.shutdown
    }
    server.start
  end

  private

  def fetch_and_send_track(uri_str, track, sock, limit = 10, &block)
    raise ArgumentError, 'HTTP redirect too deep' if limit == 0
    puts 'fetching from %s' % uri_str
    uri = URI.parse(uri_str)
    http = Net::HTTP.new(uri.host, uri.port)

    len = 0
    no_more = false
    headers = { 'Accept' => 'audio/mpeg', 'User-Agent' => 'lastfmproxy-rb' }
    begin
      response = http.get uri.path, headers do |segment|
        return if no_more
        if @want_shutdown
          no_more = true
          http.finish
        end
        begin
          sock.write segment
          sock.flush
        rescue => detail
          puts detail
          no_more = true
          http.finish
        end
        len = len + segment.length
        $stdout.write "\r   %d bytes already...       " % len if len > 0
      end
      puts "\r\n"
    rescue => detail
      case detail
      when IOError then return
      else
        puts detail
        return
      end
    end
    case response
    when Net::HTTPSuccess     then response
    when Net::HTTPRedirection then fetch_and_send_track(response['location'], track, sock, limit - 1, &block)
    else
      response.error!
    end
  end

end

LastFmProxyServer.main config if $0 == __FILE__

