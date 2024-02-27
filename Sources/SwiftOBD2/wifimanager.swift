//
//  File.swift
//  
//
//  Created by kemo konteh on 2/26/24.
//

import Foundation
import SystemConfiguration.CaptiveNetwork
import NetworkExtension

class WifiManager {
    static func getSSID() -> String {
        var ssid = ""
        if let interfaces = CNCopySupportedInterfaces() as NSArray? {
            for interface in interfaces {
                if let interfaceInfo = CNCopyCurrentNetworkInfo(interface as! CFString) as NSDictionary? {
                    ssid = interfaceInfo[kCNNetworkInfoKeySSID as String] as! String
                }
            }
        }
        return ssid
    }
}

