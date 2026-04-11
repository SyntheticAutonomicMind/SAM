// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Contacts
import Logging

/// MCP Tool for Contacts via the Contacts framework.
/// Provides access to the user's contacts for searching, reading, and creating.
public class ContactsTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "contacts_operations"

    public let description = """
    Search and manage the user's Contacts using the macOS Contacts framework.

    OPERATIONS:
    • search - Search contacts by name, email, or phone (query)
    • get_contact - Get full details for a contact (contact_id)
    • create_contact - Create a new contact (first_name, optional: last_name, email, phone, organization, job_title, notes)
    • update_contact - Update an existing contact (contact_id, fields to update)
    • list_groups - List contact groups
    • search_group - List contacts in a specific group (group_name)

    Returns contact details including name, emails, phones, addresses, organization, and birthday.
    """

    public var supportedOperations: [String] {
        return ["search", "get_contact", "create_contact", "update_contact", "list_groups", "search_group"]
    }

    public var parameters: [String: MCPToolParameter] {
        return [
            "operation": MCPToolParameter(
                type: .string,
                description: "Contacts operation to perform",
                required: true,
                enumValues: supportedOperations
            ),
            "query": MCPToolParameter(
                type: .string,
                description: "Search query (name, email, or phone number)",
                required: false
            ),
            "contact_id": MCPToolParameter(
                type: .string,
                description: "Contact identifier for get/update operations",
                required: false
            ),
            "first_name": MCPToolParameter(
                type: .string,
                description: "Contact first name",
                required: false
            ),
            "last_name": MCPToolParameter(
                type: .string,
                description: "Contact last name",
                required: false
            ),
            "email": MCPToolParameter(
                type: .string,
                description: "Contact email address",
                required: false
            ),
            "phone": MCPToolParameter(
                type: .string,
                description: "Contact phone number",
                required: false
            ),
            "organization": MCPToolParameter(
                type: .string,
                description: "Contact organization/company",
                required: false
            ),
            "job_title": MCPToolParameter(
                type: .string,
                description: "Contact job title",
                required: false
            ),
            "notes": MCPToolParameter(
                type: .string,
                description: "Contact notes",
                required: false
            ),
            "group_name": MCPToolParameter(
                type: .string,
                description: "Contact group name",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.contacts")
    private let store = CNContactStore()

    @MainActor
    public func initialize() async throws {
        logger.debug("ContactsTool initialized")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard parameters["operation"] is String else {
            throw MCPError.invalidParameters("Missing 'operation' parameter")
        }
        return true
    }

    @MainActor
    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        switch operation {
        case "search":
            return await searchContacts(parameters: parameters)
        case "get_contact":
            return await getContact(parameters: parameters)
        case "create_contact":
            return await createContact(parameters: parameters)
        case "update_contact":
            return await updateContact(parameters: parameters)
        case "list_groups":
            return await listGroups()
        case "search_group":
            return await searchGroup(parameters: parameters)
        default:
            return operationError(operation, message: "Unknown operation")
        }
    }

    // MARK: - Authorization

    private func requestAccess() async -> Bool {
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            logger.error("Contacts access denied: \(error)")
            return false
        }
    }

    // MARK: - Contact Formatting

    private let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactNoteKey as CNKeyDescriptor,
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
    ]

    private func formatContact(_ contact: CNContact, verbose: Bool = false) -> String {
        var output = ""
        let fullName = CNContactFormatter.string(from: contact, style: .fullName) ?? "\(contact.givenName) \(contact.familyName)"
        output += "**\(fullName)**\n"

        if !contact.organizationName.isEmpty {
            output += "  Organization: \(contact.organizationName)\n"
        }
        if !contact.jobTitle.isEmpty {
            output += "  Title: \(contact.jobTitle)\n"
        }

        for email in contact.emailAddresses {
            let label = CNLabeledValue<NSString>.localizedString(forLabel: email.label ?? "")
            output += "  Email (\(label)): \(email.value)\n"
        }

        for phone in contact.phoneNumbers {
            let label = CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: phone.label ?? "")
            output += "  Phone (\(label)): \(phone.value.stringValue)\n"
        }

        if verbose {
            for address in contact.postalAddresses {
                let label = CNLabeledValue<CNPostalAddress>.localizedString(forLabel: address.label ?? "")
                let formatted = CNPostalAddressFormatter.string(from: address.value, style: .mailingAddress)
                output += "  Address (\(label)): \(formatted.replacingOccurrences(of: "\n", with: ", "))\n"
            }

            if let birthday = contact.birthday {
                if let date = Calendar.current.date(from: birthday) {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    output += "  Birthday: \(formatter.string(from: date))\n"
                }
            }

            if !contact.note.isEmpty {
                output += "  Notes: \(contact.note)\n"
            }
        }

        output += "  ID: \(contact.identifier)\n"
        return output
    }

    // MARK: - Operations

    @MainActor
    private func searchContacts(parameters: [String: Any]) async -> MCPToolResult {
        guard await requestAccess() else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Contacts access denied. Please grant permission in System Settings > Privacy & Security > Contacts."))
        }

        guard let query = parameters["query"] as? String, !query.isEmpty else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: query"))
        }

        let predicate = CNContact.predicateForContacts(matchingName: query)
        var contacts: [CNContact] = []

        do {
            contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
        } catch {
            logger.error("Contact search failed: \(error)")
        }

        // Also search by email if no name matches
        if contacts.isEmpty {
            do {
                let emailPredicate = CNContact.predicateForContacts(matchingEmailAddress: query)
                contacts = try store.unifiedContacts(matching: emailPredicate, keysToFetch: keysToFetch)
            } catch {
                // Email search failed, continue
            }
        }

        if contacts.isEmpty {
            return MCPToolResult(success: true, output: MCPOutput(content: "No contacts matching '\(query)'."))
        }

        var output = "Contacts matching '\(query)' (\(contacts.count) found):\n\n"
        for contact in contacts.prefix(20) {
            output += formatContact(contact) + "\n"
        }
        if contacts.count > 20 {
            output += "... and \(contacts.count - 20) more. Narrow your search."
        }

        return MCPToolResult(success: true, output: MCPOutput(content: output))
    }

    @MainActor
    private func getContact(parameters: [String: Any]) async -> MCPToolResult {
        guard await requestAccess() else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Contacts access denied."))
        }

        guard let contactId = parameters["contact_id"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: contact_id"))
        }

        do {
            let predicate = CNContact.predicateForContacts(withIdentifiers: [contactId])
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            guard let contact = contacts.first else {
                return MCPToolResult(success: false, output: MCPOutput(content: "Contact not found with ID: \(contactId)"))
            }
            return MCPToolResult(success: true, output: MCPOutput(content: formatContact(contact, verbose: true)))
        } catch {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to fetch contact: \(error.localizedDescription)"))
        }
    }

    @MainActor
    private func createContact(parameters: [String: Any]) async -> MCPToolResult {
        guard await requestAccess() else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Contacts access denied."))
        }

        guard let firstName = parameters["first_name"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: first_name"))
        }

        let contact = CNMutableContact()
        contact.givenName = firstName
        contact.familyName = parameters["last_name"] as? String ?? ""
        contact.organizationName = parameters["organization"] as? String ?? ""
        contact.jobTitle = parameters["job_title"] as? String ?? ""
        contact.note = parameters["notes"] as? String ?? ""

        if let email = parameters["email"] as? String {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
        }

        if let phone = parameters["phone"] as? String {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone))]
        }

        let saveRequest = CNSaveRequest()
        saveRequest.add(contact, toContainerWithIdentifier: nil)

        do {
            try store.execute(saveRequest)
            let fullName = "\(firstName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            logger.info("Created contact: \(fullName)")
            return MCPToolResult(success: true, output: MCPOutput(content: "Created contact '\(fullName)'. ID: \(contact.identifier)"))
        } catch {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to create contact: \(error.localizedDescription)"))
        }
    }

    @MainActor
    private func updateContact(parameters: [String: Any]) async -> MCPToolResult {
        guard await requestAccess() else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Contacts access denied."))
        }

        guard let contactId = parameters["contact_id"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: contact_id"))
        }

        do {
            let predicate = CNContact.predicateForContacts(withIdentifiers: [contactId])
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            guard let existing = contacts.first else {
                return MCPToolResult(success: false, output: MCPOutput(content: "Contact not found with ID: \(contactId)"))
            }

            let mutable = existing.mutableCopy() as! CNMutableContact

            if let firstName = parameters["first_name"] as? String { mutable.givenName = firstName }
            if let lastName = parameters["last_name"] as? String { mutable.familyName = lastName }
            if let org = parameters["organization"] as? String { mutable.organizationName = org }
            if let title = parameters["job_title"] as? String { mutable.jobTitle = title }
            if let notes = parameters["notes"] as? String { mutable.note = notes }

            if let email = parameters["email"] as? String {
                mutable.emailAddresses.append(CNLabeledValue(label: CNLabelWork, value: email as NSString))
            }
            if let phone = parameters["phone"] as? String {
                mutable.phoneNumbers.append(CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone)))
            }

            let saveRequest = CNSaveRequest()
            saveRequest.update(mutable)
            try store.execute(saveRequest)

            let fullName = CNContactFormatter.string(from: mutable, style: .fullName) ?? mutable.givenName
            logger.info("Updated contact: \(fullName)")
            return MCPToolResult(success: true, output: MCPOutput(content: "Updated contact '\(fullName)'."))
        } catch {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to update contact: \(error.localizedDescription)"))
        }
    }

    @MainActor
    private func listGroups() async -> MCPToolResult {
        guard await requestAccess() else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Contacts access denied."))
        }

        do {
            let groups = try store.groups(matching: nil)
            if groups.isEmpty {
                return MCPToolResult(success: true, output: MCPOutput(content: "No contact groups found."))
            }

            var output = "Contact Groups (\(groups.count)):\n\n"
            for group in groups.sorted(by: { $0.name < $1.name }) {
                output += "- \(group.name)\n"
            }
            return MCPToolResult(success: true, output: MCPOutput(content: output))
        } catch {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to list groups: \(error.localizedDescription)"))
        }
    }

    @MainActor
    private func searchGroup(parameters: [String: Any]) async -> MCPToolResult {
        guard await requestAccess() else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Contacts access denied."))
        }

        guard let groupName = parameters["group_name"] as? String else {
            return MCPToolResult(success: false, output: MCPOutput(content: "Missing required parameter: group_name"))
        }

        do {
            let groups = try store.groups(matching: nil)
            guard let group = groups.first(where: { $0.name.lowercased() == groupName.lowercased() }) else {
                let available = groups.map { $0.name }.joined(separator: ", ")
                return MCPToolResult(success: false, output: MCPOutput(content: "Group '\(groupName)' not found. Available: \(available)"))
            }

            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)

            if contacts.isEmpty {
                return MCPToolResult(success: true, output: MCPOutput(content: "No contacts in group '\(group.name)'."))
            }

            var output = "Contacts in '\(group.name)' (\(contacts.count)):\n\n"
            for contact in contacts.prefix(30) {
                output += formatContact(contact) + "\n"
            }
            if contacts.count > 30 {
                output += "... and \(contacts.count - 30) more."
            }
            return MCPToolResult(success: true, output: MCPOutput(content: output))
        } catch {
            return MCPToolResult(success: false, output: MCPOutput(content: "Failed to search group: \(error.localizedDescription)"))
        }
    }
}
