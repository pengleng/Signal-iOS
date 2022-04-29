//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

// MARK: -

@objc
public class TSConstants: NSObject {

    private enum Environment {
        case production, staging
    }
    private static var environment: Environment = .production

    @objc
    public static var isUsingProductionService: Bool {
        return environment == .production
    }

    // Never instantiate this class.
    private override init() {}

    public static let legalTermsUrl = URL(string: "https://signal.org/legal/")!
    public static let donateUrl = URL(string: "https://signal.org/donate/")!
    
    @objc
    public static var isUseMinioCDN: Bool { shared.isUseMinioCDN }

    @objc
    public static var mainServiceWebSocketAPI_identified: String { shared.mainServiceWebSocketAPI_identified }
    @objc
    public static var mainServiceWebSocketAPI_unidentified: String { shared.mainServiceWebSocketAPI_unidentified }
    @objc
    public static var mainServiceURL: String { shared.mainServiceURL }
    @objc
    public static var textSecureCDN0ServerURL: String { shared.textSecureCDN0ServerURL }
    @objc
    public static var textSecureCDN2ServerURL: String { shared.textSecureCDN2ServerURL }
    @objc
    public static var contactDiscoverySGXURL: String { shared.contactDiscoverySGXURL }
    @objc
    public static var contactDiscoveryHSMURL: String { shared.contactDiscoveryHSMURL }
    @objc
    public static var keyBackupURL: String { shared.keyBackupURL }
    @objc
    public static var storageServiceURL: String { shared.storageServiceURL }
    @objc
    public static var sfuURL: String { shared.sfuURL }
    @objc
    public static var sfuTestURL: String { shared.sfuTestURL }
    @objc
    public static var registrationCaptchaURL: String { shared.registrationCaptchaURL }
    @objc
    public static var challengeCaptchaURL: String { shared.challengeCaptchaURL }
    @objc
    public static var kUDTrustRoot: String { shared.kUDTrustRoot }
    @objc
    public static var updatesURL: String { shared.updatesURL }
    @objc
    public static var updates2URL: String { shared.updates2URL }

    @objc
    public static var censorshipReflectorHost: String { shared.censorshipReflectorHost }

    @objc
    public static var serviceCensorshipPrefix: String { shared.serviceCensorshipPrefix }
    @objc
    public static var cdn0CensorshipPrefix: String { shared.cdn0CensorshipPrefix }
    @objc
    public static var cdn2CensorshipPrefix: String { shared.cdn2CensorshipPrefix }
    @objc
    public static var contactDiscoveryCensorshipPrefix: String { shared.contactDiscoveryCensorshipPrefix }
    @objc
    public static var keyBackupCensorshipPrefix: String { shared.keyBackupCensorshipPrefix }
    @objc
    public static var storageServiceCensorshipPrefix: String { shared.storageServiceCensorshipPrefix }

    @objc
    public static var contactDiscoveryEnclaveName: String { shared.contactDiscoveryEnclaveName }
    @objc
    public static var contactDiscoveryMrEnclave: String { shared.contactDiscoveryMrEnclave }
    @objc
    public static var contactDiscoveryPublicKey: String { shared.contactDiscoveryPublicKey }
    @objc
    public static var contactDiscoveryCodeHashes: [String] { shared.contactDiscoveryCodeHashes }

    static var keyBackupEnclave: KeyBackupEnclave { shared.keyBackupEnclave }
    static var keyBackupPreviousEnclaves: [KeyBackupEnclave] { shared.keyBackupPreviousEnclaves }

    @objc
    public static var applicationGroup: String { shared.applicationGroup }

    @objc
    public static var serverPublicParamsBase64: String { shared.serverPublicParamsBase64 }

    private static var shared: TSConstantsProtocol {
        switch environment {
        case .production:
            return TSConstantsProduction()
        case .staging:
            return TSConstantsStaging()
        }
    }
}

// MARK: -

private protocol TSConstantsProtocol: AnyObject {
    var isUseMinioCDN: Bool { get }
    var mainServiceWebSocketAPI_identified: String { get }
    var mainServiceWebSocketAPI_unidentified: String { get }
    var mainServiceURL: String { get }
    var textSecureCDN0ServerURL: String { get }
    var textSecureCDN2ServerURL: String { get }
    var contactDiscoverySGXURL: String { get }
    var contactDiscoveryHSMURL: String { get }
    var keyBackupURL: String { get }
    var storageServiceURL: String { get }
    var sfuURL: String { get }
    var sfuTestURL: String { get }
    var registrationCaptchaURL: String { get }
    var challengeCaptchaURL: String { get }
    var kUDTrustRoot: String { get }
    var updatesURL: String { get }
    var updates2URL: String { get }

    var censorshipReflectorHost: String { get }

    var serviceCensorshipPrefix: String { get }
    var cdn0CensorshipPrefix: String { get }
    var cdn2CensorshipPrefix: String { get }
    var contactDiscoveryCensorshipPrefix: String { get }
    var keyBackupCensorshipPrefix: String { get }
    var storageServiceCensorshipPrefix: String { get }

    // SGX Backed Contact Discovery
    var contactDiscoveryEnclaveName: String { get }
    var contactDiscoveryMrEnclave: String { get }

    // HSM Backed Contact Discovery
    var contactDiscoveryPublicKey: String { get }
    var contactDiscoveryCodeHashes: [String] { get }

    var keyBackupEnclave: KeyBackupEnclave { get }
    var keyBackupPreviousEnclaves: [KeyBackupEnclave] { get }

    var applicationGroup: String { get }

    var serverPublicParamsBase64: String { get }
}

public struct KeyBackupEnclave: Equatable {
    let name: String
    let mrenclave: String
    let serviceId: String
}

// MARK: - Production

private class TSConstantsProduction: TSConstantsProtocol {

    public let isUseMinioCDN :Bool = true
    
    public let mainServiceWebSocketAPI_identified = "wss://chat.coolchatasia.com/v1/websocket/"
    public let mainServiceWebSocketAPI_unidentified = "wss://chat.coolchatasia.com/v1/websocket/"
    public let mainServiceURL = "https://chat.coolchatasia.com/"
    public let textSecureCDN0ServerURL = "https://cdn-aws.coolchatasia.com"
    public let textSecureCDN2ServerURL = "https://minio.coolchatasia.com"
    public let contactDiscoverySGXURL = "https://cds.coolchatasia.com"
    public let contactDiscoveryHSMURL = "wss://cds.coolchatasia.com/discovery/"
    public let keyBackupURL = "https://kbs.coolchatasia.com"
    public let storageServiceURL = "https://storage.coolchatasia.com"
    public let sfuURL = "https://turn.coolchatasia.com"
    public let sfuTestURL = "https://sfu.test.voip.signal.org"
    public let registrationCaptchaURL = "https://verify.coolchatasia.com/registration/generate.html"
    public let challengeCaptchaURL = "https://verify.coolchatasia.com/challenge/generate.html"
    public let kUDTrustRoot = "BVuU1wFzCsMciGmiTgFpKTKud7e7obG22BkmOlb9F+p2"
    public let updatesURL = "https://updates.signal.org"
    public let updates2URL = "https://updates2.signal.org"

    public let censorshipReflectorHost = "australia-southeast1-cool-chat-2021.cloudfunctions.net"

    public let serviceCensorshipPrefix = "service"
    public let cdn0CensorshipPrefix = "cdn"
    public let cdn2CensorshipPrefix = "cdn2"
    public let contactDiscoveryCensorshipPrefix = "directory"
    public let keyBackupCensorshipPrefix = "backup"
    public let storageServiceCensorshipPrefix = "storage"

    public let contactDiscoveryEnclaveName = "5ee1d7571fffada6df9cb8196eefa775a56d9445fc83fd2b64f255662ca21bba"
    public var contactDiscoveryMrEnclave: String {
        return contactDiscoveryEnclaveName
    }

    public var contactDiscoveryPublicKey: String {
        owsFailDebug("CDSH unsupported in production")
        return ""
    }
    public var contactDiscoveryCodeHashes: [String] {
        owsFailDebug("CDSH unsupported in production")
        return []
    }

    public let keyBackupEnclave = KeyBackupEnclave(
            name: "f0b6faf7133748655a4f88e320b019baf1cc1cb509b30c1cfc59848ba1429717",
            mrenclave: "5d4495bc955d01b261bbf4cfe5d6c25a37dee7bc3b0c8515bccd45aec5fe17ac",
            serviceId: "f0b6faf7133748655a4f88e320b019baf1cc1cb509b30c1cfc59848ba1429717"
        )

        // An array of previously used enclaves that we should try and restore
        // key material from during registration. These must be ordered from
        // newest to oldest, so we check the latest enclaves for backups before
        // checking earlier enclaves.
        public let keyBackupPreviousEnclaves = [
            KeyBackupEnclave(
                name: "f0b6faf7133748655a4f88e320b019baf1cc1cb509b30c1cfc59848ba1429717",
                mrenclave: "5d4495bc955d01b261bbf4cfe5d6c25a37dee7bc3b0c8515bccd45aec5fe17ac",
                serviceId: "f0b6faf7133748655a4f88e320b019baf1cc1cb509b30c1cfc59848ba1429717"
            )
        ]

    public let applicationGroup = "group.asia.coolapp.chat.group"

    // We need to discard all profile key credentials if these values ever change.
    // See: GroupsV2Impl.verifyServerPublicParams(...)
    public let serverPublicParamsBase64 = "ABSzmt4ojmFA+RbINeWVzukOleV+Tz7Pj7Kdozp96Y9odMQ1q9875jZHrPJD7KtXmNlfyL46Hqlk6puDekmjTWXYXTis2wttE4OwsxDhQdveadl8TgKwF7g/K/FlesGnPKDYwUeuiv++qxmIiEW5zKaWzlQLDEvzTQEr8fF/6jZ4lqHo0OcUygyP77Sh+iMk4Om00hVK/hP27SG6ID0T9zcm/Ftpfrc5XkqbJ/LAxe3JjawRyaTh+isg+d9NgU06XD5Ylx2FZ0tcqbn0sbt7mjHaS5CJWl8w7rAL4reAZCMS5jyClAHScIDvqFMaw/CbS83ewHjQ/dDwb+6bDD3doFJiL2/Y+kSKCTBTUnzl2HH4uhxX+QJ7XMupfN3X2RtFGg=="
}

// MARK: - Staging

private class TSConstantsStaging: TSConstantsProtocol {
    
    public let isUseMinioCDN :Bool = true

    public let mainServiceWebSocketAPI_identified = "wss://chat.staging.signal.org/v1/websocket/"
    public let mainServiceWebSocketAPI_unidentified = "wss://ud-chat.staging.signal.org/v1/websocket/"
    public let mainServiceURL = "https://chat.staging.signal.org/"
    public let textSecureCDN0ServerURL = "https://cdn-staging.signal.org"
    public let textSecureCDN2ServerURL = "https://cdn2-staging.signal.org"
    public let contactDiscoverySGXURL = "https://api-staging.directory.signal.org"
    public let contactDiscoveryHSMURL = "wss://cdsh.staging.signal.org/discovery/"
    public let keyBackupURL = "https://api-staging.backup.signal.org"
    public let storageServiceURL = "https://storage-staging.signal.org"
    public let sfuURL = "https://sfu.staging.voip.signal.org"
    public let registrationCaptchaURL = "https://signalcaptchas.org/staging/registration/generate.html"
    public let challengeCaptchaURL = "https://signalcaptchas.org/staging/challenge/generate.html"
    // There's no separate test SFU for staging.
    public let sfuTestURL = "https://sfu.test.voip.signal.org"
    public let kUDTrustRoot = "BbqY1DzohE4NUZoVF+L18oUPrK3kILllLEJh2UnPSsEx"
    // There's no separate updates endpoint for staging.
    public let updatesURL = "https://updates.signal.org"
    public let updates2URL = "https://updates2.signal.org"

    public let censorshipReflectorHost = "europe-west1-signal-cdn-reflector.cloudfunctions.net"

    public let serviceCensorshipPrefix = "service-staging"
    public let cdn0CensorshipPrefix = "cdn-staging"
    public let cdn2CensorshipPrefix = "cdn2-staging"
    public let contactDiscoveryCensorshipPrefix = "directory-staging"
    public let keyBackupCensorshipPrefix = "backup-staging"
    public let storageServiceCensorshipPrefix = "storage-staging"

    // CDS uses the same EnclaveName and MrEnclave
    public let contactDiscoveryEnclaveName = "c98e00a4e3ff977a56afefe7362a27e4961e4f19e211febfbb19b897e6b80b15"
    public var contactDiscoveryMrEnclave: String {
        return contactDiscoveryEnclaveName
    }

    public let contactDiscoveryPublicKey = "2fe57da347cd62431528daac5fbb290730fff684afc4cfc2ed90995f58cb3b74"
    public let contactDiscoveryCodeHashes = [
        "2f79dc6c1599b71c70fc2d14f3ea2e3bc65134436eb87011c88845b137af673a"
    ]

    public let keyBackupEnclave = KeyBackupEnclave(
        name: "dd6f66d397d9e8cf6ec6db238e59a7be078dd50e9715427b9c89b409ffe53f99",
        mrenclave: "ee19f1965b1eefa3dc4204eb70c04f397755f771b8c1909d080c04dad2a6a9ba",
        serviceId: "4200003414528c151e2dccafbc87aa6d3d66a5eb8f8c05979a6e97cb33cd493a"
    )

    // An array of previously used enclaves that we should try and restore
    // key material from during registration. These must be ordered from
    // newest to oldest, so we check the latest enclaves for backups before
    // checking earlier enclaves.
    public let keyBackupPreviousEnclaves = [
        KeyBackupEnclave(
            name: "dcd2f0b7b581068569f19e9ccb6a7ab1a96912d09dde12ed1464e832c63fa948",
            mrenclave: "9db0568656c53ad65bb1c4e1b54ee09198828699419ec0f63cf326e79827ab23",
            serviceId: "446a6e51956e0eed502c6d9626476cea5b7278829098c34ca0cdce329753a8ee"
        ),
        KeyBackupEnclave(
            name: "823a3b2c037ff0cbe305cc48928cfcc97c9ed4a8ca6d49af6f7d6981fb60a4e9",
            mrenclave: "a3baab19ef6ce6f34ab9ebb25ba722725ae44a8872dc0ff08ad6d83a9489de87",
            serviceId: "16b94ac6d2b7f7b9d72928f36d798dbb35ed32e7bb14c42b4301ad0344b46f29"
        )
    ]

    public let applicationGroup = "group.asia.coolapp.chat.group.staging"

    // We need to discard all profile key credentials if these values ever change.
    // See: GroupsV2Impl.verifyServerPublicParams(...)
    public let serverPublicParamsBase64 = "ABSY21VckQcbSXVNCGRYJcfWHiAMZmpTtTELcDmxgdFbtp/bWsSxZdMKzfCp8rvIs8ocCU3B37fT3r4Mi5qAemeGeR2X+/YmOGR5ofui7tD5mDQfstAI9i+4WpMtIe8KC3wU5w3Inq3uNWVmoGtpKndsNfwJrCg0Hd9zmObhypUnSkfYn2ooMOOnBpfdanRtrvetZUayDMSC5iSRcXKpdlukrpzzsCIvEwjwQlJYVPOQPj4V0F4UXXBdHSLK05uoPBCQG8G9rYIGedYsClJXnbrgGYG3eMTG5hnx4X4ntARBgELuMWWUEEfSK0mjXg+/2lPmWcTZWR9nkqgQQP0tbzuiPm74H2wMO4u1Wafe+UwyIlIT9L7KLS19Aw8r4sPrXQ=="
}
