//
//  LocationModel.swift
//  Cellular
//
//  Created by Xuan Han on 2/9/23.
//

import Foundation
import CoreLocation

/**
 This class handles the checking of the Location Services permission.
 */
class LocationModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var onAuthorized: () -> Void = {}
    private var onError: () -> Void = {}
    private var authorizationStatus: CLAuthorizationStatus?
    
    @Published var isLocationPermissionDenied = true
    
    override init() {
        super.init()
        locationManager.delegate = self
    }
    
    /**
     This function registers methods to be called when the Location Services permission changes.
     - parameter onAuthorized: The method to be called when the permission is authorised.
     - parameter onError: The method to be called when the permission is restricted or denied.
     */
    func registerForAuthorizationChanges(onAuthorized: @escaping () -> Void, onError: @escaping () -> Void) {
        self.onAuthorized = onAuthorized
        self.onError = onError
        
        // The authorisation status may have been delivered before these methods were registered
        if let authorizationStatus {
            handleAuthorizationStatus(authorizationStatus)
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        handleAuthorizationStatus(manager.authorizationStatus)
    }
    
    private func handleAuthorizationStatus(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorized:           // Location services are available.
            isLocationPermissionDenied = false
            onAuthorized()
            break
        
        case .restricted, .denied:  // Location services currently unavailable.
            isLocationPermissionDenied = true
            onError()
            break
        
        case .notDetermined:        // Authorization not determined yet.
            if bluetoothModel.isSetupComplete {
                isLocationPermissionDenied = true
                onError()
            } else {
                locationManager.requestWhenInUseAuthorization()
            }
            break
        
        default:
            break
        }
    }
}
