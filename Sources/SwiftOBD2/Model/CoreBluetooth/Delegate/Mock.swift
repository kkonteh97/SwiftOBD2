//
//  Mock.swift
//  factory-tourguide-iOS
//
//  Created by kazuya ito on 2020/10/28.
//

import Foundation

protocol Mock {}

extension Mock {
    var className: String {
        return String(describing: type(of: self))
    }
    
    func log(_ message: String? = nil) {
        print("Mocked -", className, message ?? "")
    }
}
