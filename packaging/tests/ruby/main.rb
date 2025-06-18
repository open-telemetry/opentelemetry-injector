
require 'sinatra'
require 'uri'
require 'net/http'

uri = URI('http://localhost:4567/hello')
Thread.new do
  sleep 1
  while true do
    resp = Net::HTTP.get_response(uri)
    puts resp
    sleep 1
  end
end

get '/hello' do
  'Hello there!'
end


