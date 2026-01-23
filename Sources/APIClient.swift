//
//  APIClient.swift
//  ResendSwift
//
//  Created by Onnwen Cassitto on 06/07/25.
//

import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

func getConfigureClient(credentials _: EffattaInvoicesCredentials) throws -> APIProtocol {
    Client(
        serverURL: URL(string: "https://fattura.effatta.it")!,
        transport: URLSessionTransport(),
    )
}
