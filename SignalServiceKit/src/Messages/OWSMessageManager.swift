//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import LibSignalClient

/// An ObjC wrapper around UnidentifiedSenderMessageContent.ContentHint
@objc
public enum SealedSenderContentHint: Int, CustomStringConvertible {
    /// Indicates that the content of a message is user-visible and will not be resent.
    /// Insert a placeholder: No
    /// Show error to user: Yes, immediately
    /// Send DecryptionErrorMessage: Yes (to request a session reset)
    case `default` = 0
    /// Indicates that the content of a message is user-visible and likely to be resent.
    /// Insert a placeholder: Yes
    /// Show error to user: Yes, after some deferral period
    /// Send DecryptionErrorMessage: Yes (for resend if possible, session reset otherwise)
    case resendable
    /// Indicates that the content of a message is not user-visible and will not be resent.
    /// Insert a placeholder: No
    /// Show error to user: No
    /// Send DecryptionErrorMessage: Yes (to request session reset)
    case implicit

    init(_ signalClientHint: UnidentifiedSenderMessageContent.ContentHint) {
        switch signalClientHint {
        case .default: self = .default
        case .resendable: self = .resendable
        case .implicit: self = .implicit
        default:
            owsFailDebug("Unspecified case \(signalClientHint)")
            self = .default
        }
    }

    public var signalClientHint: UnidentifiedSenderMessageContent.ContentHint {
        switch self {
        case .default: return .default
        case .resendable: return .resendable
        case .implicit: return .implicit
        }
    }

    public var description: String {
        switch self {
        case .default: return "default"
        case .resendable: return "resendable"
        case .implicit: return "implicit"
        }
    }
}

// MARK: -

extension OWSMessageManager {

    private static let pendingTasks = PendingTasks(label: "messageManager")

    public static func pendingTasksPromise() -> Promise<Void> {
        // This promise blocks on all pending tasks already in flight,
        // but will not block on new tasks enqueued after this promise
        // is created. That's intentional to ensure that NotificationService
        // instances complete in a timely way.
        pendingTasks.pendingTasksPromise()
    }

    @objc
    public static func buildPendingTask(label: String) -> PendingTask {
        Self.pendingTasks.buildPendingTask(label: label)
    }

    @objc
    public func updateApplicationBadgeCount() {
        let readUnreadCount: (SDSAnyReadTransaction) -> UInt = { transaction in
            InteractionFinder.unreadCountInAllThreads(transaction: transaction.unwrapGrdbRead)
        }

        let fetchBadgeCount = { () -> Promise<UInt> in
            // The main app gets to perform this synchronously
            if CurrentAppContext().isMainApp {
                return .value(self.databaseStorage.read(block: readUnreadCount))
            } else {
                return self.databaseStorage.read(.promise, readUnreadCount)
            }
        }

        fetchBadgeCount().done {
            CurrentAppContext().setMainAppBadgeNumber(Int($0))
        }.catch { error in
            owsFailDebug("Failed to update badge number: \(error)")
        }
    }

    @objc
    func isValidEnvelope(_ envelope: SSKProtoEnvelope) -> Bool {
        guard envelope.timestamp >= 1 else {
            owsFailDebug("Invalid timestamp")
            return false
        }
        guard SDS.fitsInInt64(envelope.timestamp) else {
            owsFailDebug("Invalid timestamp")
            return false
        }
        guard envelope.hasValidSource else {
            owsFailDebug("Invalid source")
            return false
        }
        guard envelope.sourceDevice >= 1 else {
            owsFailDebug("Invalid source device")
            return false
        }
        return true
    }

    /// Performs a limited amount of time sensitive processing before scheduling the remainder of message processing
    ///
    /// Currently, the preprocess step only parses sender key distribution messages to update the sender key store. It's important
    /// the sender key store is updated *before* the write transaction completes since we don't know if the next message to be
    /// decrypted will depend on the sender key store being up to date.
    ///
    /// Some other things worth noting:
    /// - We should preprocess *all* envelopes, even those where the sender is blocked. This is important because it protects us
    /// from a case where the recipeint blocks and then unblocks a user. If the sender they blocked sent an SKDM while the user was
    /// blocked, their understanding of the world is that we have saved the SKDM. After unblock, if we don't have the SKDM we'll fail
    /// to decrypt.
    /// - This *needs* to happen in the very same write transaction where the message was decrypted. It's important to keep in mind
    /// that the NSE could race with the main app when processing messages. The write transaction is used to protect us from any races.
    func preprocessEnvelope(envelope: SSKProtoEnvelope, plaintext: Data?, transaction: SDSAnyWriteTransaction) {
        guard CurrentAppContext().shouldProcessIncomingMessages else {
            owsFail("Should not process messages")
        }
        guard self.tsAccountManager.isRegistered else {
            owsFailDebug("Not registered")
            return
        }
        guard isValidEnvelope(envelope) else {
            owsFailDebug("Invalid envelope")
            return
        }
        guard let plaintext = plaintext else {
            Logger.warn("No plaintext")
            return
        }

        // Currently, this function is only used for SKDM processing
        // Since this is idempotent, we don't need to check for a duplicate envelope.
        //
        // SKDM proecessing is also not user-visible, so we don't want to skip if the sender is
        // blocked. This ensures that we retain session info to decrypt future messages from a blocked
        // sender if they're ever unblocked.
        let contentProto: SSKProtoContent
        do {
            contentProto = try SSKProtoContent(serializedData: plaintext)
        } catch {
            owsFailDebug("Failed to deserialize content proto: \(error)")
            return
        }

        if let skdmBytes = contentProto.senderKeyDistributionMessage {
            Logger.info("Preprocessing content: \(description(for: contentProto))")
            handleIncomingEnvelope(envelope, withSenderKeyDistributionMessage: skdmBytes, transaction: transaction)
        }
    }

    @objc
    func handleIncomingEnvelope(
        _ envelope: SSKProtoEnvelope,
        withSenderKeyDistributionMessage skdmData: Data,
        transaction writeTx: SDSAnyWriteTransaction) {

        guard let sourceAddress = envelope.sourceAddress, sourceAddress.isValid else {
            return owsFailDebug("Invalid source address")
        }

        do {
            let skdm = try SenderKeyDistributionMessage(bytes: skdmData.map { $0 })
            let sourceDeviceId = envelope.sourceDevice
            let protocolAddress = try ProtocolAddress(from: sourceAddress, deviceId: sourceDeviceId)
            try processSenderKeyDistributionMessage(skdm, from: protocolAddress, store: senderKeyStore, context: writeTx)

            Logger.info("Processed incoming sender key distribution message. Sender: \(sourceAddress).\(sourceDeviceId)")

        } catch {
            owsFailDebug("Failed to process incoming sender key \(error)")
        }
    }

    @objc
    func handleIncomingEnvelope(
        _ envelope: SSKProtoEnvelope,
        withDecryptionErrorMessage bytes: Data,
        transaction writeTx: SDSAnyWriteTransaction
    ) {
        guard let sourceAddress = envelope.sourceAddress, sourceAddress.isValid else {
            return owsFailDebug("Invalid source address")
        }
        let sourceDeviceId = envelope.sourceDevice

        do {
            let errorMessage = try DecryptionErrorMessage(bytes: bytes)
            guard errorMessage.deviceId == tsAccountManager.storedDeviceId() else {
                Logger.info("Received a DecryptionError message targeting a linked device. Ignoring.")
                return
            }
            let protocolAddress = try ProtocolAddress(from: sourceAddress, deviceId: sourceDeviceId)

            let didPerformSessionReset: Bool

            if let ratchetKey = errorMessage.ratchetKey {
                // If a ratchet key is included, this was a 1:1 session message
                // Archive the session if the current key matches.
                // PNI TODO: We should never get a DEM for our PNI, but we should check that anyway.
                let sessionStore = signalProtocolStore(for: .aci).sessionStore
                let sessionRecord = try sessionStore.loadSession(for: protocolAddress, context: writeTx)
                if try sessionRecord?.currentRatchetKeyMatches(ratchetKey) == true {
                    Logger.info("Decryption error included ratchet key. Archiving...")
                    sessionStore.archiveSession(for: sourceAddress,
                                                deviceId: Int32(sourceDeviceId),
                                                transaction: writeTx)
                    didPerformSessionReset = true
                } else {
                    Logger.info("Ratchet key mismatch. Leaving session as-is.")
                    didPerformSessionReset = false
                }
            } else {
                // If we don't have a ratchet key, this was a sender key session message.
                // Let's log any info about SKDMs that we had sent to the address requesting resend
                senderKeyStore.logSKDMInfo(for: sourceAddress, transaction: writeTx)
                didPerformSessionReset = false
            }

            Logger.warn("Performing message resend of timestamp \(errorMessage.timestamp)")
            let resendResponse = OWSOutgoingResendResponse(
                address: sourceAddress,
                deviceId: Int64(sourceDeviceId),
                failedTimestamp: Int64(errorMessage.timestamp),
                didResetSession: didPerformSessionReset,
                transaction: writeTx
            )

            let sendBlock = { (transaction: SDSAnyWriteTransaction) in
                if let resendResponse = resendResponse {
                    Self.messageSenderJobQueue.add(message: resendResponse.asPreparer, transaction: transaction)
                }
            }

            if DebugFlags.delayedMessageResend.get() {
                DispatchQueue.sharedUtility.asyncAfter(deadline: .now() + 10) {
                    Self.databaseStorage.asyncWrite { writeTx in
                        sendBlock(writeTx)
                    }
                }
            } else {
                sendBlock(writeTx)
            }

        } catch {
            owsFailDebug("Failed to process decryption error message \(error)")
        }
    }

    @objc
    public static func descriptionForDataMessageContents(_ dataMessage: SSKProtoDataMessage) -> String {
        var splits = [String]()
        if !dataMessage.attachments.isEmpty {
            splits.append("attachments: \(dataMessage.attachments.count)")
        }
        if dataMessage.group != nil {
            splits.append("groupV1")
        }
        if dataMessage.groupV2 != nil {
            splits.append("groupV2")
        }
        if dataMessage.quote != nil {
            splits.append("quote")
        }
        if !dataMessage.contact.isEmpty {
            splits.append("contacts: \(dataMessage.contact.count)")
        }
        if !dataMessage.preview.isEmpty {
            splits.append("previews: \(dataMessage.preview.count)")
        }
        if dataMessage.sticker != nil {
            splits.append("sticker")
        }
        if dataMessage.reaction != nil {
            splits.append("reaction")
        }
        if dataMessage.delete != nil {
            splits.append("delete")
        }
        if !dataMessage.bodyRanges.isEmpty {
            splits.append("bodyRanges: \(dataMessage.bodyRanges.count)")
        }
        if dataMessage.groupCallUpdate != nil {
            splits.append("groupCallUpdate")
        }
        if dataMessage.payment != nil {
            splits.append("payment")
        }
        if dataMessage.body?.nilIfEmpty != nil {
            splits.append("body")
        }
        if dataMessage.expireTimer > 0 {
            splits.append("expireTimer")
        }
        if dataMessage.profileKey != nil {
            splits.append("profileKey")
        }
        if dataMessage.isViewOnce {
            splits.append("isViewOnce")
        }
        if dataMessage.flags > 0 {
            splits.append("flags: \(dataMessage.flags)")
        }
        return "[" + splits.joined(separator: ", ") + "]"
    }
}
