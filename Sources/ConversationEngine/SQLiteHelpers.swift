// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import SQLite

// MARK: - Swift 6 Disambiguation Helpers for SQLite.swift
//
// These helpers work around Expression initializer ambiguity in Swift 6.
// When String (which conforms to Value) is used as the generic parameter,
// Swift 6 cannot disambiguate between:
//   - init(_ identifier: String) - column reference
//   - init(value: UnderlyingType) where UnderlyingType == String - literal binding
//
// Solution: Use explicit column() helpers that internally use quoted literals.

/// Creates a column reference expression for a String column
func column<T>(_ name: String) -> SQLite.Expression<T> {
    SQLite.Expression<T>(literal: "\"\(name)\"")
}

/// Creates a column reference expression for an optional type column
func columnOptional<T>(_ name: String) -> SQLite.Expression<T?> {
    SQLite.Expression<T?>(literal: "\"\(name)\"")
}
