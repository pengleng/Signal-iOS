//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import SignalServiceKit

#if DEBUG

@objc
public extension DebugUIMessages {
    static func anyIncomingSenderAddress(forThread thread: TSThread) -> SignalServiceAddress? {
        if let contactThread = thread as? TSContactThread {
            return contactThread.contactAddress
        } else if let groupThread = thread as? TSGroupThread {
            guard let localAddress = Self.tsAccountManager.localAddress else {
                owsFailDebug("Missing localAddress.")
                return nil
            }
            let members = groupThread.groupMembership.fullMembers
            let otherMembers = members.filter { $0 != localAddress }.shuffled()
            guard let anyOtherMember = otherMembers.first else {
                owsFailDebug("No other members.")
                return nil
            }
            return anyOtherMember
        } else {
            owsFailDebug("Invalid thread.")
            return nil
        }
    }

    static func processDecryptedEnvelope(_ envelope: SSKProtoEnvelope,
                                         plaintextData: Data) {
        messageProcessor.processDecryptedEnvelope(envelope,
                                                  plaintextData: plaintextData,
                                                  serverDeliveryTimestamp: 0,
                                                  wasReceivedByUD: false) { error in
            switch error {
            case MessageProcessingError.duplicatePendingEnvelope?:
                Logger.warn("duplicatePendingEnvelope.")
            case let otherError?:
                owsFailDebug("Error: \(otherError)")
            case nil:
                break
            }
        }
    }
}

#endif
