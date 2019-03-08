import Foundation

public func log(_ object: Any, flush: Bool = false) {
    fputs("\(object)\n", stderr)
    if flush {
        fflush(stderr)
    }
}

public typealias JSONDictionary = [String: Any]

struct InvocationError: Codable {
    let errorMessage: String
}

public class Runtime {
    var counter = 0
    let urlSession: URLSession
    let awsLambdaRuntimeAPI: String
    let handlerName: String
    var handlers: [String: Handler]

    public init() throws {
        urlSession = URLSession.shared
        handlers = [:]

        let environment = ProcessInfo.processInfo.environment
        guard let awsLambdaRuntimeAPI = environment["AWS_LAMBDA_RUNTIME_API"],
            let handler = environment["_HANDLER"] else {
            throw RuntimeError.missingEnvironmentVariables
        }

        guard let periodIndex = handler.index(of: ".") else {
            throw RuntimeError.invalidHandlerName
        }

        self.awsLambdaRuntimeAPI = awsLambdaRuntimeAPI
        handlerName = String(handler[handler.index(after: periodIndex)...])
    }

    func getNextInvocation() throws -> (eventData: Data, responseHeaderFields: [AnyHashable: Any]) {
        let getNextInvocationEndpoint = URL(string: "http://\(awsLambdaRuntimeAPI)/2018-06-01/runtime/invocation/next")!
        let (optData, optResponse, optError) = urlSession.synchronousDataTask(with: getNextInvocationEndpoint)

        if let d = optData {
            log("data: \(String(data: d, encoding: .utf8) ?? "n/a")")
        } else {
            log("data: n/a")
        }

        if let r = optResponse {
            log("response: \(r)")
        } else {
            log("response: n/a")
        }

        if let e = optError {
            log("error: \(e.localizedDescription)")
        } else {
            log("error: n/a")
        }

        guard optError == nil else {
            throw RuntimeError.endpointError(optError!.localizedDescription)
        }

        guard let eventData = optData else {
            throw RuntimeError.missingData
        }

        let httpResponse = optResponse as! HTTPURLResponse
        return (eventData: eventData, responseHeaderFields: httpResponse.allHeaderFields)
    }

    func postInvocationResponse(for requestId: String, httpBody: Data) {
        let postInvocationResponseEndpoint = URL(string: "http://\(awsLambdaRuntimeAPI)/2018-06-01/runtime/invocation/\(requestId)/response")!
        var urlRequest = URLRequest(url: postInvocationResponseEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = httpBody
        _ = urlSession.synchronousDataTask(with: urlRequest)
    }

    func postInvocationError(for requestId: String, error: Error) {
        let errorMessage = String(describing: error)
        let invocationError = InvocationError(errorMessage: errorMessage)
        let jsonEncoder = JSONEncoder()
        let httpBody = try! jsonEncoder.encode(invocationError)

        let postInvocationErrorEndpoint = URL(string: "http://\(awsLambdaRuntimeAPI)/2018-06-01/runtime/invocation/\(requestId)/error")!
        var urlRequest = URLRequest(url: postInvocationErrorEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = httpBody
        _ = urlSession.synchronousDataTask(with: urlRequest)
    }

    public func registerLambda(_ name: String, handlerFunction: @escaping (JSONDictionary, Context) throws -> JSONDictionary) {
        let handler = JSONSerializationHandler(handlerFunction: handlerFunction)
        handlers[name] = handler
    }

    public func registerLambda<Event: Decodable, Result: Encodable>(_ name: String, handlerFunction: @escaping (Event, Context) throws -> Result) {
        let handler = CodableHandler(handlerFunction: handlerFunction)
        handlers[name] = handler
    }

    public func start() throws {
        while true {
            let (eventData, responseHeaderFields) = try getNextInvocation()
            counter += 1
            log("InvocationCounter: \(counter)")

            guard let handler = handlers[handlerName] else {
                throw RuntimeError.unknownLambdaHandler
            }

            if let lambdaRuntimeTraceId = responseHeaderFields["Lambda-Runtime-Trace-Id"] as? String {
                setenv("_X_AMZN_TRACE_ID", lambdaRuntimeTraceId, 0)
            }

            let environment = ProcessInfo.processInfo.environment
            let context = Context(environment: environment, responseHeaderFields: responseHeaderFields)

            do {
                let resultData = try handler.apply(eventData: eventData, context: context)
                postInvocationResponse(for: context.awsRequestId, httpBody: resultData)
            } catch {
                postInvocationError(for: context.awsRequestId, error: error)
            }
        }
    }
}

