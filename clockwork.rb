require 'clockwork'
require 'httparty'
require 'dotenv'

Dotenv.load

PUSH_URL = ENV["PUSH_URL"]
PUSH_USERNAME = ENV["PUSH_USERNAME"]
PUSH_PASSWORD = ENV["PUSH_PASSWORD"]

PREDICTIONS_URL = ENV["PREDICTIONS_URL"]

POLL_INTERVAL = ENV["POLL_INTERVAL"].to_i
POLL_WINDOW = ENV["POLL_WINDOW"].to_i

module Clockwork
  handler do |job, time|
    puts "Running #{job} at #{time}"

    tags = get_tags()
    puts "Found tags: #{tags}"

    routes_and_stops = get_routes_and_stops_from_tags(tags)
    puts "Found routes and stops: #{routes_and_stops}"

    predictions = get_predictions_for_routes_and_stops(routes_and_stops)
    puts "Found predictions: #{predictions}"

    matches = get_matches(tags, predictions)
    puts "Found matches: #{matches}"

    send_notifications_for_matches(matches)
  end

  every(POLL_INTERVAL.minute, 'updates')
end

def get_tags()
  tags_url = "#{PUSH_URL}/v1/tags"

  response = HTTParty.get tags_url,
    basic_auth: { username: PUSH_USERNAME, password: PUSH_PASSWORD },
    verify: false

  JSON.parse(response.body)["tags"].select do |tag|
    time, route, stop = tag.split("_")

    [
      (Time.strptime(time, "%H%M") rescue false),
      !route.nil?,
      !stop.nil?
    ].all?
  end
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

    begin
      response = HTTParty.get route_url
    rescue Exception => e
      puts "Skipping prediction for route:#{route} and stop:#{stop}"
      puts e.message
      next
    end

    puts "Response for #{route} and #{stop}: #{response.code} - #{response.body}"
    if (response.code != 200)
      puts "Skipping #{route}"
      next
    end

    response["directions"].map do |direction|
      direction["predictions"].map do |prediction|
        time = Time.at(prediction["time"].to_f/1000).strftime("%H%M")

        "#{time}_#{route}_#{stop}" unless time.nil?
      end
    end
  end.flatten.compact.uniq
end

def get_matches(tags, predictions)
  {}.tap do |matches|
    tags.each do |tag|
      next_prediction = predictions.detect do |prediction|
        matches? tag, prediction
      end

      matches[tag] = next_prediction if next_prediction
    end
  end
end

def matches? tag, prediction
  tag_time, tag_route, tag_stop = tag.split("_")
  prediction_time, prediction_route, prediction_stop = prediction.split("_")

  delta = (Time.strptime(tag_time, "%H%M") - Time.strptime(prediction_time, "%H%M")).to_i/60

  return false unless prediction_route == tag_route
  return false unless prediction_stop == tag_stop
  return false unless delta >= 0 && delta <= 15

  true
end

def send_notifications_for_matches(matches)
  notifications_url = "#{PUSH_URL}/v1/push"

  matches.each do |tag, prediction|
    time, route, stop = prediction.split('_')
    time_string = (Time.strptime(time, "%H%M") + Time.now.utc_offset - Time.now).to_i / 60
    message = "Bus #{route} coming in #{time_string} minutes to stop ##{stop}"
    puts message

    response = HTTParty.post notifications_url,
      body: {
        message: {
          body: message
        },
        target: {
          tags: [ tag ]
        }
      }.to_json,
      headers: {
        "Content-type" => "application/json"
      },
      basic_auth: { username: PUSH_USERNAME, password: PUSH_PASSWORD },
      verify: false

    puts "Sent notification to #{tag}: #{message} - #{response.code} - #{response.body}"
  end
end

