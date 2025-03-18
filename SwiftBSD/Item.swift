//
//  Item.swift
//  SwiftBSD
//
//  Created by Joseph Maloney on 3/17/25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
