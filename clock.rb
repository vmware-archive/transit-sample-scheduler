require 'clockwork'
require 'httparty'

PUSH_URL = "https://push-notifications.sherry.wine.cf-app.com:443"
PUSH_USERNAME = "6c0cb5a6-1244-4ed0-9618-d2957f85a401"
PUSH_PASSWORD = "e910e5ee-7ef9-4d81-8a33-8f70f7aac808"

PREDICTIONS_URL = "http://nextbus.one.pepsi.cf-app.com/ttc/predictions"

module Clockwork
  handler do |job, time|
    puts "Running #{job} at #{time}"

    tags = get_tags()

    puts "Found tags: #{tags}"

    routes_and_stops = get_routes_and_stops_from_tags(tags)

    puts "Found routes and stops: #{routes_and_stops}"

    predictions = get_predictions_for_routes_and_stops(routes_and_stops)

    puts "Found predictions: #{predictions}"

    matches = tags & predictions

    puts "Found matches: #{matches}"

    send_notifications_for_matches(matches)
  end

  every(1.minute, 'updates')
end

def get_tags()
  tags_url = "#{PUSH_URL}/v1/tags"

  response = HTTParty.get tags_url,
    basic_auth: { username: PUSH_USERNAME, password: PUSH_PASSWORD },
    verify: false

  JSON.parse(response.body)["tags"]
end

def get_routes_and_stops_from_tags(tags)
  tags.map do |tag|
    delta, route, stop = tag.split("_")

    "#{route}_#{stop}"
  end.compact.uniq
end

def get_predictions_for_routes_and_stops(routes_and_stops)
  routes_and_stops.map do |route_and_stop|
    route, stop = route_and_stop.split("_")

    route_url = "#{PREDICTIONS_URL}/stop/#{stop}/route/#{route}"
    response = HTTParty.get route_url

    puts "Response for #{route}: #{response.code} - #{response.body}"
    if (response.code != 200)
      puts "Skipping #{route}"
      next
    end

    response["directions"].map do |direction|
      direction["predictions"].map do |prediction|
        minutes = prediction["minutes"]

        "#{minutes}_#{route}_#{stop}" unless minutes.nil?
      end
    end
  end.flatten.compact.uniq
end

def send_notifications_for_matches(matches)
  notifications_url = "#{PUSH_URL}/v1/push"

  matches.each do |match|
    time, route, stop = match.split('_')

    response = HTTParty.post notifications_url,
      body: {
        message: {
          body: "Bus #{route} coming in #{time} minutes to stop ##{stop}"
        },
        target: {
          tags: [ match ]
        }
      }.to_json,
      headers: {
        "Content-type" => "application/json"
      },
      basic_auth: { username: PUSH_USERNAME, password: PUSH_PASSWORD },
      verify: false

    puts "Sent notification to #{match}: #{response.code} - #{response.body}"
  end
end

