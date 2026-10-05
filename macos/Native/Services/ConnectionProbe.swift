import Foundation
import Network

enum ConnectionProbe {
    static func request(url: URL, httpPort: Int) async throws -> (Data, HTTPURLResponse) {
        guard let rawPort = UInt16(exactly: httpPort), let port = NWEndpoint.Port(rawValue: rawPort) else {
            throw ClientError.message("HTTP 代理端口无效。")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))
        proxy.allowFailover = false
        configuration.proxyConfigurations = [proxy]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ClientError.message("测试请求未成功返回。")
        }
        return (data, response)
    }
}
