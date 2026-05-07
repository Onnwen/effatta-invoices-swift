//
//  EffattaReceiptsClient.swift
//  effatta-invoices-swift
//
//  Created by Onnwen Cassitto on 20/01/26.
//

import Foundation
import OpenAPIRuntime

public final actor EffattaInvoicesClient {
    private let client: APIProtocol

    private let credentials: EffattaInvoicesCredentials
    private var authentication: EffattaInvoicesAuthentication?

    private static let debugBodyByteLimit = 256 * 1024

    public init(credentials: EffattaInvoicesCredentials) throws {
        self.credentials = credentials
        client = try getConfigureClient(credentials: credentials)
    }

    public func createInvoice(_ document: Components.Schemas.CreaDocumentoRequest) async throws -> Components.Schemas.CreaDocumentoData {
        let authentication = try await checkAuthentication()

        var updatedDocument = document
        updatedDocument.token = authentication.token
        updatedDocument.idMittente = authentication.userId

        let response = try await client.creaDocumentoV2(
            .init(
                body: .json(updatedDocument),
            ),
        )

        let okBody: Operations.creaDocumentoV2.Output.Ok
        switch response {
        case .ok(let body):
            okBody = body
        case .undocumented(let statusCode, let payload):
            throw EffattaInvoicesError.unexpectedStatus(
                operation: "creaDocumentoV2",
                statusCode: statusCode,
                body: await Self.debugBody(payload.body),
            )
        }

        guard let jsonString = try okBody.body.json.d else {
            throw EffattaInvoicesError.missingPayload(operation: "creaDocumentoV2", body: nil)
        }

        do {
            return try decodeAsmxPayload(jsonString)
        } catch {
            throw EffattaInvoicesError.decodingFailed(
                operation: "creaDocumentoV2",
                payload: jsonString,
                underlying: error,
            )
        }
    }

    public func cancelInvoice(_ documentId: String, documentNumber: String) async throws -> String {
        let authentication = try await checkAuthentication()

        let response = try await client.creaNotaCreditoNumero(
            query: .init(
                token: authentication.token,
                idMittente: authentication.userId,
                idFattura: documentId,
                numeroDocumento: documentNumber
            )
        )

        let okBody: Operations.creaNotaCreditoNumero.Output.Ok
        switch response {
        case .ok(let body):
            okBody = body
        case .undocumented(let statusCode, let payload):
            throw EffattaInvoicesError.unexpectedStatus(
                operation: "creaNotaCreditoNumero",
                statusCode: statusCode,
                body: await Self.debugBody(payload.body),
            )
        }

        guard let jsonString = try okBody.body.json.d else {
            throw EffattaInvoicesError.missingPayload(operation: "creaNotaCreditoNumero", body: nil)
        }

        let body: Components.Schemas.CreaNotaCreditoTotaleData
        do {
            body = try decodeAsmxPayload(jsonString)
        } catch {
            throw EffattaInvoicesError.decodingFailed(
                operation: "creaNotaCreditoNumero",
                payload: jsonString,
                underlying: error,
            )
        }

        guard let documentId = body.idDocumento else {
            throw EffattaInvoicesError.missingField(
                operation: "creaNotaCreditoNumero",
                field: "idDocumento",
                payload: jsonString,
            )
        }

        return documentId
    }

    public func getInvoiceStatus(_ documentId: String) async throws -> ADEInvoiceStatus {
        let authentication = try await checkAuthentication()

        let response = try await client.getEsitoDocument(
            .init(
                query: .init(
                    token: authentication.token,
                    idMittente: authentication.userId,
                    idFattura: documentId
                )
            )
        )

        let okBody: Operations.getEsitoDocument.Output.Ok
        switch response {
        case .ok(let body):
            okBody = body
        case .notFound:
            return .notFound
        case .undocumented(let statusCode, let payload):
            throw EffattaInvoicesError.unexpectedStatus(
                operation: "getEsitoDocument",
                statusCode: statusCode,
                body: await Self.debugBody(payload.body),
            )
        }

        guard let jsonString = try okBody.body.json.d else {
            throw EffattaInvoicesError.missingPayload(operation: "getEsitoDocument", body: nil)
        }

        let decodedPayload: Components.Schemas.EsitoDocumento
        do {
            decodedPayload = try decodeAsmxPayload(jsonString)
        } catch {
            throw EffattaInvoicesError.decodingFailed(
                operation: "getEsitoDocument",
                payload: jsonString,
                underlying: error,
            )
        }

        if let last = decodedPayload.Lista_Esiti.last, let adeEsitoLast = ADEInvoiceStatus(esito: last) {
            return adeEsitoLast
        }
        return .unkown(raw: "Stato sconosciuto")
    }

    public enum EffattaInvoicesError: Error, CustomStringConvertible, LocalizedError {
        case unexpectedStatus(operation: String, statusCode: Int, body: String?)
        case missingPayload(operation: String, body: String?)
        case missingField(operation: String, field: String, payload: String?)
        case decodingFailed(operation: String, payload: String, underlying: any Error & Sendable)
        case invalidEnvironmentURL
        case failedReadingPDF(String)

        public var description: String {
            switch self {
            case let .unexpectedStatus(operation, statusCode, body):
                return "EffattaInvoices[\(operation)] unexpected HTTP \(statusCode)\(Self.formatBody(body))"
            case let .missingPayload(operation, body):
                return "EffattaInvoices[\(operation)] missing ASMX `d` payload\(Self.formatBody(body))"
            case let .missingField(operation, field, payload):
                return "EffattaInvoices[\(operation)] missing field `\(field)`\(Self.formatBody(payload))"
            case let .decodingFailed(operation, payload, underlying):
                return "EffattaInvoices[\(operation)] decode failed: \(underlying)\(Self.formatBody(payload))"
            case .invalidEnvironmentURL:
                return "EffattaInvoices invalid environment URL"
            case let .failedReadingPDF(detail):
                return "EffattaInvoices failed reading PDF: \(detail)"
            }
        }

        public var errorDescription: String? { description }

        private static func formatBody(_ body: String?) -> String {
            guard let body, !body.isEmpty else { return "" }
            return " — body: \(body)"
        }
    }

    public enum AsmxDecodeError: Error {
        case invalidUTF8
    }

    private static func debugBody(_ body: HTTPBody?) async -> String? {
        guard let body else { return nil }
        do {
            return try await String(collecting: body, upTo: debugBodyByteLimit)
        } catch {
            return "<body read failed: \(error)>"
        }
    }

    private func decodeAsmxPayload<T: Decodable>(
        _ d: String,
        decoder: JSONDecoder = JSONDecoder(),
    ) throws -> T {
        guard let data = d.data(using: .utf8) else {
            throw AsmxDecodeError.invalidUTF8
        }
        return try decoder.decode(T.self, from: data)
    }
}

extension EffattaInvoicesClient {
    private func checkAuthentication() async throws -> EffattaInvoicesAuthentication {
        guard authentication == nil || authentication!.expiresAt < Date() else {
            guard let authentication else {
                throw EffattaInvoicesAuthenticationError.tokenMissing
            }
            return authentication
        }

        let response = try await client.login(
            .init(
                body: .json(
                    .init(
                        username: credentials.username,
                        password: credentials.password,
                        source: credentials.source,
                    ),
                ),
            ),
        )

        let okBody: Operations.login.Output.Ok
        switch response {
        case .ok(let body):
            okBody = body
        case .undocumented(let statusCode, let payload):
            throw EffattaInvoicesAuthenticationError.loginFailed(
                statusCode: statusCode,
                body: await Self.debugBody(payload.body),
            )
        }

        guard let jsonString = try okBody.body.json.d else {
            throw EffattaInvoicesAuthenticationError.loginPayloadInvalid(payload: nil, underlying: nil)
        }

        let body: Components.Schemas.LoginData
        do {
            body = try decodeAsmxPayload(jsonString)
        } catch {
            throw EffattaInvoicesAuthenticationError.loginPayloadInvalid(payload: jsonString, underlying: error)
        }

        guard let token = body.token,
              let userId = body.userId
        else {
            throw EffattaInvoicesAuthenticationError.loginPayloadInvalid(payload: jsonString, underlying: nil)
        }

        let authentication = EffattaInvoicesAuthentication(
            token: token,
            userId: userId,
            expiresAt: Date().addingTimeInterval(60 * 55),
        )
        self.authentication = authentication
        return authentication
    }

    private struct EffattaInvoicesAuthentication {
        var token: String
        var userId: String
        var expiresAt: Date
    }

    enum EffattaInvoicesAuthenticationError: Error, CustomStringConvertible, LocalizedError {
        case loginFailed(statusCode: Int, body: String?)
        case loginPayloadInvalid(payload: String?, underlying: (any Error & Sendable)?)
        case tokenMissing

        var description: String {
            switch self {
            case let .loginFailed(statusCode, body):
                if let body, !body.isEmpty {
                    return "EffattaInvoices[login] HTTP \(statusCode) — body: \(body)"
                }
                return "EffattaInvoices[login] HTTP \(statusCode)"
            case let .loginPayloadInvalid(payload, underlying):
                var parts: [String] = ["EffattaInvoices[login] login payload invalid"]
                if let underlying { parts.append("error: \(underlying)") }
                if let payload, !payload.isEmpty { parts.append("payload: \(payload)") }
                return parts.joined(separator: " — ")
            case .tokenMissing:
                return "EffattaInvoices[login] token missing"
            }
        }

        var errorDescription: String? { description }
    }

    public enum ADEInvoiceStatus: Sendable {
        case mancataConsegna
        case consegnata
        case scarto(error: String?, reason: String?)
        case invio
        case notFound
        case unkown(raw: String?)

        init?(esito: Components.Schemas.Esito) {
            switch esito.Titolo.value1 {
            case .INVIO_space_SDI:
                self = .invio
            case .NOTIFICA_space_MANCATA_space_CONSEGNA:
                self = .mancataConsegna
            case .RICEVUTA_space_CONSEGNA:
                self = .consegnata
            case .NOTIFICA_space_SCARTO:
                self = .scarto(error: esito.Codice_Errore, reason: esito.Descrizione_Errore)
            default:
                self = .unkown(raw: esito.Titolo.value2)
            }
        }
    }
}

public struct EffattaInvoicesCredentials: Sendable {
    let username: String
    let password: String
    let source: String

    public init(username: String, password: String, source: String) {
        self.username = username
        self.password = password
        self.source = source
    }
}
