import Foundation

struct TypeWhisperStatus: Decodable {
    let engine: String?
    let model: String?
    let status: String?
}

/// Client for the TypeWhisper app's local HTTP API (default http://localhost:8978/v1).
/// Everything stays on-device; the API is localhost-only.
final class TypeWhisperClient {
    enum ClientError: LocalizedError {
        case notReachable
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notReachable:
                return "TypeWhisper is not reachable on localhost:8978. Launch the TypeWhisper app and enable its API server in Settings."
            case let .http(code, body):
                return "TypeWhisper returned HTTP \(code): \(body.prefix(200))"
            case .badResponse:
                return "TypeWhisper returned an unexpected response."
            }
        }
    }

    private struct TranscribeResponse: Decodable {
        let text: String
    }

    private let baseURL = URL(string: "http://localhost:8978/v1")!
    private let session: URLSession

    init() {
        // Local model inference can be slow on long chunks; keep generous timeouts.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 1800
        session = URLSession(configuration: configuration)
    }

    func status() async throws -> TypeWhisperStatus {
        let url = baseURL.appendingPathComponent("status")
        do {
            let (data, _) = try await session.data(from: url)
            return try JSONDecoder().decode(TypeWhisperStatus.self, from: data)
        } catch is URLError {
            throw ClientError.notReachable
        }
    }

    /// Transcribes one chunk; retries once on transport errors or 5xx.
    func transcribe(fileURL: URL) async throws -> String {
        do {
            return try await transcribeOnce(fileURL: fileURL)
        } catch let error as ClientError {
            guard case let .http(code, _) = error, code >= 500 else { throw error }
        } catch is URLError {
            // retry below
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return try await transcribeOnce(fileURL: fileURL)
    }

    private func transcribeOnce(fileURL: URL) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcribe"))
        request.httpMethod = "POST"
        let boundary = "meetwhisper-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        body.appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(TranscribeResponse.self, from: data).text
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
