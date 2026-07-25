import Foundation
import SQLite3

/// Thin wrapper over the SQLite C API. Not thread-safe on its own —
/// always confined inside the `Store` actor.
final class Database {
	private(set) var handle: OpaquePointer?
	let path: String

	init(path: String, readOnly: Bool) throws {
		self.path = path
		if readOnly {
			guard FileManager.default.fileExists(atPath: path) else {
				throw OverflightError.notFound("database not found at \(path) — has the collector run yet?")
			}
		} else {
			let dir = (path as NSString).deletingLastPathComponent
			try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		}
		let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
		var db: OpaquePointer?
		guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
			let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
			sqlite3_close_v2(db)
			throw OverflightError.sqlite(msg)
		}
		handle = db
	}

	deinit { close() }

	func close() {
		if let h = handle {
			sqlite3_close_v2(h)
			handle = nil
		}
	}

	var errorMessage: String {
		handle.map { String(cString: sqlite3_errmsg($0)) } ?? "connection closed"
	}

	func exec(_ sql: String) throws {
		guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
			throw OverflightError.sqlite("\(errorMessage) — in: \(sql.prefix(120))")
		}
	}

	func prepare(_ sql: String) throws -> Statement {
		var stmt: OpaquePointer?
		guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
			throw OverflightError.sqlite("\(errorMessage) — preparing: \(sql.prefix(120))")
		}
		return Statement(s)
	}

	var lastInsertRowID: Int64 {
		sqlite3_last_insert_rowid(handle)
	}

	/// Rows affected by the most recent INSERT/UPDATE/DELETE.
	var changes: Int {
		Int(sqlite3_changes64(handle))
	}
}

final class Statement {
	private let stmt: OpaquePointer

	init(_ stmt: OpaquePointer) {
		self.stmt = stmt
	}

	deinit { sqlite3_finalize(stmt) }

	func reset() {
		sqlite3_reset(stmt)
		sqlite3_clear_bindings(stmt)
	}

	func bind(_ index: Int32, _ value: Int64?) {
		if let value { sqlite3_bind_int64(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
	}

	func bind(_ index: Int32, _ value: Int?) {
		bind(index, value.map(Int64.init))
	}

	func bind(_ index: Int32, _ value: Double?) {
		if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
	}

	func bind(_ index: Int32, _ value: String?) {
		if let value {
			// SQLITE_TRANSIENT: have SQLite copy the buffer before the Swift string goes away
			sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
		} else {
			sqlite3_bind_null(stmt, index)
		}
	}

	/// Returns true while rows remain.
	@discardableResult
	func step() throws -> Bool {
		switch sqlite3_step(stmt) {
		case SQLITE_ROW: return true
		case SQLITE_DONE: return false
		default:
			throw OverflightError.sqlite(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
		}
	}

	func isNull(_ col: Int32) -> Bool {
		sqlite3_column_type(stmt, col) == SQLITE_NULL
	}

	func int64(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
	func int64OrNil(_ col: Int32) -> Int64? { isNull(col) ? nil : int64(col) }
	func intOrNil(_ col: Int32) -> Int? { int64OrNil(col).map(Int.init) }
	func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }
	func doubleOrNil(_ col: Int32) -> Double? { isNull(col) ? nil : double(col) }

	func text(_ col: Int32) -> String? {
		sqlite3_column_text(stmt, col).map { String(cString: $0) }
	}
}
