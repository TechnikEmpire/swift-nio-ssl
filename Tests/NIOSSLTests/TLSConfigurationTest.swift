//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
#if compiler(>=5.1)
@_implementationOnly import CNIOBoringSSL
#else
import CNIOBoringSSL
#endif
import NIO
@testable import NIOSSL
import NIOTLS

class ErrorCatcher<T: Error>: ChannelInboundHandler {
    public typealias InboundIn = Any
    public var errors: [T]

    public init() {
        errors = []
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        errors.append(error as! T)
    }
}

class HandshakeCompletedHandler: ChannelInboundHandler {
    public typealias InboundIn = Any
    public var handshakeSucceeded = false

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? TLSUserEvent, case .handshakeCompleted = event {
            self.handshakeSucceeded = true
        }
        context.fireUserInboundEventTriggered(event)
    }
}

class WaitForHandshakeHandler: ChannelInboundHandler {
    public typealias InboundIn = Any
    public var handshakeResult: EventLoopFuture<Void> {
        return self.handshakeResultPromise.futureResult
    }

    private var handshakeResultPromise: EventLoopPromise<Void>

    init(handshakeResultPromise: EventLoopPromise<Void>) {
        self.handshakeResultPromise = handshakeResultPromise
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? TLSUserEvent, case .handshakeCompleted = event {
            self.handshakeResultPromise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let error = error as? NIOSSLError, case .handshakeFailed = error {
            self.handshakeResultPromise.fail(error)
        }
        context.fireErrorCaught(error)
    }
}

class TLSConfigurationTest: XCTestCase {
    static var cert1: NIOSSLCertificate!
    static var key1: NIOSSLPrivateKey!

    static var cert2: NIOSSLCertificate!
    static var key2: NIOSSLPrivateKey!

    override class func setUp() {
        super.setUp()
        var (cert, key) = generateSelfSignedCert()
        TLSConfigurationTest.cert1 = cert
        TLSConfigurationTest.key1 = key

        (cert, key) = generateSelfSignedCert()
        TLSConfigurationTest.cert2 = cert
        TLSConfigurationTest.key2 = key
    }

    func assertHandshakeError(withClientConfig clientConfig: TLSConfiguration,
                              andServerConfig serverConfig: TLSConfiguration,
                              errorTextContains message: String,
                              file: StaticString = #file,
                              line: UInt = #line) throws {
        return try assertHandshakeError(withClientConfig: clientConfig,
                                        andServerConfig: serverConfig,
                                        errorTextContainsAnyOf: [message],
                                        file: file,
                                        line: line)
    }

    func assertHandshakeError(withClientConfig clientConfig: TLSConfiguration,
                              andServerConfig serverConfig: TLSConfiguration,
                              errorTextContainsAnyOf messages: [String],
                              file: StaticString = #file,
                              line: UInt = #line) throws {
        let clientContext = try assertNoThrowWithValue(NIOSSLContext(configuration: clientConfig), file: file, line: line)
        let serverContext = try assertNoThrowWithValue(NIOSSLContext(configuration: serverConfig), file: file, line: line)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let eventHandler = ErrorCatcher<NIOSSLError>()
        let handshakeHandler = HandshakeCompletedHandler()
        let serverChannel = try assertNoThrowWithValue(serverTLSChannel(context: serverContext, handlers: [], group: group), file: file, line: line)
        let clientChannel = try assertNoThrowWithValue(clientTLSChannel(context: clientContext, preHandlers:[], postHandlers: [eventHandler, handshakeHandler], group: group, connectingTo: serverChannel.localAddress!), file: file, line: line)

        // We expect the channel to be closed fairly swiftly as the handshake should fail.
        clientChannel.closeFuture.whenComplete { _ in
            XCTAssertEqual(eventHandler.errors.count, 1)

            switch eventHandler.errors[0] {
            case .handshakeFailed(.sslError(let errs)):
                let correctError: Bool = messages.map { errs[0].description.contains($0) }.reduce(false) { $0 || $1 }
                XCTAssert(correctError, errs[0].description, file: (file), line: line)
            default:
                XCTFail("Unexpected error: \(eventHandler.errors[0])", file: (file), line: line)
            }

            XCTAssertFalse(handshakeHandler.handshakeSucceeded, file: (file), line: line)
        }
        try clientChannel.closeFuture.wait()
    }

    func assertPostHandshakeError(withClientConfig clientConfig: TLSConfiguration,
                                  andServerConfig serverConfig: TLSConfiguration,
                                  errorTextContainsAnyOf messages: [String],
                                  file: StaticString = #file,
                                  line: UInt = #line) throws {
        let clientContext = try assertNoThrowWithValue(NIOSSLContext(configuration: clientConfig), file: file, line: line)
        let serverContext = try assertNoThrowWithValue(NIOSSLContext(configuration: serverConfig), file: file, line: line)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let eventHandler = ErrorCatcher<BoringSSLError>()
        let handshakeHandler = HandshakeCompletedHandler()
        let serverChannel = try assertNoThrowWithValue(serverTLSChannel(context: serverContext, handlers: [], group: group), file: file, line: line)
        let clientChannel = try assertNoThrowWithValue(clientTLSChannel(context: clientContext, preHandlers:[], postHandlers: [eventHandler, handshakeHandler], group: group, connectingTo: serverChannel.localAddress!), file: file, line: line)

        // We expect the channel to be closed fairly swiftly as the handshake should fail.
        clientChannel.closeFuture.whenComplete { _ in
            XCTAssertEqual(eventHandler.errors.count, 1, file: (file), line: line)

            switch eventHandler.errors[0] {
            case .sslError(let errs):
                XCTAssertEqual(errs.count, 1, file: (file), line: line)
                let correctError: Bool = messages.map { errs[0].description.contains($0) }.reduce(false) { $0 || $1 }
                XCTAssert(correctError, errs[0].description, file: (file), line: line)
            default:
                XCTFail("Unexpected error: \(eventHandler.errors[0])", file: (file), line: line)
            }

            XCTAssertTrue(handshakeHandler.handshakeSucceeded, file: (file), line: line)
        }
        try clientChannel.closeFuture.wait()
    }

    /// Performs a connection in memory and validates that the handshake was successful.
    ///
    /// - NOTE: This function should only be used when you know that there is no custom verification
    /// callback in use, otherwise it will not be thread-safe.
    func assertHandshakeSucceededInMemory(withClientConfig clientConfig: TLSConfiguration,
                                          andServerConfig serverConfig: TLSConfiguration,
                                          file: StaticString = #file,
                                          line: UInt = #line) throws {
        let clientContext = try assertNoThrowWithValue(NIOSSLContext(configuration: clientConfig))
        let serverContext = try assertNoThrowWithValue(NIOSSLContext(configuration: serverConfig))

        let serverChannel = EmbeddedChannel()
        let clientChannel = EmbeddedChannel()

        defer {
            // We expect the server case to throw
            _ = try? serverChannel.finish()
            _ = try? clientChannel.finish()
        }

        XCTAssertNoThrow(try serverChannel.pipeline.addHandler(NIOSSLServerHandler(context: serverContext)).wait(), file: (file), line: line)
        XCTAssertNoThrow(try clientChannel.pipeline.addHandler(NIOSSLClientHandler(context: clientContext, serverHostname: nil)).wait(), file: (file), line: line)
        let handshakeHandler = HandshakeCompletedHandler()
        XCTAssertNoThrow(try clientChannel.pipeline.addHandler(handshakeHandler).wait(), file: (file), line: line)

        // Connect. This should lead to a completed handshake.
        XCTAssertNoThrow(try connectInMemory(client: clientChannel, server: serverChannel), file: (file), line: line)
        XCTAssertTrue(handshakeHandler.handshakeSucceeded, file: (file), line: line)

        _ = serverChannel.close()
        try interactInMemory(clientChannel: clientChannel, serverChannel: serverChannel)
    }

    /// Performs a connection using a real event loop and validates that the handshake was successful.
    ///
    /// This function is thread-safe in the presence of custom verification callbacks.
    func assertHandshakeSucceededEventLoop(withClientConfig clientConfig: TLSConfiguration,
                                           andServerConfig serverConfig: TLSConfiguration,
                                           file: StaticString = #file,
                                           line: UInt = #line) throws {
        let clientContext = try assertNoThrowWithValue(NIOSSLContext(configuration: clientConfig), file: file, line: line)
        let serverContext = try assertNoThrowWithValue(NIOSSLContext(configuration: serverConfig), file: file, line: line)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let eventHandler = ErrorCatcher<BoringSSLError>()
        let handshakeHandler = HandshakeCompletedHandler()
        let handshakeResultPromise = group.next().makePromise(of: Void.self)
        let handshakeWatcher = WaitForHandshakeHandler(handshakeResultPromise: handshakeResultPromise)

        let serverChannel = try assertNoThrowWithValue(serverTLSChannel(context: serverContext, handlers: [], group: group), file: file, line: line)
        let clientChannel = try assertNoThrowWithValue(clientTLSChannel(context: clientContext, preHandlers:[], postHandlers: [eventHandler, handshakeWatcher, handshakeHandler], group: group, connectingTo: serverChannel.localAddress!), file: file, line: line)

        handshakeWatcher.handshakeResult.whenComplete { c in
            _ = clientChannel.close()
        }

        clientChannel.closeFuture.whenComplete { _ in
            XCTAssertEqual(eventHandler.errors.count, 0, file: file, line: line)
            XCTAssertTrue(handshakeHandler.handshakeSucceeded, file: file, line: line)
        }
        try clientChannel.closeFuture.wait()
    }

    func assertHandshakeSucceeded(withClientConfig clientConfig: TLSConfiguration,
                                  andServerConfig serverConfig: TLSConfiguration,
                                  file: StaticString = #file,
                                  line: UInt = #line) throws {
        // The only use of a custom callback is on Darwin...
        #if os(Linux)
        return try assertHandshakeSucceededInMemory(withClientConfig: clientConfig, andServerConfig: serverConfig, file: file, line: line)

        #else
        return try assertHandshakeSucceededEventLoop(withClientConfig: clientConfig, andServerConfig: serverConfig, file: file, line: line)
        #endif
    }

    func testNonOverlappingTLSVersions() throws {
        var clientConfig = TLSConfiguration.clientDefault
        clientConfig.minimumTLSVersion = .tlsv11
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.maximumTLSVersion = .tlsv1

        try assertHandshakeError(withClientConfig: clientConfig,
                                 andServerConfig: serverConfig,
                                 errorTextContains: "ALERT_PROTOCOL_VERSION")
    }

    func testNonOverlappingCipherSuitesPreTLS13() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.cipherSuiteValues = [.TLS_RSA_WITH_AES_128_CBC_SHA]
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.cipherSuiteValues = [.TLS_RSA_WITH_AES_256_CBC_SHA]
        serverConfig.maximumTLSVersion = .tlsv12

        try assertHandshakeError(withClientConfig: clientConfig, andServerConfig: serverConfig, errorTextContains: "ALERT_HANDSHAKE_FAILURE")
    }

    func testCannotVerifySelfSigned() throws {
        let clientConfig = TLSConfiguration.makeClientConfiguration()
        let serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )

        try assertHandshakeError(withClientConfig: clientConfig, andServerConfig: serverConfig, errorTextContains: "CERTIFICATE_VERIFY_FAILED")
    }

    func testServerCannotValidateClientPreTLS13() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        clientConfig.certificateChain = [.certificate(TLSConfigurationTest.cert2)]
        clientConfig.privateKey = .privateKey(TLSConfigurationTest.key2)

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.maximumTLSVersion = .tlsv12
        serverConfig.certificateVerification = .noHostnameVerification

        try assertHandshakeError(withClientConfig: clientConfig, andServerConfig: serverConfig, errorTextContainsAnyOf: ["ALERT_UNKNOWN_CA", "ALERT_CERTIFICATE_UNKNOWN"])
    }

    func testServerCannotValidateClientPostTLS13() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.minimumTLSVersion = .tlsv13
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        clientConfig.certificateChain = [.certificate(TLSConfigurationTest.cert2)]
        clientConfig.privateKey = .privateKey(TLSConfigurationTest.key2)

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.minimumTLSVersion = .tlsv13
        serverConfig.certificateVerification = .noHostnameVerification

        try assertPostHandshakeError(withClientConfig: clientConfig, andServerConfig: serverConfig, errorTextContainsAnyOf: ["ALERT_UNKNOWN_CA", "ALERT_CERTIFICATE_UNKNOWN"])
    }

    func testMutualValidationRequiresClientCertificatePreTLS13() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.certificateVerification = .none

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.maximumTLSVersion = .tlsv12
        serverConfig.certificateVerification = .noHostnameVerification
        serverConfig.trustRoots = .certificates([TLSConfigurationTest.cert2])

        try assertHandshakeError(withClientConfig: clientConfig, andServerConfig: serverConfig, errorTextContainsAnyOf: ["ALERT_HANDSHAKE_FAILURE"])
    }

    func testMutualValidationRequiresClientCertificatePostTLS13() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.minimumTLSVersion = .tlsv13
        clientConfig.certificateVerification = .none

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.minimumTLSVersion = .tlsv13
        serverConfig.certificateVerification = .noHostnameVerification
        serverConfig.trustRoots = .certificates([TLSConfigurationTest.cert2])

        try assertPostHandshakeError(withClientConfig: clientConfig, andServerConfig: serverConfig, errorTextContainsAnyOf: ["CERTIFICATE_REQUIRED"])
    }
    
    func testIncompatibleSignatures() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.verifySignatureAlgorithms = [.ecdsaSecp384R1Sha384]
        clientConfig.minimumTLSVersion = .tlsv13
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        clientConfig.renegotiationSupport = .none

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.signingSignatureAlgorithms = [.rsaPssRsaeSha256]
        serverConfig.minimumTLSVersion = .tlsv13
        serverConfig.certificateVerification = .none

        try assertHandshakeError(withClientConfig: clientConfig, andServerConfig: serverConfig, errorTextContains: "ALERT_HANDSHAKE_FAILURE")
    }

    func testCompatibleSignatures() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.minimumTLSVersion = .tlsv13
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.signingSignatureAlgorithms = [.rsaPssRsaeSha256]
        serverConfig.minimumTLSVersion = .tlsv13
        serverConfig.certificateVerification = .none

        try assertHandshakeSucceeded(withClientConfig: clientConfig, andServerConfig: serverConfig)
    }

    func testMatchingCompatibleSignatures() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.verifySignatureAlgorithms = [.rsaPssRsaeSha256]
        clientConfig.minimumTLSVersion = .tlsv13
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        clientConfig.renegotiationSupport = .none

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.signingSignatureAlgorithms = [.rsaPssRsaeSha256]
        serverConfig.minimumTLSVersion = .tlsv13
        serverConfig.certificateVerification = .none

        try assertHandshakeSucceeded(withClientConfig: clientConfig, andServerConfig: serverConfig)
    }


    func testMutualValidationSuccessNoAdditionalTrustRoots() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        clientConfig.renegotiationSupport = .none

        let serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1))

        try assertHandshakeSucceeded(withClientConfig: clientConfig, andServerConfig: serverConfig)
    }

    func testMutualValidationSuccessWithDefaultAndAdditionalTrustRoots() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .default
        clientConfig.renegotiationSupport = .none
        clientConfig.additionalTrustRoots = [.certificates([TLSConfigurationTest.cert1])]

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.trustRoots = .default
        serverConfig.additionalTrustRoots = [.certificates([TLSConfigurationTest.cert2])]

        try assertHandshakeSucceeded(withClientConfig: clientConfig, andServerConfig: serverConfig)
    }

    func testMutualValidationSuccessWithOnlyAdditionalTrustRoots() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([])
        clientConfig.renegotiationSupport = .none
        clientConfig.additionalTrustRoots = [.certificates([TLSConfigurationTest.cert1])]

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.trustRoots = .certificates([])
        serverConfig.additionalTrustRoots = [.certificates([TLSConfigurationTest.cert2])]

        try assertHandshakeSucceeded(withClientConfig: clientConfig, andServerConfig: serverConfig)
    }

    func testNonexistentFileObject() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.trustRoots = .file("/thispathbetternotexist/bogus.foo")

        XCTAssertThrowsError(try NIOSSLContext(configuration: clientConfig)) {error in
            XCTAssertEqual(.noSuchFilesystemObject, error as? NIOSSLError)
        }
    }

    func testComputedApplicationProtocols() throws {
        var config = TLSConfiguration.makeServerConfiguration(certificateChain: [], privateKey: .file("fake.file"))
        config.applicationProtocols = ["http/1.1"]
        XCTAssertEqual(config.applicationProtocols, ["http/1.1"])
        XCTAssertEqual(config.encodedApplicationProtocols, [[8, 104, 116, 116, 112, 47, 49, 46, 49]])
        config.applicationProtocols.insert("h2", at: 0)
        XCTAssertEqual(config.applicationProtocols, ["h2", "http/1.1"])
        XCTAssertEqual(config.encodedApplicationProtocols, [[2, 104, 50], [8, 104, 116, 116, 112, 47, 49, 46, 49]])
    }

    func testKeyLogManagerOverlappingAccess() throws {
        // Tests that we can have overlapping calls to the log() function of the keylog manager.
        // This test fails probabilistically! DO NOT IGNORE INTERMITTENT FAILURES OF THIS TEST.
        let semaphore = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let completionsQueue = DispatchQueue(label: "completionsQueue")
        var completions: [Bool] = []

        func keylogCallback(_ ign: ByteBuffer) {
            completionsQueue.sync {
                completions.append(true)
                semaphore.wait()
            }
            group.leave()
        }

        let keylogManager = KeyLogCallbackManager(callback: keylogCallback(_:))

        // Now we call log twice, from different threads. These will not complete right away so we
        // do those on background threads. They should not both complete.
        group.enter()
        group.enter()
        DispatchQueue(label: "first-thread").async {
            keylogManager.log("hello!")
        }
        DispatchQueue(label: "second-thread").async {
            keylogManager.log("world!")
        }

        // We now sleep a short time to let everything catch up and the runtime catch any exclusivity violation.
        // 10ms is fine.
        usleep(10_000)

        // Great, signal the sempahore twice to un-wedge everything and wait for everything to exit.
        semaphore.signal()
        semaphore.signal()
        group.wait()
        XCTAssertEqual([true, true], completionsQueue.sync { completions })
    }
    
    func testTheSameHashValue() {
        var config = TLSConfiguration.makeServerConfiguration(certificateChain: [], privateKey: .file("fake.file"))
        config.applicationProtocols = ["http/1.1"]
        let theSameConfig = config
        var hasher = Hasher()
        var hasher2 = Hasher()
        config.bestEffortHash(into: &hasher)
        theSameConfig.bestEffortHash(into: &hasher2)
        XCTAssertEqual(hasher.finalize(), hasher2.finalize())
        XCTAssertTrue(config.bestEffortEquals(theSameConfig))
    }
    
    func testDifferentHashValues() {
        var config = TLSConfiguration.makeServerConfiguration(certificateChain: [], privateKey: .file("fake.file"))
        config.applicationProtocols = ["http/1.1"]
        var differentConfig = config
        differentConfig.privateKey = .file("fake2.file")
        XCTAssertFalse(config.bestEffortEquals(differentConfig))
    }
    
    func testDifferentKeylogCallbacksNotEqual() {
        var config = TLSConfiguration.makeServerConfiguration(certificateChain: [], privateKey: .file("fake.file"))
        config.applicationProtocols = ["http/1.1"]
        config.keyLogCallback = { _ in }
        var differentConfig = config
        differentConfig.keyLogCallback = { _ in }
        XCTAssertFalse(config.bestEffortEquals(differentConfig))
    }
    
    func testDifferentSniCallbacksNotEqual() {
        var config = TLSConfiguration.makeServerConfiguration(certificateChain: [], privateKey: .file("fake.file"))
        config.applicationProtocols = ["http/1.1"]
        config.sniCallback = { (hostname : String, ctx: NIOSSLContext) -> NIOSSLContext? in
            return ctx
        }
        var differentConfig = config
        differentConfig.sniCallback = { (hostname : String, ctx: NIOSSLContext) -> NIOSSLContext? in
            return ctx
        }
        XCTAssertFalse(config.bestEffortEquals(differentConfig))
    }
    
    func testCompatibleCipherSuite() throws {
        // ECDHE_RSA is used here because the public key in .cert1 is derived from a RSA private key.
        // These could also be RSA based, but cannot be ECDHE_ECDSA.
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.cipherSuiteValues = [.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256]
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        clientConfig.renegotiationSupport = .none
        
        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.cipherSuiteValues = [.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256]
        serverConfig.maximumTLSVersion = .tlsv12
        serverConfig.certificateVerification = .none
        try assertHandshakeSucceeded(withClientConfig: clientConfig, andServerConfig: serverConfig)
    }
    
    func testNonCompatibleCipherSuite() throws {
        // This test fails more importantly because ECDHE_ECDSA is being set with a public key that is RSA based.
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.cipherSuiteValues = [.TLS_RSA_WITH_AES_128_GCM_SHA256]
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        clientConfig.renegotiationSupport = .none

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.cipherSuiteValues = [.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256]
        serverConfig.maximumTLSVersion = .tlsv12
        serverConfig.certificateVerification = .none
        try assertHandshakeError(withClientConfig: clientConfig, andServerConfig: serverConfig, errorTextContains: "ALERT_HANDSHAKE_FAILURE")
    }
    
    func testDefaultWithRSACipherSuite() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.cipherSuiteValues = [.TLS_RSA_WITH_AES_128_GCM_SHA256]
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        clientConfig.renegotiationSupport = .none

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.cipherSuites = defaultCipherSuites
        serverConfig.maximumTLSVersion = .tlsv12
        serverConfig.certificateVerification = .none
        try assertHandshakeSucceeded(withClientConfig: clientConfig, andServerConfig: serverConfig)
    }
    
    func testDefaultWithECDHERSACipherSuite() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.cipherSuiteValues = [.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384]
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        clientConfig.renegotiationSupport = .none

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.cipherSuites = defaultCipherSuites
        serverConfig.maximumTLSVersion = .tlsv12
        serverConfig.certificateVerification = .none

        try assertHandshakeSucceeded(withClientConfig: clientConfig, andServerConfig: serverConfig)
    }
    
    func testStringBasedCipherSuite() throws {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.cipherSuites = "AES256"
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.cipherSuites = "AES256"
        serverConfig.maximumTLSVersion = .tlsv12

        try assertHandshakeSucceeded(withClientConfig: clientConfig, andServerConfig: serverConfig)
    }
    
    func testMultipleCompatibleCipherSuites() throws {
        // This test is for multiple ECDHE_RSA based ciphers on the server side.
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.cipherSuiteValues = [.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256]
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        clientConfig.renegotiationSupport = .none

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.cipherSuiteValues = [
            .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
            .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
            .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
        ]
        serverConfig.maximumTLSVersion = .tlsv12
        serverConfig.certificateVerification = .none

        try assertHandshakeSucceeded(withClientConfig: clientConfig, andServerConfig: serverConfig)
    }
    
    func testMultipleCompatibleCipherSuitesWithStringBasedCipher() throws {
        // This test is for using multiple server side ciphers with the client side string based cipher.
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.cipherSuites = "AES256"
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.cipherSuiteValues = [
            .TLS_RSA_WITH_AES_128_CBC_SHA,
            .TLS_RSA_WITH_AES_256_CBC_SHA,
            .TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA,
            .TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA
        ]
        serverConfig.maximumTLSVersion = .tlsv12
        serverConfig.certificateVerification = .none

        try assertHandshakeSucceeded(withClientConfig: clientConfig, andServerConfig: serverConfig)
    }
    
    func testMultipleClientCipherSuitesWithDefaultCipher() throws {
        // Client ciphers should match one of the default ciphers.
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.cipherSuiteValues = [
            .TLS_RSA_WITH_AES_128_CBC_SHA,
            .TLS_RSA_WITH_AES_256_CBC_SHA,
            .TLS_RSA_WITH_AES_128_GCM_SHA256,
            .TLS_RSA_WITH_AES_256_GCM_SHA384,
            .TLS_AES_128_GCM_SHA256,
            .TLS_AES_256_GCM_SHA384,
            .TLS_CHACHA20_POLY1305_SHA256,
            .TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA,
            .TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,
            .TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
            .TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
            .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
        ]
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        clientConfig.renegotiationSupport = .none

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.cipherSuites = defaultCipherSuites
        serverConfig.maximumTLSVersion = .tlsv12
        serverConfig.certificateVerification = .none

        try assertHandshakeSucceeded(withClientConfig: clientConfig, andServerConfig: serverConfig)
    }
    
    func testNonCompatibleClientCiphersWithServerStringBasedCiphers() throws {
        // This test should fail on client hello negotiation.
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.cipherSuiteValues = [
            .TLS_AES_128_GCM_SHA256,
            .TLS_AES_256_GCM_SHA384,
            .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
        ]
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        clientConfig.renegotiationSupport = .none

        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TLSConfigurationTest.cert1)],
            privateKey: .privateKey(TLSConfigurationTest.key1)
        )
        serverConfig.cipherSuites = "AES256"
        serverConfig.maximumTLSVersion = .tlsv12
        
        try assertHandshakeError(withClientConfig: clientConfig, andServerConfig: serverConfig, errorTextContains: "ALERT_HANDSHAKE_FAILURE")
    }
    
    func testSettingCiphersWithCipherSuiteValues() {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.cipherSuiteValues = [
            .TLS_AES_128_GCM_SHA256,
            .TLS_AES_256_GCM_SHA384,
            .TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
        ]
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        clientConfig.renegotiationSupport = .none

        XCTAssertEqual(clientConfig.cipherSuites, "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256")
    }
    
    func testSettingCiphersWithCipherSuitesString() {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.cipherSuites = "AES256"
        clientConfig.maximumTLSVersion = .tlsv12
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([TLSConfigurationTest.cert1])
        
        let assignedCiphers = clientConfig.cipherSuiteValues.map { $0.standardName }
        let createdCipherSuiteValuesFromString = assignedCiphers.joined(separator: ":")
        // Note that this includes the PSK values as well.
        XCTAssertEqual(createdCipherSuiteValuesFromString, "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA:TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA:TLS_ECDHE_PSK_WITH_AES_256_CBC_SHA:TLS_RSA_WITH_AES_256_GCM_SHA384:TLS_RSA_WITH_AES_256_CBC_SHA:TLS_PSK_WITH_AES_256_CBC_SHA")
    }
    
    func testDefaultCipherSuiteValues() {
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.certificateVerification = .noHostnameVerification
        clientConfig.trustRoots = .certificates([])
        clientConfig.renegotiationSupport = .none
        clientConfig.additionalTrustRoots = [.certificates([TLSConfigurationTest.cert1])]
        XCTAssertEqual(clientConfig.cipherSuites, defaultCipherSuites)
        
        let assignedCiphers = clientConfig.cipherSuiteValues.map { $0.standardName }
        let defaultCipherSuiteValuesFromString = assignedCiphers.joined(separator: ":")
        // Note that this includes the PSK values as well.
        XCTAssertEqual(defaultCipherSuiteValuesFromString, "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA:TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA:TLS_ECDHE_PSK_WITH_AES_256_CBC_SHA:TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA:TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA:TLS_ECDHE_PSK_WITH_AES_128_CBC_SHA:TLS_RSA_WITH_AES_128_GCM_SHA256:TLS_RSA_WITH_AES_256_GCM_SHA384:TLS_RSA_WITH_AES_128_CBC_SHA:TLS_RSA_WITH_AES_256_CBC_SHA")
    }

    func testBestEffortEquatableHashableDifferences() {
        let first = TLSConfiguration.makeClientConfiguration()

        let transforms: [(inout TLSConfiguration) -> Void] = [
            { $0.minimumTLSVersion = .tlsv13 },
            { $0.maximumTLSVersion = .tlsv12 },
            { $0.cipherSuites = "AES" },
            { $0.cipherSuiteValues = [.TLS_RSA_WITH_AES_256_CBC_SHA] },
            { $0.verifySignatureAlgorithms = [.ed25519] },
            { $0.signingSignatureAlgorithms = [.ed25519] },
            { $0.certificateVerification = .noHostnameVerification },
            { $0.trustRoots = .certificates([TLSConfigurationTest.cert1]) },
            { $0.additionalTrustRoots = [.certificates([TLSConfigurationTest.cert1])] },
            { $0.certificateChain = [.certificate(TLSConfigurationTest.cert1)] },
            { $0.privateKey = .privateKey(TLSConfigurationTest.key1) },
            { $0.applicationProtocols = ["h2"] },
            { $0.shutdownTimeout = .seconds((60 * 24 * 24) + 1) },
            { $0.keyLogCallback = { _ in } },
            { $0.sniCallback = { (hostname : String, ctx: NIOSSLContext) -> NIOSSLContext? in
                return ctx
            }},
            { $0.renegotiationSupport = .always },
        ]

        for (index, transform) in transforms.enumerated() {
            var transformed = first
            transform(&transformed)
            XCTAssertNotEqual(Wrapper(config: first), Wrapper(config: transformed), "Should have compared not equal in index \(index)")
            XCTAssertEqual(Set([Wrapper(config: first), Wrapper(config: transformed)]).count, 2, "Should have hashed non-equal in index \(index)")
        }
    }
}

struct Wrapper: Hashable {
    var config: TLSConfiguration

    static func ==(lhs: Wrapper, rhs: Wrapper) -> Bool {
        return lhs.config.bestEffortEquals(rhs.config)
    }

    func hash(into hasher: inout Hasher) {
        self.config.bestEffortHash(into: &hasher)
    }
}
