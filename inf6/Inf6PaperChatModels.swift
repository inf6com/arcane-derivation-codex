//
//  Inf6PaperChatModels.swift
//  inf6
//
//  Models for PaperChat
//

import Foundation

enum Inf6PaperChatRole: String, Codable {
    case user
    case assistant
    case system
}

struct Inf6PaperChatMessage: Identifiable, Hashable, Codable {
    let id: String
    let role: Inf6PaperChatRole
    let text: String
    let createdAt: Date

    init(role: Inf6PaperChatRole, text: String) {
        self.id = UUID().uuidString
        self.role = role
        self.text = text
        self.createdAt = Date()
    }
}

/// Quick reply shown as a chip (tap button).
struct Inf6PaperChatQuickReply: Identifiable, Hashable, Codable {
    let id: String
    let label: String

    init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}
