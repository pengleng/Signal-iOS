//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc
public class StoryManager: NSObject {
    public static let storyLifetimeMillis = kDayInMs

    @objc
    public class func processIncomingStoryMessage(
        _ storyMessage: SSKProtoStoryMessage,
        timestamp: UInt64,
        author: SignalServiceAddress,
        transaction: SDSAnyWriteTransaction
    ) throws {
        // Drop all story messages until the feature is enabled.
        guard FeatureFlags.stories else { return }

        guard StoryFinder.story(
            timestamp: timestamp,
            author: author,
            transaction: transaction
        ) == nil else {
            owsFailDebug("Dropping story message with duplicate timestamp \(timestamp) from author \(author)")
            return
        }

        guard let thread: TSThread = {
            if let masterKey = storyMessage.group?.masterKey,
                let contextInfo = try? groupsV2.groupV2ContextInfo(forMasterKeyData: masterKey) {
                return TSGroupThread.fetch(groupId: contextInfo.groupId, transaction: transaction)
            } else {
                return TSContactThread.getWithContactAddress(author, transaction: transaction)
            }
        }(), !thread.hasPendingMessageRequest(transaction: transaction.unwrapGrdbRead) else {
            Logger.warn("Dropping story message with timestamp \(timestamp) from author \(author) with pending message request.")
            return
        }

        guard let message = try StoryMessage.create(
            withIncomingStoryMessage: storyMessage,
            timestamp: timestamp,
            author: author,
            transaction: transaction
        ) else { return }

        // TODO: Optimistic downloading of story attachments.
        attachmentDownloads.enqueueDownloadOfAttachmentsForNewStoryMessage(message, transaction: transaction)

        OWSDisappearingMessagesJob.shared.scheduleRun(byTimestamp: message.timestamp + storyLifetimeMillis)

        earlyMessageManager.applyPendingMessages(for: message, transaction: transaction)
    }

    @objc
    public class func deleteExpiredStories(transaction: SDSAnyWriteTransaction) -> UInt {
        var removedCount: UInt = 0
        StoryFinder.enumerateExpiredStories(transaction: transaction) { message, _ in
            Logger.info("Removing StoryMessage \(message.timestamp) which expired at: \(message.timestamp + storyLifetimeMillis)")
            message.anyRemove(transaction: transaction)
            removedCount += 1
        }
        return removedCount
    }

    @objc
    public class func nextExpirationTimestamp(transaction: SDSAnyReadTransaction) -> NSNumber? {
        guard let timestamp = StoryFinder.oldestTimestamp(transaction: transaction) else { return nil }
        return NSNumber(value: timestamp + storyLifetimeMillis)
    }
}

public enum StoryContext: Equatable, Hashable {
    case groupId(Data)
    case authorUuid(UUID)
    case none
}

public extension TSThread {
    var storyContext: StoryContext {
        if let groupThread = self as? TSGroupThread {
            return .groupId(groupThread.groupId)
        } else if let contactThread = self as? TSContactThread, let authorUuid = contactThread.contactAddress.uuid {
            return .authorUuid(authorUuid)
        } else {
            return .none
        }
    }
}

public extension StoryContext {
    func threadUniqueId(transaction: SDSAnyReadTransaction) -> String? {
        switch self {
        case .groupId(let data):
            return TSGroupThread.threadId(
                forGroupId: data,
                transaction: transaction
            )
        case .authorUuid(let uuid):
            return TSContactThread.getWithContactAddress(
                SignalServiceAddress(uuid: uuid),
                transaction: transaction
            )?.uniqueId
        case .none:
            return nil
        }
    }

    func thread(transaction: SDSAnyReadTransaction) -> TSThread? {
        switch self {
        case .groupId(let data):
            return TSGroupThread.fetch(groupId: data, transaction: transaction)
        case .authorUuid(let uuid):
            return TSContactThread.getWithContactAddress(
                SignalServiceAddress(uuid: uuid),
                transaction: transaction
            )
        case .none:
            return nil
        }
    }
}
