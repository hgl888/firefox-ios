/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage
import XCGLogger

private let log = Logger.syncLogger

/**
 * Hierarchy:
 * - BookmarkBasePayload
 *   \_ FolderPayload
 *      \_ LivemarkPayload
 *   \_ SeparatorPayload
 *   \_ BookmarkPayload
 *      \_ BookmarkQueryPayload
 */

public enum BookmarkType: String {
    case livemark
    case separator
    case folder
    case bookmark
    case query
    case microsummary     // Dead: now a bookmark.

    // The result might be invalid, but it won't be nil.
    public static func somePayloadFromJSON(json: JSON) -> BookmarkBasePayload {
        return payloadFromJSON(json) ?? BookmarkBasePayload(json)
    }

    public static func payloadFromJSON(json: JSON) -> BookmarkBasePayload? {
        guard let typeString = json["type"].asString else {
            return nil
        }
        guard let type = BookmarkType.init(rawValue: typeString) else {
            return nil
        }

        let result: BookmarkBasePayload
        switch type {
        case microsummary:
            fallthrough
        case bookmark:
            result = BookmarkPayload(json)
        case folder:
            result = FolderPayload(json)
        case livemark:
            result = LivemarkPayload(json)
        case separator:
            result = SeparatorPayload(json)
        case query:
            result = BookmarkQueryPayload(json)
        }

        if result.isValid() {
            return result
        }
        let id = json["id"].asString ?? "<unknown>"
        log.warning("Record \(id) of type \(type) was invalid.")
        return nil
    }
}

public class LivemarkPayload: BookmarkBasePayload {
    public var feedURI: String? {
        return self["feedUri"].asString
    }

    public var siteURI: String? {
        return self["siteUri"].asString
    }

    override public func isValid() -> Bool {
        if !super.isValid() {
            return false
        }
        return self.hasRequiredStringFields(["feedUri", "siteUri"])
    }

    override public func equalPayloads(obj: CleartextPayloadJSON) -> Bool {
        guard let p = obj as? LivemarkPayload else {
            return false
        }

        if !super.equalPayloads(p) {
            return false
        }

        if self.deleted {
            return true
        }

        if self.feedURI != p.feedURI {
            return false
        }

        if self.siteURI != p.siteURI {
            return false
        }

        return true
    }
}

public class SeparatorPayload: BookmarkBasePayload {
    override public func isValid() -> Bool {
        if !super.isValid() {
            return false
        }
        if !self["pos"].isInt {
            log.warning("Separator \(self.id) missing pos.")
            return false
        }
        return true
    }

    override public func equalPayloads(obj: CleartextPayloadJSON) -> Bool {
        guard let p = obj as? SeparatorPayload else {
            return false
        }

        if !super.equalPayloads(p) {
            return false
        }

        if self.deleted {
            return true
        }

        if self["pos"].asInt != p["pos"].asInt {
            return false
        }

        return true
    }
}

public class FolderPayload: BookmarkBasePayload {
    private var childrenAreValid: Bool {
        return self.hasStringArrayField("children")
    }

    override public func isValid() -> Bool {
        if !super.isValid() {
            return false
        }

        if !self.hasRequiredStringFields(["title"]) {
            log.warning("Folder \(self.id) missing title.")
            return false
        }

        if !self.hasOptionalStringFields(["description"]) {
            log.warning("Folder \(self.id) missing string description.")
            return false

        }
        if !self.childrenAreValid {
            log.warning("Folder \(self.id) has invalid children.")
            return false
        }

        return true
    }

    public var children: [String] {
        return self["children"].asArray!.map { $0.asString! }
    }

    override public func equalPayloads(obj: CleartextPayloadJSON) -> Bool {
        guard let p = obj as? FolderPayload else {
            return false
        }

        if !super.equalPayloads(p) {
            return false
        }

        if self.deleted {
            return true
        }

        if self["title"].asString != p["title"].asString {
            return false
        }

        if self["description"].asString != p["description"].asString {
            return false
        }

        if self.children != p.children {
            return false
        }

        return true
    }
}

public class BookmarkPayload: BookmarkBasePayload {
    private static let requiredBookmarkStringFields = ["bmkUri"]

    // Title *should* be required, but can be missing for queries. Great.
    private static let optionalBookmarkStringFields = ["title", "keyword", "description"]
    private static let optionalBookmarkBooleanFields = ["loadInSidebar"]

    override public func isValid() -> Bool {
        if !super.isValid() {
            return false
        }

        if !self.hasRequiredStringFields(BookmarkPayload.requiredBookmarkStringFields) {
            log.warning("Bookmark \(self.id) missing required string field.")
            return false
        }

        if !self.hasStringArrayField("tags") {
            log.warning("Bookmark \(self.id) missing tags array.")
            return false
        }

        if !self.hasOptionalStringFields(BookmarkPayload.optionalBookmarkStringFields) {
            return false
        }

        return self.hasOptionalBooleanFields(BookmarkPayload.optionalBookmarkBooleanFields)
    }

    override public func equalPayloads(obj: CleartextPayloadJSON) -> Bool {
        guard let p = obj as? BookmarkPayload else {
            return false
        }

        if !super.equalPayloads(p) {
            return false
        }

        if self.deleted {
            return true
        }

        if !BookmarkPayload.requiredBookmarkStringFields.every({ p[$0].asString! == self[$0].asString! }) {
            return false
        }

        // TODO: compare optional fields.

        if Set(self.tags) != Set(p.tags) {
            return false
        }

        if self["loadInSidebar"].asBool != p["loadInSidebar"].asBool {
            return false
        }

        return true
    }

    lazy var tags: [String] = {
        return self["tags"].asArray?.flatMap { $0.asString } ?? []
    }()

    // This goes here because extensions cannot override methods yet.
    // The rest are in extension blocks at the end of this file.
    public func toMirrorItem(modified: Timestamp) -> BookmarkMirrorItem {
        if self.deleted {
            return BookmarkMirrorItem.deleted(.Bookmark, guid: self.id, modified: modified)
        }

        return BookmarkMirrorItem.bookmark(
            self.id,
            modified: modified,
            hasDupe: self.hasDupe,
            // TODO: these might need to be weakened if real-world data is dirty.
            parentID: self["parentid"].asString!,
            parentName: self["parentName"].asString!,
            title: self["title"].asString ?? "",
            description: self["description"].asString,
            URI: self["bmkUri"].asString!,
            tags: self["tags"].toString(),           // Stringify it so we can put the array in the DB.
            keyword: self["keyword"].asString
        )
    }
}

public class BookmarkQueryPayload: BookmarkPayload {
    override public func isValid() -> Bool {
        if !super.isValid() {
            return false
        }

        if !self.hasOptionalStringFields(["queryId", "folderName"]) {
            log.warning("Query \(self.id) missing queryId or folderName.")
            return false
        }

        return true
    }

    override public func equalPayloads(obj: CleartextPayloadJSON) -> Bool {
        guard let p = obj as? BookmarkQueryPayload else {
            return false
        }

        if !super.equalPayloads(p) {
            return false
        }

        if self.deleted {
            return true
        }

        if self["folderName"].asString != p["folderName"].asString {
            return false
        }

        if self["queryId"].asString != p["queryId"].asString {
            return false
        }

        return true
    }

    override public func toMirrorItem(modified: Timestamp) -> BookmarkMirrorItem {
        if self.deleted {
            return BookmarkMirrorItem.deleted(.Query, guid: self.id, modified: modified)
        }

        return BookmarkMirrorItem.query(
            self.id,
            modified: modified,
            hasDupe: self.hasDupe,
            parentID: self["parentid"].asString!,
            parentName: self["parentName"].asString!,
            title: self["title"].asString ?? "",
            description: self["description"].asString,
            URI: self["bmkUri"].asString!,
            tags: self["tags"].toString(),           // Stringify it so we can put the array in the DB.
            keyword: self["keyword"].asString,
            folderName: self["folderName"].asString,
            queryID: self["queryID"].asString
        )
    }
}

public class BookmarkBasePayload: CleartextPayloadJSON {
    private static let requiredStringFields: [String] = ["parentid", "type"]
    private static let optionalBooleanFields: [String] = ["hasDupe"]

    func hasStringArrayField(name: String) -> Bool {
        guard let arr = self[name].asArray else {
            return false
        }
        return arr.every { $0.isString }
    }

    func hasRequiredStringFields(fields: [String]) -> Bool {
        return fields.every { self[$0].isString }
    }

    func hasOptionalStringFields(fields: [String]) -> Bool {
        return fields.every { field in
            let val = self[field]
            // Yup, 404 is not found, so this means "string or nothing".
            let valid = val.isString || val.isNull || val.asError?.code == 404
            if !valid {
                log.debug("Field \(field) is invalid: \(val).")
            }
            return valid
        }
    }

    func hasOptionalBooleanFields(fields: [String]) -> Bool {
        return fields.every { field in
            let val = self[field]
            // Yup, 404 is not found, so this means "boolean or nothing".
            let valid = val.isBool || val.isNull || val.asError?.code == 404
            if !valid {
                log.debug("Field \(field) is invalid: \(val).")
            }
            return valid
        }
    }

    override public func isValid() -> Bool {
        if !super.isValid() {
            return false
        }

        if self["deleted"].asBool ?? false {
            return true
        }

        if !(self["parentName"].isString || self.id == "places") {
            log.warning("Not the places root and missing parent name.")
            return false
        }

        if !self.hasRequiredStringFields(BookmarkBasePayload.requiredStringFields) {
            log.warning("Item missing required string field.")
            return false
        }

        return self.hasOptionalBooleanFields(BookmarkBasePayload.optionalBooleanFields)
    }

    public var hasDupe: Bool {
        return self["hasDupe"].asBool ?? false
    }

    /**
     * This only makes sense for valid payloads.
     */
    override public func equalPayloads(obj: CleartextPayloadJSON) -> Bool {
        guard let p = obj as? BookmarkBasePayload else {
            return false
        }

        if !super.equalPayloads(p) {
            return false;
        }

        if self.deleted {
            return true
        }

        if p.deleted {
            return self.deleted == p.deleted
        }

        // If either record is deleted, these other fields might be missing.
        // But we just checked, so we're good to roll on.

        let same: String -> Bool = { field in
            let left = self[field].asString
            let right = p[field].asString
            return left == right
        }

        if !BookmarkBasePayload.requiredStringFields.every(same) {
            return false
        }

        if p["parentName"].asString != self["parentName"].asString {
            return false
        }

        return self.hasDupe == p.hasDupe
    }
}

public protocol MirrorItemable {
    func toMirrorItem(modified: Timestamp) -> BookmarkMirrorItem
}

extension BookmarkPayload: MirrorItemable {
    // In the main class definition due to Swift compiler limitations.
}

extension FolderPayload: MirrorItemable {
    public func toMirrorItem(modified: Timestamp) -> BookmarkMirrorItem {
        if self.deleted {
            return BookmarkMirrorItem.deleted(.Folder, guid: self.id, modified: modified)
        }

        return BookmarkMirrorItem.folder(
            self.id,
            modified: modified,
            hasDupe: self.hasDupe,
            // TODO: these might need to be weakened if real-world data is dirty.
            parentID: self["parentid"].asString!,
            parentName: self["parentName"].asString,
            title: self["title"].asString!,
            description: self["description"].asString,
            children: self.children
        )
    }
}

extension LivemarkPayload: MirrorItemable {
    public func toMirrorItem(modified: Timestamp) -> BookmarkMirrorItem {
        if self.deleted {
            return BookmarkMirrorItem.deleted(.Livemark, guid: self.id, modified: modified)
        }

        return BookmarkMirrorItem.livemark(
            self.id,
            modified: modified,
            hasDupe: self.hasDupe,
            // TODO: these might need to be weakened if real-world data is dirty.
            parentID: self["parentid"].asString!,
            parentName: self["parentName"].asString!,
            title: self["title"].asString!,
            description: self["description"].asString,
            feedURI: self.feedURI!,
            siteURI: self.siteURI!
        )
    }
}

extension SeparatorPayload: MirrorItemable {
    public func toMirrorItem(modified: Timestamp) -> BookmarkMirrorItem {
        if self.deleted {
            return BookmarkMirrorItem.deleted(.Separator, guid: self.id, modified: modified)
        }

        return BookmarkMirrorItem.separator(
            self.id,
            modified: modified,
            hasDupe: self.hasDupe,
            // TODO: these might need to be weakened if real-world data is dirty.
            parentID: self["parentid"].asString!,
            parentName: self["parentName"].asString!,
            pos: self["pos"].asInt!
        )
    }
}
