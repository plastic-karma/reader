//
//  Item.swift
//  reader
//
//  Created by Benni Rogge on 7/5/26.
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
