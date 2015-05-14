require 'clockwork'
require 'httparty'
require 'dotenv'
require 'time_difference'
require 'active_support/time'

Dotenv.load

PUSH_URL = ENV["PUSH_URL"]
PUSH_USERNAME = ENV["PUSH_USERNAME"]
PUSH_PASSWORD = ENV["PUSH_PASSWORD"]

PREDICTIONS_URL = ENV["PREDICTIONS_URL"]
SERVICE_ALERTS_URL = ENV["SERVICE_ALERTS_URL"]

POLL_INTERVAL = ENV["POLL_INTERVAL"].to_i
POLL_WINDOW = ENV["POLL_WINDOW"].to_i

DEFAULT_TIME_ZONE = ENV["DEFAULT_TIME_ZONE"]

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

    create_service_alerts_tag

    alerts = get_alerts()
    send_notifications_for_alerts(alerts)
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

    if route.nil? || stop.nil? || route == "null" || stop == "null" || route == "<null>" || stop == "<null>"
      puts "Skipping route and stop : /stop/#{stop}/route/#{route}"
      next
    end

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

    if response["directions"].nil?
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

  # Get the differene between the hours/minutes, it doesn't matter what timezone (they will be the same timezone)
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

    puts "Time: #{time}, Route: #{route}, Stop: #{stop}"

    # For clarity, these now have the same timezone and uses the "time_difference" gem
    time_difference_in_minutes = TimeDifference.between(
      Time.strptime("#{time}", "%H%M").in_time_zone(DEFAULT_TIME_ZONE),
      Time.now.in_time_zone(DEFAULT_TIME_ZONE)
    ).in_minutes.round

    message = "Bus #{route} coming in #{time_difference_in_minutes} minutes to stop ##{stop}"

    if time_difference_in_minutes < 0 
      puts "Bad time_difference_in_minutes: #{time_difference_in_minutes}, not sending notification"
      next
    end

    puts "Sending push with message: #{message}"
    
    response = HTTParty.post notifications_url,
      body: {
        message: {
          body: message,
          custom: {
            ios: {
              "content-available" => true
            },
          },
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

def get_alerts()
    begin
      response = HTTParty.get SERVICE_ALERTS_URL
    rescue Exception => e
      puts "Error getting service alerts: #{e.message}"
      return nil
    end

    alerts = []

    JSON.parse(response.body)["alerts"].select do |alert|
      puts "Found alert #{alert}"
      desc = alert["description"]
      unless desc.nil?
        alerts.push(desc.strip.gsub("\n", "").gsub("\t",""))
      end
    end

    alerts
end

def create_service_alerts_tag
  response = HTTParty.post "#{PUSH_URL}/v1/tags/service_alerts",
      headers: {
        "Content-type" => "application/json"
      },
      basic_auth: { username: PUSH_USERNAME, password: PUSH_PASSWORD },
      verify: false

  puts "Creating service alerts, code: #{response.code}, body: #{response.body}"
end

def send_notifications_for_alerts(alerts)
  return if alerts.nil? || alerts.empty?

  notifications_url = "#{PUSH_URL}/v1/push"

  alerts.each do |alert|
    puts "Sending service alert notification: #{alert}"

    message = "Service Alert: #{alert}"

    response = HTTParty.post notifications_url,
      body: {
        message: {
          body: message,
          custom: {
            ios: {
              "content-available" => true
            },
          },
        },
        target: {
          tags: [ "service_alerts" ]
        }
      }.to_json,
      headers: {
        "Content-type" => "application/json"
      },
      basic_auth: { username: PUSH_USERNAME, password: PUSH_PASSWORD },
      verify: false

    puts "Sent notification to service_alerts: #{message} - #{response.code} - #{response.body}"
  end

end
