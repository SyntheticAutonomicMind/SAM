// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

/// MCP Tool for Weather data via Open-Meteo API.
/// Free, no API key required. Uses SAM's LocationManager for coordinates.
public class WeatherTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "weather_operations"

    public let description = """
    Get weather information using the Open-Meteo API (free, no API key needed).
    Uses SAM's configured location or accepts coordinates/city name.

    OPERATIONS:
    • current - Get current weather conditions (optional: latitude, longitude, city)
    • forecast - Get weather forecast (optional: latitude, longitude, city, days)
    • hourly - Get hourly forecast for today (optional: latitude, longitude, city, hours)

    Location Resolution (in order of priority):
    1. Explicit latitude/longitude parameters
    2. City name (geocoded via Open-Meteo)
    3. SAM's configured location from Preferences

    Temperature is returned in both Fahrenheit and Celsius.
    """

    public var supportedOperations: [String] {
        return ["current", "forecast", "hourly"]
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "operation": MCPToolParameter(
                type: .string,
                description: "Weather operation to perform",
                required: true,
                enumValues: supportedOperations
            ),
            "latitude": MCPToolParameter(
                type: .number,
                description: "Location latitude (optional if city or SAM location configured)",
                required: false
            ),
            "longitude": MCPToolParameter(
                type: .number,
                description: "Location longitude (optional if city or SAM location configured)",
                required: false
            ),
            "city": MCPToolParameter(
                type: .string,
                description: "City name to look up (e.g., 'Austin, TX' or 'London')",
                required: false
            ),
            "days": MCPToolParameter(
                type: .integer,
                description: "Number of forecast days (default: 7, max: 16)",
                required: false
            ),
            "hours": MCPToolParameter(
                type: .integer,
                description: "Number of hourly forecast hours (default: 24)",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.weather")

    @MainActor
    public func initialize() async throws {
        logger.debug("WeatherTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard parameters["operation"] is String else {
            throw MCPError.invalidParameters("Missing 'operation' parameter")
        }
        return true
    }

    @MainActor
    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        switch operation {
        case "current":
            return await getCurrentWeather(parameters: parameters)
        case "forecast":
            return await getForecast(parameters: parameters)
        case "hourly":
            return await getHourlyForecast(parameters: parameters)
        default:
            return operationError(operation, message: "Unknown operation")
        }
    }

    // MARK: - Location Resolution

    private struct Coordinates {
        let latitude: Double
        let longitude: Double
        let name: String
    }

    @MainActor
    private func resolveLocation(parameters: [String: Any]) async -> Coordinates? {
        // 1. Explicit coordinates
        if let lat = parameters["latitude"] as? Double, let lon = parameters["longitude"] as? Double {
            return Coordinates(latitude: lat, longitude: lon, name: "(\(lat), \(lon))")
        }

        // 2. City name geocoding
        if let city = parameters["city"] as? String {
            if let coords = await geocodeCity(city) {
                return coords
            }
        }

        // 3. SAM's configured location
        let locationManager = LocationManager.shared
        if let location = locationManager.getEffectiveLocation() {
            if let coords = await geocodeCity(location) {
                return coords
            }
        }

        return nil
    }

    private func geocodeCity(_ city: String) async -> Coordinates? {
        let encoded = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? city
        let urlString = "https://geocoding-api.open-meteo.com/v1/search?name=\(encoded)&count=1&language=en&format=json"

        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]],
               let first = results.first,
               let lat = first["latitude"] as? Double,
               let lon = first["longitude"] as? Double {
                let name = first["name"] as? String ?? city
                let country = first["country"] as? String ?? ""
                let admin = first["admin1"] as? String ?? ""
                let displayName = [name, admin, country].filter { !$0.isEmpty }.joined(separator: ", ")
                return Coordinates(latitude: lat, longitude: lon, name: displayName)
            }
        } catch {
            logger.error("Geocoding failed for '\(city)': \(error)")
        }

        return nil
    }

    // MARK: - API Requests

    private func fetchJSON(url: URL) async -> [String: Any]? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            logger.error("Weather API request failed: \(error)")
            return nil
        }
    }

    // MARK: - Weather Code Descriptions

    private func weatherDescription(code: Int) -> String {
        switch code {
        case 0: return "Clear sky"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45: return "Foggy"
        case 48: return "Depositing rime fog"
        case 51: return "Light drizzle"
        case 53: return "Moderate drizzle"
        case 55: return "Dense drizzle"
        case 56: return "Light freezing drizzle"
        case 57: return "Dense freezing drizzle"
        case 61: return "Slight rain"
        case 63: return "Moderate rain"
        case 65: return "Heavy rain"
        case 66: return "Light freezing rain"
        case 67: return "Heavy freezing rain"
        case 71: return "Slight snowfall"
        case 73: return "Moderate snowfall"
        case 75: return "Heavy snowfall"
        case 77: return "Snow grains"
        case 80: return "Slight rain showers"
        case 81: return "Moderate rain showers"
        case 82: return "Violent rain showers"
        case 85: return "Slight snow showers"
        case 86: return "Heavy snow showers"
        case 95: return "Thunderstorm"
        case 96: return "Thunderstorm with slight hail"
        case 99: return "Thunderstorm with heavy hail"
        default: return "Unknown (\(code))"
        }
    }

    private func weatherEmoji(code: Int) -> String {
        switch code {
        case 0: return "☀️"
        case 1: return "🌤️"
        case 2: return "⛅"
        case 3: return "☁️"
        case 45, 48: return "🌫️"
        case 51, 53, 55: return "🌦️"
        case 56, 57: return "🌧️"
        case 61, 63: return "🌧️"
        case 65: return "🌧️"
        case 66, 67: return "🧊"
        case 71, 73, 75, 77: return "❄️"
        case 80, 81, 82: return "🌧️"
        case 85, 86: return "🌨️"
        case 95, 96, 99: return "⛈️"
        default: return "🌡️"
        }
    }

    private func celsiusToFahrenheit(_ c: Double) -> Double {
        return c * 9.0 / 5.0 + 32.0
    }

    private func formatTemp(_ celsius: Double) -> String {
        let f = celsiusToFahrenheit(celsius)
        return String(format: "%.0f°F (%.0f°C)", f, celsius)
    }

    // MARK: - Operations

    @MainActor
    private func getCurrentWeather(parameters: [String: Any]) async -> MCPToolResult {
        guard let coords = await resolveLocation(parameters: parameters) else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Could not determine location. Provide city name, coordinates, or configure location in SAM Preferences."))
        }

        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(coords.latitude)&longitude=\(coords.longitude)&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m,precipitation,cloud_cover,surface_pressure&temperature_unit=celsius&wind_speed_unit=mph&precipitation_unit=inch&timezone=auto"

        guard let url = URL(string: urlString),
              let json = await fetchJSON(url: url) else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to fetch weather data."))
        }

        guard let current = json["current"] as? [String: Any] else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Invalid weather data received."))
        }

        let temp = current["temperature_2m"] as? Double ?? 0
        let feelsLike = current["apparent_temperature"] as? Double ?? 0
        let humidity = current["relative_humidity_2m"] as? Int ?? 0
        let weatherCode = current["weather_code"] as? Int ?? 0
        let windSpeed = current["wind_speed_10m"] as? Double ?? 0
        let windGusts = current["wind_gusts_10m"] as? Double ?? 0
        let windDir = current["wind_direction_10m"] as? Int ?? 0
        let precip = current["precipitation"] as? Double ?? 0
        let clouds = current["cloud_cover"] as? Int ?? 0
        let pressure = current["surface_pressure"] as? Double ?? 0

        let emoji = weatherEmoji(code: weatherCode)
        var output = "\(emoji) **Current Weather for \(coords.name)**\n\n"
        output += "**\(weatherDescription(code: weatherCode))**\n\n"
        output += "Temperature: \(formatTemp(temp))\n"
        output += "Feels Like: \(formatTemp(feelsLike))\n"
        output += "Humidity: \(humidity)%\n"
        output += "Wind: \(String(format: "%.0f", windSpeed)) mph from \(compassDirection(degrees: windDir))"
        if windGusts > windSpeed + 5 {
            output += " (gusts \(String(format: "%.0f", windGusts)) mph)"
        }
        output += "\n"
        output += "Cloud Cover: \(clouds)%\n"
        if precip > 0 {
            output += "Precipitation: \(String(format: "%.2f", precip)) in\n"
        }
        output += "Pressure: \(String(format: "%.1f", pressure)) hPa\n"

        return MCPToolResult(success: true, output: MCPOutput(content: output))
    }

    @MainActor
    private func getForecast(parameters: [String: Any]) async -> MCPToolResult {
        guard let coords = await resolveLocation(parameters: parameters) else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Could not determine location. Provide city name, coordinates, or configure location in SAM Preferences."))
        }

        let days = min(parameters["days"] as? Int ?? 7, 16)

        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(coords.latitude)&longitude=\(coords.longitude)&daily=weather_code,temperature_2m_max,temperature_2m_min,apparent_temperature_max,apparent_temperature_min,precipitation_sum,precipitation_probability_max,wind_speed_10m_max,sunrise,sunset&temperature_unit=celsius&wind_speed_unit=mph&precipitation_unit=inch&timezone=auto&forecast_days=\(days)"

        guard let url = URL(string: urlString),
              let json = await fetchJSON(url: url) else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to fetch forecast data."))
        }

        guard let daily = json["daily"] as? [String: Any],
              let dates = daily["time"] as? [String],
              let codes = daily["weather_code"] as? [Int],
              let maxTemps = daily["temperature_2m_max"] as? [Double],
              let minTemps = daily["temperature_2m_min"] as? [Double] else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Invalid forecast data received."))
        }

        let precipProb = daily["precipitation_probability_max"] as? [Int] ?? []
        let precipSum = daily["precipitation_sum"] as? [Double] ?? []
        let windMax = daily["wind_speed_10m_max"] as? [Double] ?? []

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "EEEE, MMM d"

        var output = "**\(days)-Day Forecast for \(coords.name)**\n\n"

        for i in 0..<min(dates.count, days) {
            let emoji = weatherEmoji(code: codes[i])
            let dayName: String
            if let date = dateFormatter.date(from: dates[i]) {
                dayName = displayFormatter.string(from: date)
            } else {
                dayName = dates[i]
            }

            output += "\(emoji) **\(dayName)** - \(weatherDescription(code: codes[i]))\n"
            output += "  High: \(formatTemp(maxTemps[i])) / Low: \(formatTemp(minTemps[i]))\n"

            if i < precipProb.count && precipProb[i] > 0 {
                output += "  Precipitation: \(precipProb[i])% chance"
                if i < precipSum.count && precipSum[i] > 0 {
                    output += " (\(String(format: "%.2f", precipSum[i])) in)"
                }
                output += "\n"
            }
            if i < windMax.count {
                output += "  Wind: up to \(String(format: "%.0f", windMax[i])) mph\n"
            }
            output += "\n"
        }

        return MCPToolResult(success: true, output: MCPOutput(content: output))
    }

    @MainActor
    private func getHourlyForecast(parameters: [String: Any]) async -> MCPToolResult {
        guard let coords = await resolveLocation(parameters: parameters) else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Could not determine location. Provide city name, coordinates, or configure location in SAM Preferences."))
        }

        let hours = min(parameters["hours"] as? Int ?? 24, 48)

        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(coords.latitude)&longitude=\(coords.longitude)&hourly=temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,wind_speed_10m,relative_humidity_2m&temperature_unit=celsius&wind_speed_unit=mph&precipitation_unit=inch&timezone=auto&forecast_hours=\(hours)"

        guard let url = URL(string: urlString),
              let json = await fetchJSON(url: url) else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to fetch hourly forecast."))
        }

        guard let hourly = json["hourly"] as? [String: Any],
              let times = hourly["time"] as? [String],
              let temps = hourly["temperature_2m"] as? [Double],
              let codes = hourly["weather_code"] as? [Int] else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Invalid hourly data received."))
        }

        let precipProb = hourly["precipitation_probability"] as? [Int] ?? []
        let wind = hourly["wind_speed_10m"] as? [Double] ?? []
        let humidity = hourly["relative_humidity_2m"] as? [Int] ?? []

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "h a"

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE"

        var output = "**Hourly Forecast for \(coords.name)** (next \(hours) hours)\n\n"

        var lastDay = ""
        for i in 0..<min(times.count, hours) {
            let emoji = weatherEmoji(code: codes[i])
            let timeStr: String
            if let date = timeFormatter.date(from: times[i]) {
                let day = dayFormatter.string(from: date)
                if day != lastDay {
                    if !lastDay.isEmpty { output += "\n" }
                    output += "**\(day)**\n"
                    lastDay = day
                }
                timeStr = displayFormatter.string(from: date)
            } else {
                timeStr = times[i]
            }

            output += "\(emoji) \(timeStr): \(formatTemp(temps[i]))"
            if i < precipProb.count && precipProb[i] > 0 {
                output += " | Rain: \(precipProb[i])%"
            }
            if i < wind.count {
                output += " | Wind: \(String(format: "%.0f", wind[i])) mph"
            }
            if i < humidity.count {
                output += " | Humidity: \(humidity[i])%"
            }
            output += "\n"
        }

        return MCPToolResult(success: true, output: MCPOutput(content: output))
    }

    // MARK: - Helpers

    private func compassDirection(degrees: Int) -> String {
        let directions = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                          "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int(round(Double(degrees) / 22.5)) % 16
        return directions[index]
    }
}
