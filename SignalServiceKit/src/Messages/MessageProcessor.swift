//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import Foundation
import GRDB
import SignalCoreKit

@objc
public class MessageProcessor: NSObject {
    @objc
    public static let messageProcessorDidFlushQueue = Notification.Name("messageProcessorDidFlushQueue")

    @objc
    public var hasPendingEnvelopes: Bool {
        !pendingEnvelopes.isEmpty
    }

    @objc
    @available(swift, obsoleted: 1.0)
    public func processingCompletePromise() -> AnyPromise {
        return AnyPromise(processingCompletePromise())
    }

    public func processingCompletePromise() -> Promise<Void> {
        guard CurrentAppContext().shouldProcessIncomingMessages else {
            if DebugFlags.isMessageProcessingVerbose {
                Logger.verbose("!shouldProcessIncomingMessages")
            }
            return Promise.value(())
        }

        if self.hasPendingEnvelopes {
            if DebugFlags.internalLogging {
                Logger.info("hasPendingEnvelopes, queuedContentCount: \(self.queuedContentCount)")
            }
            return NotificationCenter.default.observe(
                once: Self.messageProcessorDidFlushQueue
            ).then { _ in self.processingCompletePromise() }.asVoid()
        } else if databaseStorage.read(
            block: { Self.groupsV2MessageProcessor.hasPendingJobs(transaction: $0) }
        ) {
            if DebugFlags.internalLogging {
                let pendingJobCount = databaseStorage.read {
                    Self.groupsV2MessageProcessor.pendingJobCount(transaction: $0)
                }
                Logger.verbose("groupsV2MessageProcessor.hasPendingJobs, pendingJobCount: \(pendingJobCount)")
            }
            return NotificationCenter.default.observe(
                once: GroupsV2MessageProcessor.didFlushGroupsV2MessageQueue
            ).then { _ in self.processingCompletePromise() }.asVoid()
        } else {
            if DebugFlags.isMessageProcessingVerbose {
                Logger.verbose("!hasPendingEnvelopes && !hasPendingJobs")
            }
            return Promise.value(())
        }
    }

    @objc
    @available(swift, obsoleted: 1.0)
    public func fetchingAndProcessingCompletePromise() -> AnyPromise {
        return AnyPromise(fetchingAndProcessingCompletePromise())
    }

    public func fetchingAndProcessingCompletePromise() -> Promise<Void> {
        return firstly { () -> Promise<Void> in
            Self.messageFetcherJob.fetchingCompletePromise()
        }.then { () -> Promise<Void> in
            self.processingCompletePromise()
        }
    }

    public override init() {
        super.init()

        SwiftSingletons.register(self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registrationStateDidChange),
            name: .registrationStateDidChange,
            object: nil
        )

        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            Self.messagePipelineSupervisor.register(pipelineStage: self)

            SDSDatabaseStorage.shared.read { transaction in
                // We may have legacy process jobs queued. We want to schedule them for
                // processing immediately when we launch, so that we can drain the old queue.
                let legacyProcessingJobRecords = AnyMessageContentJobFinder().allJobs(transaction: transaction)
                for jobRecord in legacyProcessingJobRecords {
                    let completion: (Error?) -> Void = { _ in
                        SDSDatabaseStorage.shared.write { jobRecord.anyRemove(transaction: $0) }
                    }
                    do {
                        let envelope = try SSKProtoEnvelope(serializedData: jobRecord.envelopeData)
                        self.processDecryptedEnvelope(envelope,
                                                      plaintextData: jobRecord.plaintextData,
                                                      serverDeliveryTimestamp: jobRecord.serverDeliveryTimestamp,
                                                      wasReceivedByUD: jobRecord.wasReceivedByUD,
                                                      completion: completion)
                    } catch {
                        completion(error)
                    }
                }

                // We may have legacy decrypt jobs queued. We want to schedule them for
                // processing immediately when we launch, so that we can drain the old queue.
                let legacyDecryptJobRecords = AnyJobRecordFinder<SSKMessageDecryptJobRecord>().allRecords(
                    label: "SSKMessageDecrypt",
                    status: .ready,
                    transaction: transaction
                )
                for jobRecord in legacyDecryptJobRecords {
                    guard let envelopeData = jobRecord.envelopeData else {
                        owsFailDebug("Skipping job with no envelope data")
                        continue
                    }
                    self.processEncryptedEnvelopeData(envelopeData,
                                                      serverDeliveryTimestamp: jobRecord.serverDeliveryTimestamp,
                                                      envelopeSource: .unknown) { _ in
                        SDSDatabaseStorage.shared.write { jobRecord.anyRemove(transaction: $0) }
                    }
                }
            }
        }
    }

    public func processEncryptedEnvelopeData(
        _ encryptedEnvelopeData: Data,
        serverDeliveryTimestamp: UInt64,
        envelopeSource: EnvelopeSource,
        completion: @escaping (Error?) -> Void
    ) {
        guard !encryptedEnvelopeData.isEmpty else {
            completion(OWSAssertionError("Empty envelope, envelopeSource: \(envelopeSource)."))
            return
        }

        // Drop any too-large messages on the floor. Well behaving clients should never send them.
        guard encryptedEnvelopeData.count <= Self.maxEnvelopeByteCount else {
            completion(OWSAssertionError("Oversize envelope, envelopeSource: \(envelopeSource)."))
            return
        }

        // Take note of any messages larger than we expect, but still process them.
        // This likely indicates a misbehaving sending client.
        if encryptedEnvelopeData.count > Self.largeEnvelopeWarningByteCount {
            Logger.verbose("encryptedEnvelopeData: \(encryptedEnvelopeData.count) > : \(Self.largeEnvelopeWarningByteCount)")
            owsFailDebug("Unexpectedly large envelope, envelopeSource: \(envelopeSource).")
        }

        let encryptedEnvelopeProto: SSKProtoEnvelope
        do {
            encryptedEnvelopeProto = try SSKProtoEnvelope(serializedData: encryptedEnvelopeData)
        } catch {
            owsFailDebug("Failed to parse encrypted envelope \(error), envelopeSource: \(envelopeSource)")
            completion(error)
            return
        }

        processEncryptedEnvelope(EncryptedEnvelope(encryptedEnvelopeData: encryptedEnvelopeData,
                                                   encryptedEnvelope: encryptedEnvelopeProto,
                                                   serverDeliveryTimestamp: serverDeliveryTimestamp,
                                                   completion: completion),
                                 envelopeSource: envelopeSource)
    }

    public func processEncryptedEnvelope(
        _ encryptedEnvelopeProto: SSKProtoEnvelope,
        serverDeliveryTimestamp: UInt64,
        envelopeSource: EnvelopeSource,
        completion: @escaping (Error?) -> Void
    ) {
        processEncryptedEnvelope(EncryptedEnvelope(encryptedEnvelopeData: nil,
                                                   encryptedEnvelope: encryptedEnvelopeProto,
                                                   serverDeliveryTimestamp: serverDeliveryTimestamp,
                                                   completion: completion),
                                 envelopeSource: envelopeSource)
    }

    private func processEncryptedEnvelope(_ encryptedEnvelope: EncryptedEnvelope, envelopeSource: EnvelopeSource) {
        let result = pendingEnvelopes.enqueue(encryptedEnvelope: encryptedEnvelope)
        switch result {
        case .duplicate:
            Logger.warn("Duplicate envelope \(encryptedEnvelope.encryptedEnvelope.timestamp). Server timestamp: \(encryptedEnvelope.serverTimestamp), serverGuid: \(encryptedEnvelope.serverGuidFormatted), EnvelopeSource: \(envelopeSource).")
            encryptedEnvelope.completion(MessageProcessingError.duplicatePendingEnvelope)
        case .enqueued:
            drainPendingEnvelopes()
        }
    }

    public func processDecryptedEnvelope(
        _ envelope: SSKProtoEnvelope,
        plaintextData: Data?,
        serverDeliveryTimestamp: UInt64,
        wasReceivedByUD: Bool,
        completion: @escaping (Error?) -> Void
    ) {
        let decryptedEnvelope = DecryptedEnvelope(
            envelope: envelope,
            envelopeData: nil,
            plaintextData: plaintextData,
            serverDeliveryTimestamp: serverDeliveryTimestamp,
            wasReceivedByUD: wasReceivedByUD,
            completion: completion
        )
        pendingEnvelopes.enqueue(decryptedEnvelope: decryptedEnvelope)
        drainPendingEnvelopes()
    }

    public var queuedContentCount: Int {
        pendingEnvelopes.count
    }

    private static let maxEnvelopeByteCount = 250 * 1024
    public static let largeEnvelopeWarningByteCount = 25 * 1024
    private let serialQueue = DispatchQueue(label: "MessageProcessor.processingQueue",
                                            autoreleaseFrequency: .workItem)

    private var pendingEnvelopes = PendingEnvelopes()
    private var isDrainingPendingEnvelopes = false {
        didSet { assertOnQueue(serialQueue) }
    }

    private func drainPendingEnvelopes() {
        guard Self.messagePipelineSupervisor.isMessageProcessingPermitted else { return }
        guard TSAccountManager.shared.isRegisteredAndReady else { return }

        guard CurrentAppContext().shouldProcessIncomingMessages else { return }

        serialQueue.async {
            guard !self.isDrainingPendingEnvelopes else { return }
            self.isDrainingPendingEnvelopes = true
            while self.drainNextBatch() {}
            self.isDrainingPendingEnvelopes = false
            if self.pendingEnvelopes.isEmpty {
                NotificationCenter.default.postNotificationNameAsync(Self.messageProcessorDidFlushQueue, object: nil)
            }
        }
    }

    /// Returns whether or not to continue draining the queue.
    private func drainNextBatch() -> Bool {
        assertOnQueue(serialQueue)
        owsAssertDebug(isDrainingPendingEnvelopes)

        return autoreleasepool {
            // We want a value that is just high enough to yield perf benefits.
            let kIncomingMessageBatchSize = 16
            // If the app is in the background, use batch size of 1.
            // This reduces the risk of us never being able to drain any
            // messages from the queue. We should fine tune this number
            // to yield the best perf we can get.
            let batchSize = CurrentAppContext().isInBackground() ? 1 : kIncomingMessageBatchSize
            let batch = pendingEnvelopes.nextBatch(batchSize: batchSize)
            let batchEnvelopes = batch.batchEnvelopes
            let pendingEnvelopesCount = batch.pendingEnvelopesCount

            guard !batchEnvelopes.isEmpty, messagePipelineSupervisor.isMessageProcessingPermitted else {
                if DebugFlags.internalLogging {
                    Logger.info("Processing complete: \(self.queuedContentCount) (memoryUsage: \(LocalDevice.memoryUsageString).")
                }
                return false
            }

            let startTime = CACurrentMediaTime()
            Logger.info("Processing batch of \(batchEnvelopes.count)/\(pendingEnvelopesCount) received envelope(s). (memoryUsage: \(LocalDevice.memoryUsageString)")

            var processedEnvelopes: [PendingEnvelope] = []
            SDSDatabaseStorage.shared.write { transaction in
                for envelope in batchEnvelopes {
                    if messagePipelineSupervisor.isMessageProcessingPermitted {
                        self.processEnvelope(envelope, transaction: transaction)
                        processedEnvelopes.append(envelope)
                    } else {
                        // If we're skipping one message, we have to skip them all to preserve ordering
                        // Next time around we can process the skipped messages in order
                        break
                    }
                }
            }
            pendingEnvelopes.removeProcessedEnvelopes(processedEnvelopes)
            let duration = CACurrentMediaTime() - startTime
            Logger.info(String.init(format: "Processed %.0d envelopes in %0.2fms -> %.2f envelopes per second", batchEnvelopes.count, duration * 1000, duration > 0 ? Double(batchEnvelopes.count) / duration : 0))
            return true
        }
    }

    private func processEnvelope(_ pendingEnvelope: PendingEnvelope, transaction: SDSAnyWriteTransaction) {
        assertOnQueue(serialQueue)

        switch pendingEnvelope.decrypt(transaction: transaction) {
        case .success(let result):
            // NOTE: We use the envelope from the decrypt result, not the pending envelope,
            // since the envelope may be altered by the decryption process in the UD case.
            guard let sourceAddress = result.envelope.sourceAddress, sourceAddress.isValid else {
                owsFailDebug("Successful decryption with no source address; discarding message")
                transaction.addAsyncCompletionOffMain {
                    pendingEnvelope.completion(OWSAssertionError("successful decryption with no source address"))
                }
                return
            }

            // Pre-processing happens during the same transaction that performed decryption
            messageManager.preprocessEnvelope(envelope: result.envelope,
                                              plaintext: result.plaintextData,
                                              transaction: transaction)

            // If the sender is in the block list, we can skip scheduling any additional processing.
            if blockingManager.isAddressBlocked(sourceAddress, transaction: transaction) {
                Logger.info("Skipping processing for blocked envelope: \(sourceAddress)")

                let error = MessageProcessingError.blockedSender
                transaction.addAsyncCompletionOffMain {
                    pendingEnvelope.completion(error)
                }
                return
            }

            enum ProcessingStep {
                case discard
                case enqueueForGroupProcessing
                case processNow(shouldDiscardVisibleMessages: Bool)
            }
            let processingStep = { () -> ProcessingStep in
                guard let plaintextData = result.plaintextData,
                      let groupContextV2 =
                        GroupsV2MessageProcessor.groupContextV2(fromPlaintextData: plaintextData) else {
                    // Non-v2-group messages can be processed immediately.
                    return .processNow(shouldDiscardVisibleMessages: false)
                }

                guard GroupsV2MessageProcessor.canContextBeProcessedImmediately(
                    groupContext: groupContextV2,
                    transaction: transaction
                ) else {
                    // Some v2 group messages required group state to be
                    // updated before they can be processed.
                    return .enqueueForGroupProcessing
                }
                let discardMode = GroupsMessageProcessor.discardMode(forMessageFrom: sourceAddress,
                                                                     groupContext: groupContextV2,
                                                                     transaction: transaction)
                if discardMode == .discard {
                    // Some v2 group messages should be discarded and not processed.
                    Logger.verbose("Discarding job.")
                    return .discard
                }
                // Some v2 group messages should be processed, but
                // discarding any "visible" messages, e.g. text messages
                // or calls.
                return .processNow(shouldDiscardVisibleMessages: discardMode == .discardVisibleMessages)
            }()

            switch processingStep {
            case .discard:
                // Do nothing.
                Logger.verbose("Discarding job.")
            case .enqueueForGroupProcessing:
                // If we can't process the message immediately, we enqueue it for
                // for processing in the same transaction within which it was decrypted
                // to prevent data loss.
                let envelopeData: Data
                if let existingEnvelopeData = result.envelopeData {
                    envelopeData = existingEnvelopeData
                } else {
                    do {
                        envelopeData = try result.envelope.serializedData()
                    } catch {
                        owsFailDebug("failed to reserialize envelope: \(error)")
                        transaction.addAsyncCompletionOffMain {
                            pendingEnvelope.completion(error)
                        }
                        return
                    }
                }
                Self.groupsV2MessageProcessor.enqueue(
                    envelopeData: envelopeData,
                    // All GV2 messages have plaintext data (because that's where the group context lives)
                    plaintextData: result.plaintextData!,
                    wasReceivedByUD: result.wasReceivedByUD,
                    serverDeliveryTimestamp: result.serverDeliveryTimestamp,
                    transaction: transaction
                )
            case .processNow(let shouldDiscardVisibleMessages):
                // Envelopes can be processed immediately if they're:
                // 1. Not a GV2 message.
                // 2. A GV2 message that doesn't require updating the group.
                //
                // The advantage to processing the message immediately is that
                // we can full process the message in the same transaction that
                // we used to decrypt it. This results in a significant perf
                // benefit verse queueing the message and waiting for that queue
                // to open new transactions and process messages. The downside is
                // that if we *fail* to process this message (e.g. the app crashed
                // or was killed), we'll have to re-decrypt again before we process.
                // This is safe, since the decrypt operation would also be rolled
                // back (since the transaction didn't finalize) and should be rare.
                Self.messageManager.processEnvelope(
                    result.envelope,
                    plaintextData: result.plaintextData,
                    wasReceivedByUD: result.wasReceivedByUD,
                    serverDeliveryTimestamp: result.serverDeliveryTimestamp,
                    shouldDiscardVisibleMessages: shouldDiscardVisibleMessages,
                    transaction: transaction
                )
            }

            transaction.addAsyncCompletionOffMain {
                pendingEnvelope.completion(nil)
            }
        case .failure(let error):
            transaction.addAsyncCompletionOffMain {
                pendingEnvelope.completion(error)
            }
        }
    }

    @objc
    func registrationStateDidChange() {
        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            self.drainPendingEnvelopes()
        }
    }

    public enum MessageAckBehavior {
        case shouldAck
        case shouldNotAck(error: Error)
    }

    public static func handleMessageProcessingOutcome(error: Error?) -> MessageAckBehavior {
        guard let error = error else {
            // Success.
            return .shouldAck
        }
        if case MessageProcessingError.duplicatePendingEnvelope = error {
            // _DO NOT_ ACK if de-duplicated before decryption.
            return .shouldNotAck(error: error)
        } else if case MessageProcessingError.blockedSender = error {
            return .shouldAck
        } else if let owsError = error as? OWSError,
                  owsError.errorCode == OWSErrorCode.failedToDecryptDuplicateMessage.rawValue {
            // _DO_ ACK if de-duplicated during decryption.
            return .shouldAck
        } else {
            Logger.warn("Failed to process message: \(error)")
            // This should only happen for malformed envelopes. We may eventually
            // want to show an error in this case.
            return .shouldAck
        }
    }
}

// MARK: -

extension MessageProcessor: MessageProcessingPipelineStage {
    public func supervisorDidResumeMessageProcessing(_ supervisor: MessagePipelineSupervisor) {
        drainPendingEnvelopes()
    }
}

// MARK: -

private protocol PendingEnvelope {
    var completion: (Error?) -> Void { get }
    var wasReceivedByUD: Bool { get }
    func decrypt(transaction: SDSAnyWriteTransaction) -> Swift.Result<DecryptedEnvelope, Error>
    func isDuplicateOf(_ other: PendingEnvelope) -> Bool
}

// MARK: -

private struct EncryptedEnvelope: PendingEnvelope, Dependencies {
    let encryptedEnvelopeData: Data?
    let encryptedEnvelope: SSKProtoEnvelope
    let serverDeliveryTimestamp: UInt64
    let completion: (Error?) -> Void

    public var serverGuid: String? {
        encryptedEnvelope.serverGuid
    }
    public var serverGuidFormatted: String {
        String(describing: serverGuid)
    }
    public var serverTimestamp: UInt64 {
        encryptedEnvelope.serverTimestamp
    }

    var wasReceivedByUD: Bool {
        let hasSenderSource: Bool
        if encryptedEnvelope.hasValidSource {
            hasSenderSource = true
        } else {
            hasSenderSource = false
        }
        return encryptedEnvelope.type == .unidentifiedSender && !hasSenderSource
    }

    func decrypt(transaction: SDSAnyWriteTransaction) -> Swift.Result<DecryptedEnvelope, Error> {
        // PNI TODO: actually handle destinationUuid, don't just use it as a filter.
        if let destinationUuidString = encryptedEnvelope.destinationUuid,
           let localAci = self.tsAccountManager.localUuid,
           localAci != UUID(uuidString: destinationUuidString) {
            return .failure(MessageProcessingError.wrongDestinationUuid)
        }

        let result = Self.messageDecrypter.decryptEnvelope(
            encryptedEnvelope,
            envelopeData: encryptedEnvelopeData,
            transaction: transaction
        )
        switch result {
        case .success(let result):
            return .success(DecryptedEnvelope(
                envelope: result.envelope,
                envelopeData: result.envelopeData,
                plaintextData: result.plaintextData,
                serverDeliveryTimestamp: serverDeliveryTimestamp,
                wasReceivedByUD: wasReceivedByUD,
                completion: completion
            ))
        case .failure(let error):
            return .failure(error)
        }
    }

    func isDuplicateOf(_ other: PendingEnvelope) -> Bool {
        guard let other = other as? EncryptedEnvelope else {
            return false
        }
        guard let serverGuid = self.serverGuid else {
            owsFailDebug("Missing serverGuid.")
            return false
        }
        guard let otherServerGuid = other.serverGuid else {
            owsFailDebug("Missing other.serverGuid.")
            return false
        }
        return serverGuid == otherServerGuid
    }
}

// MARK: -

private struct DecryptedEnvelope: PendingEnvelope {
    let envelope: SSKProtoEnvelope
    let envelopeData: Data?
    let plaintextData: Data?
    let serverDeliveryTimestamp: UInt64
    let wasReceivedByUD: Bool
    let completion: (Error?) -> Void

    func decrypt(transaction: SDSAnyWriteTransaction) -> Swift.Result<DecryptedEnvelope, Error> {
        return .success(self)
    }

    func isDuplicateOf(_ other: PendingEnvelope) -> Bool {
        // This envelope is only used for legacy envelopes.
        // We don't need to de-duplicate.
        false
    }
}

// MARK: -

@objc
public enum EnvelopeSource: UInt, CustomStringConvertible {
    case unknown
    case websocketIdentified
    case websocketUnidentified
    case rest
    // We re-decrypt incoming messages after accepting a safety number change.
    case identityChangeError
    case debugUI
    case tests

    // MARK: - CustomStringConvertible

    public var description: String {
        switch self {
        case .unknown:
            return "unknown"
        case .websocketIdentified:
            return "websocketIdentified"
        case .websocketUnidentified:
            return "websocketUnidentified"
        case .rest:
            return "rest"
        case .identityChangeError:
            return "identityChangeError"
        case .debugUI:
            return "debugUI"
        case .tests:
            return "tests"
        }
    }
}

// MARK: -

public class PendingEnvelopes {
    private let unfairLock = UnfairLock()
    private var pendingEnvelopes = [PendingEnvelope]()

    @objc
    public var isEmpty: Bool {
        unfairLock.withLock { pendingEnvelopes.isEmpty }
    }

    public var count: Int {
        unfairLock.withLock { pendingEnvelopes.count }
    }

    fileprivate struct Batch {
        let batchEnvelopes: [PendingEnvelope]
        let pendingEnvelopesCount: Int
    }

    fileprivate func nextBatch(batchSize: Int) -> Batch {
        unfairLock.withLock {
            Batch(batchEnvelopes: Array(pendingEnvelopes.prefix(batchSize)),
                  pendingEnvelopesCount: pendingEnvelopes.count)
        }
    }

    fileprivate func removeProcessedEnvelopes(_ processedEnvelopes: [PendingEnvelope]) {
        unfairLock.withLock {
            guard pendingEnvelopes.count > processedEnvelopes.count else {
                pendingEnvelopes = []
                return
            }
            let oldCount = pendingEnvelopes.count
            pendingEnvelopes = Array(pendingEnvelopes.suffix(from: processedEnvelopes.count))
            let newCount = pendingEnvelopes.count
            if DebugFlags.internalLogging {
                Logger.info("\(oldCount) -> \(newCount)")
            }
        }
    }

    fileprivate func enqueue(decryptedEnvelope: DecryptedEnvelope) {
        unfairLock.withLock {
            let oldCount = pendingEnvelopes.count
            pendingEnvelopes.append(decryptedEnvelope)
            let newCount = pendingEnvelopes.count
            if DebugFlags.internalLogging {
                Logger.info("\(oldCount) -> \(newCount)")
            }
        }
    }

    public enum EnqueueResult {
        case duplicate
        case enqueued
    }

    fileprivate func enqueue(encryptedEnvelope: EncryptedEnvelope) -> EnqueueResult {
        unfairLock.withLock {
            let oldCount = pendingEnvelopes.count

            for pendingEnvelope in pendingEnvelopes {
                if pendingEnvelope.isDuplicateOf(encryptedEnvelope) {
                    return .duplicate
                }
            }
            pendingEnvelopes.append(encryptedEnvelope)

            let newCount = pendingEnvelopes.count
            if DebugFlags.internalLogging {
                Logger.info("\(oldCount) -> \(newCount)")
            }
            return .enqueued
        }
    }
}

// MARK: -

public enum MessageProcessingError: Error {
    case wrongDestinationUuid
    case invalidMessageTypeForDestinationUuid
    case duplicatePendingEnvelope
    case blockedSender
}
