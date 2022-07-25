//
//  Created by Alexander Vlasov.
//  Copyright © 2018 Alexander Vlasov. All rights reserved.
//

import Foundation
import BigInt

public class EthereumContract: ContractProtocol {

    public var transactionOptions: TransactionOptions? = TransactionOptions.defaultOptions
    public var address: EthereumAddress? = nil

    public let abi: [ABI.Element]

    private(set) public lazy var methods: [String: [ABI.Element.Function]] = {
        var methods = [String: [ABI.Element.Function]]()

        func appendFunction(_ key: String, _ value: ABI.Element.Function) {
            var array = methods[key] ?? []
            array.append(value)
            methods[key] = array
        }

        for case let .function(function) in abi where function.name != nil {
            appendFunction(function.name!, function)
            appendFunction(function.signature, function)
            appendFunction(function.methodString.addHexPrefix().lowercased(), function)

            /// ABI cannot have two functions with exactly the same name and input arguments
            if (methods[function.signature]?.count ?? 0) > 1 {
                fatalError("Given ABI is invalid: contains two functions with possibly different return values but exactly the same name and input parameters!")
            }
        }
        return methods
    }()

    private(set) public lazy var allMethods: [ABI.Element.Function] = {
        return methods.filter { pair in
            let data = Data.fromHex(pair.key)
            return data?.count == 4
        }.values.flatMap { $0 }
    }()

    private(set) public lazy var events: [String: ABI.Element.Event] = {
        var events = [String: ABI.Element.Event]()
        for case let .event(event) in abi {
            events[event.name] = event
            if !event.anonymous {
                events[event.topic.toHexString().addHexPrefix()] = event
            }
        }
        return events
    }()

    private(set) public lazy var allEvents: [ABI.Element.Event] = {
        return Array(events.filter({ (key: String, _) in
            Data.fromHex(key) == nil
        }).values)
    }()

    private(set) public lazy var constructor: ABI.Element.Constructor = {
        for element in abi {
            switch element {
            case let .constructor(constructor):
                return constructor
            default:
                continue
            }
        }
        return ABI.Element.Constructor(inputs: [], constant: false, payable: false)
    }()

    public init(abi: [ABI.Element]) {
        self.abi = abi
    }

    public init(abi: [ABI.Element], at: EthereumAddress) {
        self.abi = abi
        address = at
    }

    public required init?(_ abiString: String, at: EthereumAddress? = nil) {
        do {
            let jsonData = abiString.data(using: .utf8)
            let abi = try JSONDecoder().decode([ABI.Record].self, from: jsonData!)
            let abiNative = try abi.map({ (record) -> ABI.Element in
                return try record.parse()
            })
            self.abi = abiNative
            if at != nil {
                self.address = at
            }
        } catch {
            return nil
        }
    }

    public func deploy(bytecode: Data,
                       constructor: ABI.Element.Constructor?,
                       parameters: [AnyObject]?,
                       extraData: Data?) -> EthereumTransaction? {
        var fullData = bytecode

        if let constructor = constructor,
            let parameters = parameters,
            !parameters.isEmpty {
            guard constructor.inputs.count == parameters.count,
                let encodedData = constructor.encodeParameters(parameters)
            else {
                NSLog("Constructor encoding will fail as the number of input arguments doesn't match the number of given arguments.")
                return nil
            }
            fullData.append(encodedData)
        }

        if let extraData = extraData {
            fullData.append(extraData)
        }

        return EthereumTransaction(to: .contractDeploymentAddress(),
                                   value: BigUInt(0),
                                   data: fullData,
                                   parameters: .init(gasLimit: BigUInt(0), gasPrice: BigUInt(0)))
    }

    public func method(_ method: String,
                       parameters: [AnyObject],
                       extraData: Data?) -> EthereumTransaction? {
        guard let to = self.address else { return nil }

        let params = EthereumParameters(gasLimit: BigUInt(0), gasPrice: BigUInt(0))

        if method == "fallback" {
            return EthereumTransaction(to: to, value: BigUInt(0), data: extraData ?? Data(), parameters: params)
        }

        let method = Data.fromHex(method) == nil ? method : method.addHexPrefix().lowercased()

        guard let abiMethod = methods[method]?.first,
              var encodedData = abiMethod.encodeParameters(parameters) else { return nil }

        if let extraData = extraData {
            encodedData.append(extraData)
        }

        return EthereumTransaction(to: to, value: BigUInt(0), data: encodedData, parameters: params)
    }

    public func parseEvent(_ eventLog: EventLog) -> (eventName: String?, eventData: [String: Any]?) {
        func parseEventData(event: ABI.Element.Event) -> [String: Any]? {
            event.decodeReturnedLogs(eventLogTopics: eventLog.topics, eventLogData: eventLog.data)
        }

        if let topic = eventLog.topics.first?.toHexString(),
           let event = events[topic],
           let eventData = parseEventData(event: event) {
            return (event.name, eventData)
        }

        for event in allEvents {
            if let eventData = parseEventData(event: event) {
                return (event.name, eventData)
            }
        }
        return (nil, nil)
    }

    public func testBloomForEventPrecence(eventName: String, bloom: EthereumBloomFilter) -> Bool? {
        guard let event = events[eventName] else { return nil }
        if event.anonymous {
            return true
        }
        return bloom.test(topic: event.topic)
    }

    public func decodeReturnData(_ method: String, data: Data) -> [String: Any]? {
        if method == "fallback" {
            return [String: Any]()
        }
        return methods[method]?.compactMap({ function in
            return function.decodeReturnData(data)
        }).first
    }

    public func decodeInputData(_ method: String, data: Data) -> [String: Any]? {
        if method == "fallback" {
            return nil
        }
        return methods[method]?.compactMap({ function in
            return function.decodeInputData(data)
        }).first
    }

    public func decodeInputData(_ data: Data) -> [String: Any]? {
        guard data.count % 32 == 4 else { return nil }
        let methodSignature = data[0..<4].toHexString().addHexPrefix().lowercased()

        guard let function = methods[methodSignature]?.first else { return nil }
        return function.decodeInputData(Data(data[4 ..< data.count]))
    }
}
