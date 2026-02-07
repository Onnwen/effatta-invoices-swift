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

        guard case let .ok(body) = response else {
            dump(response)
            throw EffattaInvoicesError.badStatusCode
        }

        do {
            guard let jsonString = try body.body.json.d else {
                dump(response)
                throw EffattaInvoicesError.badResponse
            }

            return try decodeAsmxPayload(jsonString)
        } catch {
            dump(error)
            dump(error.localizedDescription)
            throw EffattaInvoicesError.unknown
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

        guard case let .ok(body) = response else {
            dump(response)
            throw EffattaInvoicesError.badStatusCode
        }

        do {
            guard let jsonString = try body.body.json.d else {
                dump(response)
                throw EffattaInvoicesError.badResponse
            }

            let body: Components.Schemas.CreaNotaCreditoTotaleData = try decodeAsmxPayload(jsonString)

            guard let documentId = body.idDocumento else {
                dump(response)
                throw EffattaInvoicesError.badResponse
            }

            return documentId
        } catch {
            dump(error)
            dump(error.localizedDescription)
            throw EffattaInvoicesError.unknown
        }
    }

    public enum EffattaInvoicesError: Error {
        case unknown
        case status(Int)
        case invalidEnvironmentURL
        case badStatusCode
        case badResponse
        case failedReadingPDF(String)
    }

    public enum AsmxDecodeError: Error {
        case invalidUTF8
    }

    private func decodeAsmxPayload<T: Decodable>(
        _ d: String,
        decoder: JSONDecoder = JSONDecoder(),
    ) throws -> T {
        guard let data = d.data(using: .utf8) else {
            dump(d)
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

        guard case let .ok(body) = response else {
            dump(response)
            throw EffattaInvoicesError.badStatusCode
        }

        do {
            guard let jsonString = try body.body.json.d else {
                dump(response)
                throw EffattaInvoicesError.badResponse
            }

            let body: Components.Schemas.LoginData = try decodeAsmxPayload(jsonString)

            guard let token = body.token,
                  let userId = body.userId
            else {
                dump(response)
                throw EffattaInvoicesError.badResponse
            }

            authentication = .init(
                token: token,
                userId: userId,
                expiresAt: Date().addingTimeInterval(60 * 55),
            )
        } catch {
            dump(error)
            dump(error.localizedDescription)
            throw EffattaInvoicesAuthenticationError.tokenRefreshFailed
        }

        guard let authentication else {
            throw EffattaInvoicesAuthenticationError.tokenMissing
        }

        return authentication
    }

    private struct EffattaInvoicesAuthentication {
        var token: String
        var userId: String
        var expiresAt: Date
    }

    enum EffattaInvoicesAuthenticationError: Error {
        case tokenRefreshFailed
        case tokenMissing
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
