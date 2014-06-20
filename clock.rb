require 'clockwork'
require 'httparty'

PUSH_URL = "https://push-notifications.sherry.wine.cf-app.com:443"
PUSH_USERNAME = "6c0cb5a6-1244-4ed0-9618-d2957f85a401"
PUSH_PASSWORD = "e910e5ee-7ef9-4d81-8a33-8f70f7aac808"

PREDICTIONS_URL = "http://nextbus.main.vchs.cfms-apps.com/ttc/predictions"

module Clockwork
  handler do |job, time|
    puts "Running #{job} at #{time}"

    tags = get_tags()

    puts "Found tags: #{tags}"

    routes = get_routes_from_tags(tags)

    puts "Found routes: #{routes}"

    predictions = get_predictions_for_routes(routes)

    puts "Found predictions: #{predictions}"
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

def get_routes_from_tags(tags)
  tags.map do |tag|
    delta, route = tag.split("_")

    route
  end.compact.uniq
end

def get_predictions_for_routes(routes)
  routes.map do |route|
    route_url = "#{PREDICTIONS_URL}/#{route}"
    response = HTTParty.get route_url

    puts "Response for #{route}: #{response.code} - #{response.body}"
    if (response.code != 200)
      puts "Skipping #{route}"
      next
    end

    response["directions"].map do |direction|
      direction["predictions"].map do |prediction|
        minutes = prediction["minutes"]

        "#{minutes}_#{route}" unless minutes.nil?
      end
    end
  end.flatten.compact.uniq
end

