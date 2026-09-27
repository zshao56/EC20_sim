import Foundation
import SQLite3

/// SQLite must copy the bound string; passing nil would keep a dangling pointer to a
/// temporary NSString buffer after the statement finishes.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class EC20Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.quectel.ec20companion.database", qos: .userInitiated)

    public static let defaultDatabaseURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.quectel.ec20companion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ec20companion_v2.sqlite3")
    }()

    public init(url: URL? = nil) {
        let targetURL = url ?? Self.defaultDatabaseURL
        let path = targetURL.path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            print("[Database] Failed to open SQLite database at \(path): \(errmsg)")
        } else {
            createTables()
        }
    }

    public init(inMemory: Bool) {
        if inMemory {
            if sqlite3_open(":memory:", &db) != SQLITE_OK {
                print("[Database] Failed to open in-memory database")
            } else {
                createTables()
            }
        } else {
            let targetURL = Self.defaultDatabaseURL
            _ = sqlite3_open(targetURL.path, &db)
            createTables()
        }
    }

    deinit {
        queue.sync {
            if let db = db {
                sqlite3_close(db)
            }
        }
    }

    private func createTables() {
        queue.sync {
            guard let db = db else { return }

            let sql = """
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL,
                storage_index INTEGER,
                storage_area TEXT,
                sender_or_recipient TEXT NOT NULL,
                text TEXT NOT NULL,
                timestamp REAL NOT NULL,
                is_incoming INTEGER NOT NULL,
                is_read INTEGER NOT NULL,
                send_status TEXT NOT NULL,
                send_error TEXT,
                raw_pdu TEXT,
                dedup_key TEXT UNIQUE
            );
            CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id, timestamp);
            CREATE INDEX IF NOT EXISTS idx_messages_dedup ON messages(dedup_key);
            CREATE INDEX IF NOT EXISTS idx_messages_unread ON messages(is_read);

            CREATE TABLE IF NOT EXISTS contacts (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                phone_number TEXT NOT NULL,
                normalized_phone TEXT NOT NULL UNIQUE,
                notes TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_contacts_phone ON contacts(normalized_phone);

            CREATE TABLE IF NOT EXISTS call_records (
                id TEXT PRIMARY KEY,
                phone_number TEXT NOT NULL,
                normalized_phone TEXT NOT NULL,
                contact_name TEXT,
                type TEXT NOT NULL,
                timestamp REAL,
                duration_seconds INTEGER,
                source TEXT NOT NULL,
                has_exact_timestamp INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_calls_time ON call_records(timestamp);

            CREATE TABLE IF NOT EXISTS storage_capacity (
                area TEXT PRIMARY KEY,
                used INTEGER NOT NULL,
                total INTEGER NOT NULL,
                updated_at REAL NOT NULL
            );
            """
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                if let err = err {
                    print("[Database] Init error: \(String(cString: err))")
                    sqlite3_free(err)
                }
            }
        }
    }

    // MARK: - Messages & Threads

    /// Saves a single message. Returns true if inserted as new, false if deduplicated.
    @discardableResult
    public func saveMessage(_ msg: SMSMessage) -> Bool {
        return queue.sync {
            guard let db = db else { return false }
            let sql = """
            INSERT OR IGNORE INTO messages (
                id, thread_id, storage_index, storage_area, sender_or_recipient,
                text, timestamp, is_incoming, is_read, send_status, send_error, raw_pdu, dedup_key
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (msg.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (msg.threadId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if let idx = msg.storageIndex {
                sqlite3_bind_int(stmt, 3, Int32(idx))
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            if let area = msg.storageArea {
                sqlite3_bind_text(stmt, 4, (area as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_text(stmt, 5, (msg.senderOrRecipient as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, (msg.text as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 7, msg.timestamp.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 8, msg.isIncoming ? 1 : 0)
            sqlite3_bind_int(stmt, 9, msg.isRead ? 1 : 0)
            sqlite3_bind_text(stmt, 10, (msg.sendStatus.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if let err = msg.sendError {
                sqlite3_bind_text(stmt, 11, (err as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            if let pdu = msg.rawPDU {
                sqlite3_bind_text(stmt, 12, (pdu as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 12)
            }
            sqlite3_bind_text(stmt, 13, (msg.dedupKey as NSString).utf8String, -1, SQLITE_TRANSIENT)

            let res = sqlite3_step(stmt)
            let changes = sqlite3_changes(db)
            let inserted = res == SQLITE_DONE && changes > 0
            if !inserted && msg.isRead {
                // The module message already exists locally but is now flagged read
                // (e.g. read on the phone); propagate that state into SQLite.
                self.applyReadState(db: db, dedupKey: msg.dedupKey)
            }
            return inserted
        }
    }

    /// Marks an existing row as read when the module reports the message as read.
    private func applyReadState(db: OpaquePointer, dedupKey: String) {
        let sql = "UPDATE messages SET is_read = 1 WHERE dedup_key = ? AND is_read = 0 AND is_incoming = 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (dedupKey as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// Looks up a single message by its local UUID (used for outbox retry).
    public func fetchMessage(id: UUID) -> SMSMessage? {
        return queue.sync {
            guard let db = db else { return nil }
            let sql = """
            SELECT id, thread_id, storage_index, storage_area, sender_or_recipient,
                   text, timestamp, is_incoming, is_read, send_status, send_error, raw_pdu
            FROM messages
            WHERE id = ?
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return self.decodeMessageRow(stmt)
        }
    }

    private func decodeMessageRow(_ stmt: OpaquePointer?) -> SMSMessage? {
        guard let idStr = sqlite3_column_text(stmt, 0) else { return nil }
        let id = UUID(uuidString: String(cString: idStr)) ?? UUID()
        let tId = String(cString: sqlite3_column_text(stmt, 1))
        let storageIdx = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 2))
        let storageArea = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 3))
        let rawNumber = String(cString: sqlite3_column_text(stmt, 4))
        let text = String(cString: sqlite3_column_text(stmt, 5))
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let isIncoming = sqlite3_column_int(stmt, 7) == 1
        let isRead = sqlite3_column_int(stmt, 8) == 1
        let sendStatusRaw = String(cString: sqlite3_column_text(stmt, 9))
        let sendStatus = MessageSendStatus(rawValue: sendStatusRaw) ?? .sent
        let sendError = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 10))
        let rawPdu = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 11))

        return SMSMessage(
            id: id,
            threadId: tId,
            storageIndex: storageIdx,
            storageArea: storageArea,
            senderOrRecipient: rawNumber,
            text: text,
            timestamp: timestamp,
            isIncoming: isIncoming,
            isRead: isRead,
            sendStatus: sendStatus,
            sendError: sendError,
            rawPDU: rawPdu
        )
    }

    /// Batch saves messages (e.g. startup catch-up sync). Returns number of newly inserted messages.
    @discardableResult
    public func saveMessages(_ messages: [SMSMessage]) -> Int {
        var count = 0
        for m in messages {
            if saveMessage(m) {
                count += 1
            }
        }
        return count
    }

    public func fetchConversations() -> [SMSConversation] {
        return queue.sync {
            guard let db = db else { return [] }
            // Fetch distinct threads with latest message timestamp
            let sql = """
            SELECT m.thread_id, m.sender_or_recipient, m.id, m.storage_index, m.storage_area,
                   m.text, m.timestamp, m.is_incoming, m.is_read, m.send_status, m.send_error,
                   (SELECT COUNT(*) FROM messages u WHERE u.thread_id = m.thread_id AND u.is_read = 0 AND u.is_incoming = 1) as unread_count,
                   (SELECT COUNT(*) FROM messages t WHERE t.thread_id = m.thread_id) as total_count,
                   c.name as contact_name
            FROM messages m
            LEFT JOIN contacts c ON c.normalized_phone = m.thread_id
            WHERE m.rowid = (
                SELECT m2.rowid FROM messages m2
                WHERE m2.thread_id = m.thread_id
                ORDER BY m2.timestamp DESC, m2.rowid DESC
                LIMIT 1
            )
            ORDER BY m.timestamp DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var conversations: [SMSConversation] = []
            var seenThreads = Set<String>()

            while sqlite3_step(stmt) == SQLITE_ROW {
                let threadId = String(cString: sqlite3_column_text(stmt, 0))
                if seenThreads.contains(threadId) { continue }
                seenThreads.insert(threadId)

                let rawNumber = String(cString: sqlite3_column_text(stmt, 1))
                let idStr = String(cString: sqlite3_column_text(stmt, 2))
                let id = UUID(uuidString: idStr) ?? UUID()

                let storageIdx = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 3))
                let storageArea = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
                let text = String(cString: sqlite3_column_text(stmt, 5))
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                let isIncoming = sqlite3_column_int(stmt, 7) == 1
                let isRead = sqlite3_column_int(stmt, 8) == 1
                let sendStatusRaw = String(cString: sqlite3_column_text(stmt, 9))
                let sendStatus = MessageSendStatus(rawValue: sendStatusRaw) ?? .sent
                let sendError = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 10))

                let unreadCount = Int(sqlite3_column_int(stmt, 11))
                let totalCount = Int(sqlite3_column_int(stmt, 12))
                let contactName = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 13))

                let latestMsg = SMSMessage(
                    id: id,
                    threadId: threadId,
                    storageIndex: storageIdx,
                    storageArea: storageArea,
                    senderOrRecipient: rawNumber,
                    text: text,
                    timestamp: timestamp,
                    isIncoming: isIncoming,
                    isRead: isRead,
                    sendStatus: sendStatus,
                    sendError: sendError
                )

                conversations.append(SMSConversation(
                    threadId: threadId,
                    displayRecipient: rawNumber,
                    contactName: contactName,
                    latestMessage: latestMsg,
                    unreadCount: unreadCount,
                    totalCount: totalCount
                ))
            }
            return conversations
        }
    }

    public func fetchMessages(threadId: String) -> [SMSMessage] {
        return queue.sync {
            guard let db = db else { return [] }
            let sql = """
            SELECT id, thread_id, storage_index, storage_area, sender_or_recipient,
                   text, timestamp, is_incoming, is_read, send_status, send_error, raw_pdu
            FROM messages
            WHERE thread_id = ?
            ORDER BY timestamp ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (threadId as NSString).utf8String, -1, SQLITE_TRANSIENT)

            var list: [SMSMessage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let msg = self.decodeMessageRow(stmt) {
                    list.append(msg)
                }
            }
            return list
        }
    }

    public func fetchAllMessages() -> [SMSMessage] {
        return queue.sync {
            guard let db = db else { return [] }
            let sql = """
            SELECT id, thread_id, storage_index, storage_area, sender_or_recipient,
                   text, timestamp, is_incoming, is_read, send_status, send_error, raw_pdu
            FROM messages
            ORDER BY timestamp DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var list: [SMSMessage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let msg = self.decodeMessageRow(stmt) {
                    list.append(msg)
                }
            }
            return list
        }
    }

    public func markThreadRead(threadId: String) {
        queue.sync {
            guard let db = db else { return }
            let sql = "UPDATE messages SET is_read = 1 WHERE thread_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (threadId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    public func markMessageRead(id: UUID) {
        queue.sync {
            guard let db = db else { return }
            let sql = "UPDATE messages SET is_read = 1 WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    public func updateMessageStatus(id: UUID, status: MessageSendStatus, error: String? = nil) {
        queue.sync {
            guard let db = db else { return }
            let sql = "UPDATE messages SET send_status = ?, send_error = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (status.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if let error = error {
                sqlite3_bind_text(stmt, 2, (error as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    public func totalUnreadCount() -> Int {
        return queue.sync {
            guard let db = db else { return 0 }
            let sql = "SELECT COUNT(*) FROM messages WHERE is_read = 0 AND is_incoming = 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
            return 0
        }
    }

    public func deleteMessage(id: UUID) {
        queue.sync {
            guard let db = db else { return }
            let sql = "DELETE FROM messages WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    public func deleteThread(threadId: String) {
        queue.sync {
            guard let db = db else { return }
            let sql = "DELETE FROM messages WHERE thread_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (threadId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    public func runInTransaction<T>(_ block: () throws -> T) throws -> T {
        return try queue.sync {
            guard let db = db else {
                throw NSError(domain: "EC20Database", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
            }
            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            do {
                let result = try block()
                sqlite3_exec(db, "COMMIT;", nil, nil, nil)
                return result
            } catch {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    public func deleteMessagesBatch(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            guard let db = db else { return }
            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            let sql = "DELETE FROM messages WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for id in ids {
                    sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_step(stmt)
                    sqlite3_reset(stmt)
                }
                sqlite3_finalize(stmt)
                sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            } else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }
    }

    public func deleteThreadsBatch(threadIds: [String]) {
        guard !threadIds.isEmpty else { return }
        queue.sync {
            guard let db = db else { return }
            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            let sql = "DELETE FROM messages WHERE thread_id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for tId in threadIds {
                    sqlite3_bind_text(stmt, 1, (tId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_step(stmt)
                    sqlite3_reset(stmt)
                }
                sqlite3_finalize(stmt)
                sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            } else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }
    }

    // MARK: - Contacts

    public func saveContact(_ contact: Contact) {
        queue.sync {
            guard let db = db else { return }
            let sql = """
            INSERT OR REPLACE INTO contacts (
                id, name, phone_number, normalized_phone, notes, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (contact.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (contact.name as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (contact.phoneNumber as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, (contact.normalizedPhone as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, (contact.notes as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 6, contact.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 7, contact.updatedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    public func deleteContact(id: UUID) {
        queue.sync {
            guard let db = db else { return }
            let sql = "DELETE FROM contacts WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    public func fetchContacts() -> [Contact] {
        return queue.sync {
            guard let db = db else { return [] }
            let sql = "SELECT id, name, phone_number, normalized_phone, notes, created_at, updated_at FROM contacts ORDER BY name ASC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var list: [Contact] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let phone = String(cString: sqlite3_column_text(stmt, 2))
                let notes = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? "" : String(cString: sqlite3_column_text(stmt, 4))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))

                list.append(Contact(
                    id: id,
                    name: name,
                    phoneNumber: phone,
                    notes: notes,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                ))
            }
            return list
        }
    }

    public func findContact(forPhone phone: String) -> Contact? {
        let norm = PhoneNumberNormalizer.normalize(phone)
        return queue.sync {
            guard let db = db else { return nil }
            let sql = "SELECT id, name, phone_number, normalized_phone, notes, created_at, updated_at FROM contacts WHERE normalized_phone = ? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (norm as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let phoneNum = String(cString: sqlite3_column_text(stmt, 2))
                let notes = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? "" : String(cString: sqlite3_column_text(stmt, 4))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                return Contact(id: id, name: name, phoneNumber: phoneNum, notes: notes, createdAt: createdAt, updatedAt: updatedAt)
            }
            return nil
        }
    }

    // MARK: - Call Records

    public func saveCallRecord(_ record: CallHistoryItem) {
        queue.sync {
            guard let db = db else { return }
            var cleanPhone = record.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanPhone.isEmpty {
                cleanPhone = "未知号码"
            }
            var cleanNorm = record.normalizedPhone.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanNorm.isEmpty {
                cleanNorm = PhoneNumberNormalizer.normalize(cleanPhone)
                if cleanNorm.isEmpty { cleanNorm = "未知号码" }
            }

            let sql = """
            INSERT INTO call_records (
                id, phone_number, normalized_phone, contact_name, type,
                timestamp, duration_seconds, source, has_exact_timestamp
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (record.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (cleanPhone as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (cleanNorm as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if let cName = record.contactName {
                sqlite3_bind_text(stmt, 4, (cName as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_text(stmt, 5, (record.type.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if let time = record.timestamp {
                sqlite3_bind_double(stmt, 6, time.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            if let dur = record.durationSeconds {
                sqlite3_bind_int(stmt, 7, Int32(dur))
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            sqlite3_bind_text(stmt, 8, (record.source.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 9, record.hasExactTimestamp ? 1 : 0)
            sqlite3_step(stmt)
        }
    }

    public func fetchCallHistory(limit: Int = 100) -> [CallHistoryItem] {
        return queue.sync {
            guard let db = db else { return [] }
            let sql = """
            SELECT r.id, r.phone_number, r.normalized_phone, r.contact_name, r.type,
                   r.timestamp, r.duration_seconds, r.source, r.has_exact_timestamp, c.name
            FROM call_records r
            LEFT JOIN contacts c ON c.normalized_phone = r.normalized_phone
            ORDER BY COALESCE(r.timestamp, 0) DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(limit))

            var list: [CallHistoryItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
                var phone = String(cString: sqlite3_column_text(stmt, 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if phone.isEmpty {
                    phone = "未知号码"
                }
                let contactName = sqlite3_column_type(stmt, 9) != SQLITE_NULL
                    ? String(cString: sqlite3_column_text(stmt, 9))
                    : (sqlite3_column_type(stmt, 3) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 3)) : nil)
                let typeRaw = String(cString: sqlite3_column_text(stmt, 4))
                let type = CallHistoryType(rawValue: typeRaw) ?? .outgoing
                let timestamp = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                let duration = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))
                let sourceRaw = String(cString: sqlite3_column_text(stmt, 7))
                let source = CallRecordSource(rawValue: sourceRaw) ?? .local
                let hasExact = sqlite3_column_int(stmt, 8) == 1

                list.append(CallHistoryItem(
                    id: id,
                    phoneNumber: phone,
                    contactName: contactName,
                    type: type,
                    timestamp: timestamp,
                    durationSeconds: duration,
                    source: source,
                    hasExactTimestamp: hasExact
                ))
            }
            return list
        }
    }

    public func clearCallHistory() {
        queue.sync {
            guard let db = db else { return }
            sqlite3_exec(db, "DELETE FROM call_records;", nil, nil, nil)
        }
    }

    public func deleteCallRecord(id: UUID) {
        queue.sync {
            guard let db = db else { return }
            let sql = "DELETE FROM call_records WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    public func deleteCallHistoryBatch(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            guard let db = db else { return }
            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            let sql = "DELETE FROM call_records WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for id in ids {
                    sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_step(stmt)
                    sqlite3_reset(stmt)
                }
                sqlite3_finalize(stmt)
                sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            } else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }
    }

    // MARK: - Storage Capacity Monitoring

    public func updateStorageCapacity(area: String, used: Int, total: Int) {
        queue.sync {
            guard let db = db else { return }
            let sql = """
            INSERT OR REPLACE INTO storage_capacity (area, used, total, updated_at)
            VALUES (?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (area as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(used))
            sqlite3_bind_int(stmt, 3, Int32(total))
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    public func fetchStorageCapacity() -> [StorageCapacity] {
        return queue.sync {
            guard let db = db else { return [] }
            let sql = "SELECT area, used, total, updated_at FROM storage_capacity ORDER BY area ASC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var list: [StorageCapacity] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let area = String(cString: sqlite3_column_text(stmt, 0))
                let used = Int(sqlite3_column_int(stmt, 1))
                let total = Int(sqlite3_column_int(stmt, 2))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                list.append(StorageCapacity(area: area, used: used, total: total, updatedAt: updatedAt))
            }
            return list
        }
    }
}
