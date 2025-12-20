// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import CoreLocation
import Logging

private let logger = Logger(label: "com.sam.locationmanager")

/// Manages user location settings for SAM
/// Provides both manual location entry and optional precise location via Core Location
@MainActor
public class LocationManager: NSObject, ObservableObject {
    public static let shared = LocationManager()

    // MARK: - Published Properties

    /// User's manually entered general location (e.g., "Austin, TX")
    @Published public var generalLocation: String {
        didSet {
            UserDefaults.standard.set(generalLocation, forKey: "user.generalLocation")
        }
    }

    /// Whether to use precise location from device
    @Published public var usePreciseLocation: Bool {
        didSet {
            UserDefaults.standard.set(usePreciseLocation, forKey: "user.usePreciseLocation")
            if usePreciseLocation {
                requestLocationPermission()
            } else {
                stopLocationUpdates()
                preciseLocationString = nil
                UserDefaults.standard.removeObject(forKey: "user.preciseLocationString")
            }
        }
    }

    /// Current precise location string (e.g., "Downtown Austin, Travis County, TX")
    @Published public var preciseLocationString: String? {
        didSet {
            // Save to UserDefaults for thread-safe access from SystemPromptConfiguration
            if let location = preciseLocationString {
                UserDefaults.standard.set(location, forKey: "user.preciseLocationString")
            } else {
                UserDefaults.standard.removeObject(forKey: "user.preciseLocationString")
            }
        }
    }

    /// Location authorization status
    @Published public var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Whether location is currently being fetched
    @Published public var isFetchingLocation: Bool = false

    /// Last error message
    @Published public var lastError: String?

    // MARK: - Private Properties

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()

    // MARK: - Initialization

    private override init() {
        self.generalLocation = UserDefaults.standard.string(forKey: "user.generalLocation") ?? ""
        self.usePreciseLocation = UserDefaults.standard.bool(forKey: "user.usePreciseLocation")

        super.init()

        // Load cached precise location string
        self.preciseLocationString = UserDefaults.standard.string(forKey: "user.preciseLocationString")

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer // City-level accuracy
        authorizationStatus = locationManager.authorizationStatus

        if usePreciseLocation && authorizationStatus == .authorized {
            requestSingleLocationUpdate()
        }
    }

    // MARK: - Public Methods

    /// Get the effective location string for use in prompts
    /// Returns precise location if enabled and available, otherwise general location
    public func getEffectiveLocation() -> String? {
        if usePreciseLocation, let precise = preciseLocationString {
            return precise
        }

        if !generalLocation.isEmpty {
            return generalLocation
        }

        return nil
    }

    /// Get formatted location context for injection into user messages
    public func getLocationContext() -> String? {
        guard let location = getEffectiveLocation() else { return nil }
        return "User's location: \(location)"
    }

    /// Request location permission from the user
    public func requestLocationPermission() {
        logger.info("Requesting location authorization")
        locationManager.requestWhenInUseAuthorization()
    }

    /// Request a single location update
    public func requestSingleLocationUpdate() {
        guard authorizationStatus == .authorized else {
            logger.warning("Cannot request location - not authorized")
            lastError = "Location access not authorized"
            return
        }

        isFetchingLocation = true
        lastError = nil
        locationManager.requestLocation()
    }

    /// Stop receiving location updates
    public func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
        isFetchingLocation = false
    }

    /// Refresh the current location
    public func refreshLocation() {
        if usePreciseLocation && authorizationStatus == .authorized {
            requestSingleLocationUpdate()
        }
    }

    // MARK: - Private Methods

    private func reverseGeocode(_ location: CLLocation) {
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            Task { @MainActor in
                guard let self = self else { return }

                self.isFetchingLocation = false

                if let error = error {
                    logger.error("Geocoding failed: \(error.localizedDescription)")
                    self.lastError = "Could not determine location name"
                    return
                }

                guard let placemark = placemarks?.first else {
                    self.lastError = "No location data available"
                    return
                }

                // Build a user-friendly location string
                var components: [String] = []

                if let locality = placemark.locality {
                    components.append(locality)
                }

                if let adminArea = placemark.administrativeArea {
                    components.append(adminArea)
                }

                if components.isEmpty {
                    if let country = placemark.country {
                        components.append(country)
                    }
                }

                if !components.isEmpty {
                    self.preciseLocationString = components.joined(separator: ", ")
                    logger.info("Location updated: \(self.preciseLocationString ?? "unknown")")
                } else {
                    self.lastError = "Could not determine location name"
                }
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            logger.debug("Received location update: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            reverseGeocode(location)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            logger.error("Location manager error: \(error.localizedDescription)")
            isFetchingLocation = false
            lastError = "Failed to get location: \(error.localizedDescription)"
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            authorizationStatus = status
            logger.info("Location authorization changed: \(String(describing: authorizationStatus.rawValue))")

            switch authorizationStatus {
            case .authorized:
                if usePreciseLocation {
                    requestSingleLocationUpdate()
                }
            case .denied, .restricted:
                preciseLocationString = nil
                usePreciseLocation = false
                lastError = "Location access denied"
            default:
                break
            }
        }
    }
}
