//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import Foundation
import PassKit
import BonMot
import SignalServiceKit
import SignalMessaging
import Lottie
import SignalUI

class BoostSheetView: InteractiveSheetViewController {
    let boostVC = BoostViewController()
    let handleContainer = UIView()
    override var interactiveScrollViews: [UIScrollView] { [boostVC.tableView] }
    override var minHeight: CGFloat { min(680, CurrentAppContext().frame.height - (view.safeAreaInsets.top + 32)) }
    override var maximizedHeight: CGFloat { minHeight }
    override var renderExternalHandle: Bool { false }

    // MARK: -

    override public func viewDidLoad() {
        super.viewDidLoad()

        // We add the handle directly to the content view,
        // so that it doesn't scroll with the table.
        handleContainer.backgroundColor = Theme.tableView2PresentedBackgroundColor
        contentView.addSubview(handleContainer)
        handleContainer.autoPinWidthToSuperview()
        handleContainer.autoPinEdge(toSuperviewEdge: .top)

        let handle = UIView()
        handle.backgroundColor = boostVC.separatorColor
        handle.autoSetDimensions(to: CGSize(width: 36, height: 5))
        handle.layer.cornerRadius = 5 / 2
        handleContainer.addSubview(handle)
        handle.autoPinHeightToSuperview(withMargin: 12)
        handle.autoHCenterInSuperview()

        contentView.addSubview(boostVC.view)
        boostVC.view.autoPinWidthToSuperview()
        boostVC.view.autoPinEdge(toSuperviewEdge: .bottom)
        boostVC.view.autoPinEdge(.top, to: .bottom, of: handleContainer)
        addChild(boostVC)
    }

    override func themeDidChange() {
        super.themeDidChange()
        handleContainer.backgroundColor = Theme.tableView2PresentedBackgroundColor
    }
}

class BoostViewController: OWSTableViewController2 {
    private var currencyCode = Stripe.defaultCurrencyCode {
        didSet {
            guard oldValue != currencyCode else { return }
            customValueTextField.setCurrencyCode(currencyCode, symbol: presets?[currencyCode]?.symbol)
            state = nil
            updateTableContents()
        }
    }
    private let customValueTextField = CustomValueTextField()
    private let headerAnimationView: AnimationView = {
        let animationView = AnimationView(name: "boost_badge")
        animationView.loopMode = .playOnce
        animationView.backgroundBehavior = .forceFinish
        animationView.contentMode = .scaleAspectFit
        animationView.autoSetDimensions(to: CGSize(square: 112))
        return animationView
    }()

    private var donationAmount: NSDecimalNumber? {
        switch state {
        case .presetSelected(let amount): return NSDecimalNumber(value: amount)
        case .customValueSelected: return customValueTextField.decimalNumber
        default: return nil
        }
    }

    private var presets: [Currency.Code: DonationUtilities.Presets.Preset]? {
        didSet {
            customValueTextField.setCurrencyCode(currencyCode, symbol: presets?[currencyCode]?.symbol)
        }
    }
    private var boostBadge: ProfileBadge?
    private var boostExpiration: UInt64? {
        profileManagerImpl.localUserProfile().profileBadgeInfo?.first { BoostBadgeIds.contains($0.badgeId) }?.expiration
    }

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        return formatter
    }()

    enum State: Equatable {
        case loading
        case presetSelected(amount: UInt)
        case customValueSelected
        case donatedSuccessfully
    }
    private var state: State? = .loading {
        didSet {
            guard oldValue != state else { return }
            if oldValue == .customValueSelected { clearCustomTextField() }
            if state == .donatedSuccessfully || oldValue == .loading { updateTableContents() }
            updatePresetButtonSelection()
        }
    }

    func clearCustomTextField() {
        customValueTextField.text = nil
        customValueTextField.resignFirstResponder()
    }

    override func viewDidLoad() {
        shouldAvoidKeyboard = true

        super.viewDidLoad()

        firstly(on: .global()) {
            Promise.when(fulfilled: SubscriptionManager.getBoostBadge(), SubscriptionManager.getSuggestedBoostAmounts())
        }.then(on: .main) { [weak self] (boostBadge, presets) -> Promise<Void> in
            guard let self = self else { return Promise.value(()) }

            self.presets = presets
            self.boostBadge = boostBadge
            self.state = nil

            return self.profileManager.badgeStore.populateAssetsOnBadge(boostBadge)
        }.catch { error in
            owsFailDebug("Failed to fetch boost info \(error)")
        }

        customValueTextField.placeholder = NSLocalizedString(
            "BOOST_VIEW_CUSTOM_AMOUNT_PLACEHOLDER",
            comment: "Default text for the custom amount field of the boost view."
        )
        customValueTextField.delegate = self
        customValueTextField.accessibilityIdentifier = UIView.accessibilityIdentifier(in: self, name: "custom_amount_text_field")

        updateTableContents()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // If we're the root view, add a cancel button
        if navigationController?.viewControllers.first == self {
            navigationItem.leftBarButtonItem = .init(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(didTapDone)
            )
        }
    }

    @objc
    func didTapDone() {
        self.dismiss(animated: true)
    }

    static let bubbleBorderWidth: CGFloat = 1.5
    static let bubbleBorderColor = UIColor(rgbHex: 0xdedede)
    static var bubbleBackgroundColor: UIColor { Theme.isDarkThemeEnabled ? .ows_gray80 : .ows_white }

    func newCell() -> UITableViewCell {
        let cell = OWSTableItem.newCell()
        cell.selectionStyle = .none
        cell.layoutMargins = cellOuterInsets
        cell.contentView.layoutMargins = .zero
        return cell
    }

    override var canBecomeFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        // If we become the first responder, but the user was entering
        // a customValue, restore the first responder state to the text field.
        if result, case .customValueSelected = state {
            customValueTextField.becomeFirstResponder()
        }
        return result
    }

    var presetButtons: [UInt: UIView] = [:]
    func updatePresetButtonSelection() {
        for (amount, button) in presetButtons {
            if case .presetSelected(amount: amount) = self.state {
                button.layer.borderColor = Theme.accentBlueColor.cgColor
            } else {
                button.layer.borderColor = Self.bubbleBorderColor.cgColor
            }
        }
    }

    func updateTableContents() {

        let contents = OWSTableContents()
        defer {
            self.contents = contents
            if case .customValueSelected = state { customValueTextField.becomeFirstResponder() }
        }

        let section = OWSTableSection()
        section.hasBackground = false
        contents.addSection(section)

        section.customHeaderView = {
            let stackView = UIStackView()
            stackView.axis = .vertical
            stackView.alignment = .center
            stackView.isLayoutMarginsRelativeArrangement = true
            stackView.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 28, right: 16)

            let animationProgress = headerAnimationView.currentProgress
            stackView.addArrangedSubview(headerAnimationView)
            if animationProgress < 1, state != .loading {
                headerAnimationView.play(fromProgress: animationProgress, toProgress: 1)
            }

            let titleLabel = UILabel()
            titleLabel.textAlignment = .center
            titleLabel.font = UIFont.ows_dynamicTypeTitle2.ows_semibold
            titleLabel.text = NSLocalizedString(
                "BOOST_VIEW_TITLE",
                comment: "Title for the donate to signal view"
            )
            titleLabel.numberOfLines = 0
            titleLabel.lineBreakMode = .byWordWrapping
            stackView.addArrangedSubview(titleLabel)
            stackView.setCustomSpacing(20, after: titleLabel)

            let bodyText: String
            if let expiration = self.boostExpiration, expiration > Date().ows_millisecondsSince1970 {
                let renewalFormat = NSLocalizedString(
                    "BOOST_VIEW_BODY_WITH_EXPIRATION_FORMAT",
                    comment: "The body text for the donate to signal view, embeds {{Expiration}}"
                )
                let renewalDate = Date(millisecondsSince1970: expiration)
                bodyText = String(format: renewalFormat, self.dateFormatter.string(from: renewalDate))
            } else {
                bodyText = NSLocalizedString("BOOST_VIEW_BODY", comment: "The body text for the donate to signal view")
            }

            let bodyTextView = LinkingTextView()
            bodyTextView.attributedText = .composed(of: [
                bodyText,
                " ",
                CommonStrings.learnMore.styled(with: .link(SupportConstants.subscriptionFAQURL))
            ]).styled(with: .color(Theme.primaryTextColor), .font(.ows_dynamicTypeBody))

            bodyTextView.linkTextAttributes = [
                .foregroundColor: Theme.accentBlueColor,
                .underlineColor: UIColor.clear,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            bodyTextView.textAlignment = .center
            stackView.addArrangedSubview(bodyTextView)

            return stackView
        }()

        if state == .loading {
            section.add(.init(
                customCellBlock: { [weak self] in
                    guard let self = self else { return UITableViewCell() }
                    let cell = self.newCell()
                    let stackView = UIStackView()
                    stackView.axis = .vertical
                    stackView.alignment = .center
                    stackView.layoutMargins = UIEdgeInsets(top: 16, leading: 0, bottom: 16, trailing: 0)
                    stackView.isLayoutMarginsRelativeArrangement = true
                    cell.contentView.addSubview(stackView)
                    stackView.autoPinEdgesToSuperviewEdges()

                    let activitySpinner: UIActivityIndicatorView
                    if #available(iOS 13, *) {
                        activitySpinner = UIActivityIndicatorView(style: .medium)
                    } else {
                        activitySpinner = UIActivityIndicatorView(style: .gray)
                    }

                    activitySpinner.startAnimating()

                    stackView.addArrangedSubview(activitySpinner)

                    return cell
                },
                actionBlock: {}
            ))
        }

        addApplePayItemsIfAvailable(to: section)

        // If ApplePay isn't available, show just a link to the website
        if !DonationUtilities.isApplePayAvailable {
            section.add(.init(
                customCellBlock: { [weak self] in
                    guard let self = self else { return UITableViewCell() }
                    let cell = self.newCell()

                    let donateButton = OWSFlatButton()
                    donateButton.setBackgroundColors(upColor: Theme.accentBlueColor)
                    donateButton.setTitleColor(.ows_white)
                    donateButton.setAttributedTitle(NSAttributedString.composed(of: [
                        NSLocalizedString(
                            "SETTINGS_DONATE",
                            comment: "Title for the 'donate to signal' link in settings."
                        ),
                        Special.noBreakSpace,
                        NSAttributedString.with(
                            image: #imageLiteral(resourceName: "open-20").withRenderingMode(.alwaysTemplate),
                            font: UIFont.ows_dynamicTypeBodyClamped.ows_semibold
                        )
                    ]).styled(
                        with: .font(UIFont.ows_dynamicTypeBodyClamped.ows_semibold),
                        .color(.ows_white)
                    ))
                    donateButton.layer.cornerRadius = 24
                    donateButton.clipsToBounds = true
                    donateButton.setPressedBlock { [weak self] in
                        self?.openDonateWebsite()
                    }

                    cell.contentView.addSubview(donateButton)
                    donateButton.autoPinEdgesToSuperviewMargins()
                    donateButton.autoSetDimension(.height, toSize: 48, relation: .greaterThanOrEqual)

                    return cell
                },
                actionBlock: {}
            ))
        }
    }

    private func openDonateWebsite() {
        UIApplication.shared.open(TSConstants.donateUrl, options: [:], completionHandler: nil)
    }
}

// MARK: - ApplePay

extension BoostViewController: PKPaymentAuthorizationControllerDelegate {

    func addApplePayItemsIfAvailable(to section: OWSTableSection) {
        guard DonationUtilities.isApplePayAvailable, state != .loading else { return }

        // Currency Picker

        section.add(.init(
            customCellBlock: { [weak self] in
                guard let self = self else { return UITableViewCell() }
                let cell = self.newCell()

                let stackView = UIStackView()
                stackView.axis = .horizontal
                stackView.alignment = .center
                stackView.spacing = 8
                cell.contentView.addSubview(stackView)
                stackView.autoPinEdgesToSuperviewEdges()

                let label = UILabel()
                label.font = .ows_dynamicTypeBodyClamped
                label.textColor = Theme.primaryTextColor
                label.text = NSLocalizedString(
                    "BOOST_VIEW_AMOUNT_LABEL",
                    comment: "Donation amount label for the donate to signal view"
                )
                stackView.addArrangedSubview(label)

                let picker = OWSButton { [weak self] in
                    guard let self = self else { return }
                    let vc = CurrencyPickerViewController(
                        dataSource: StripeCurrencyPickerDataSource(currentCurrencyCode: self.currencyCode)
                    ) { [weak self] currencyCode in
                        self?.currencyCode = currencyCode
                    }
                    self.presentFormSheet(OWSNavigationController(rootViewController: vc), animated: true)
                }

                picker.setAttributedTitle(NSAttributedString.composed(of: [
                    self.currencyCode,
                    Special.noBreakSpace,
                    NSAttributedString.with(
                        image: #imageLiteral(resourceName: "chevron-down-18").withRenderingMode(.alwaysTemplate),
                        font: .ows_regularFont(withSize: 17)
                    ).styled(
                        with: .color(Self.bubbleBorderColor)
                    )
                ]).styled(
                    with: .font(.ows_regularFont(withSize: 17)),
                    .color(Theme.primaryTextColor)
                ), for: .normal)

                picker.setBackgroundImage(UIImage.init(color: Self.bubbleBackgroundColor), for: .normal)
                picker.setBackgroundImage(UIImage.init(color: Self.bubbleBackgroundColor.withAlphaComponent(0.8)), for: .highlighted)

                let pillView = PillView()
                pillView.layer.borderWidth = Self.bubbleBorderWidth
                pillView.layer.borderColor = Self.bubbleBorderColor.cgColor
                pillView.clipsToBounds = true
                pillView.addSubview(picker)
                picker.autoPinEdgesToSuperviewEdges()
                picker.autoSetDimension(.width, toSize: 74, relation: .greaterThanOrEqual)

                stackView.addArrangedSubview(pillView)
                pillView.autoSetDimension(.height, toSize: 36, relation: .greaterThanOrEqual)

                let leadingSpacer = UIView.hStretchingSpacer()
                let trailingSpacer = UIView.hStretchingSpacer()
                stackView.insertArrangedSubview(leadingSpacer, at: 0)
                stackView.addArrangedSubview(trailingSpacer)
                leadingSpacer.autoMatch(.width, to: .width, of: trailingSpacer)

                return cell
            },
            actionBlock: {}
        ))

        // Preset donation options

        if let preset = presets?[currencyCode] {
            section.add(.init(
                customCellBlock: { [weak self] in
                    guard let self = self else { return UITableViewCell() }
                    let cell = self.newCell()

                    let vStack = UIStackView()
                    vStack.axis = .vertical
                    vStack.distribution = .fillEqually
                    vStack.spacing = 16
                    cell.contentView.addSubview(vStack)
                    vStack.autoPinEdgesToSuperviewMargins()

                    self.presetButtons.removeAll()

                    for (row, amounts) in preset.amounts.chunked(by: 3).enumerated() {
                        let hStack = UIStackView()
                        hStack.axis = .horizontal
                        hStack.distribution = .fillEqually
                        hStack.spacing = UIDevice.current.isIPhone5OrShorter ? 8 : 14

                        vStack.addArrangedSubview(hStack)

                        for (index, amount) in amounts.enumerated() {
                            let button = OWSFlatButton()
                            hStack.addArrangedSubview(button)
                            button.setBackgroundColors(
                                upColor: Self.bubbleBackgroundColor,
                                downColor: Self.bubbleBackgroundColor.withAlphaComponent(0.8)
                            )
                            button.layer.cornerRadius = 24
                            button.clipsToBounds = true
                            button.layer.borderWidth = Self.bubbleBorderWidth

                            func playEmojiAnimation(parentView: UIView?) {
                                guard let parentView = parentView else { return }
                                let animationNames = [
                                    "boost_smile",
                                    "boost_clap",
                                    "boost_heart_eyes",
                                    "boost_fire",
                                    "boost_shock",
                                    "boost_rockets"
                                ]

                                guard let selectedAnimation = animationNames[safe: (row * 3) + index] else {
                                    return owsFailDebug("Missing animation for preset")
                                }

                                let animationView = AnimationView(name: selectedAnimation)
                                animationView.loopMode = .playOnce
                                animationView.contentMode = .scaleAspectFit
                                animationView.backgroundBehavior = .forceFinish
                                parentView.addSubview(animationView)
                                animationView.autoPinEdge(.bottom, to: .top, of: button, withOffset: 20)
                                animationView.autoPinEdge(.leading, to: .leading, of: button)
                                animationView.autoMatch(.width, to: .width, of: button)
                                animationView.play { _ in
                                    animationView.removeFromSuperview()
                                }
                            }

                            button.setPressedBlock { [weak self] in
                                self?.state = .presetSelected(amount: amount)
                                playEmojiAnimation(parentView: self?.view)
                            }

                            button.setTitle(
                                title: DonationUtilities.formatCurrency(NSDecimalNumber(value: amount), currencyCode: self.currencyCode),
                                font: .ows_regularFont(withSize: UIDevice.current.isIPhone5OrShorter ? 18 : 20),
                                titleColor: Theme.primaryTextColor
                            )

                            button.autoSetDimension(.height, toSize: 48)

                            self.presetButtons[amount] = button
                        }
                    }

                    self.updatePresetButtonSelection()

                    return cell
                },
                actionBlock: {}
            ))
        }

        // Custom donation option

        let applePayButtonIndex = IndexPath(row: section.items.count + 1, section: 0)
        let customValueTextField = self.customValueTextField
        section.add(.init(
            customCellBlock: { [weak self] in
                guard let self = self else { return UITableViewCell() }
                let cell = self.newCell()

                customValueTextField.backgroundColor = Self.bubbleBackgroundColor
                customValueTextField.layer.cornerRadius = 24
                customValueTextField.layer.borderWidth = Self.bubbleBorderWidth
                customValueTextField.layer.borderColor = Self.bubbleBorderColor.cgColor

                customValueTextField.font = .ows_dynamicTypeBodyClamped
                customValueTextField.textColor = Theme.primaryTextColor

                cell.contentView.addSubview(customValueTextField)
                customValueTextField.autoPinEdgesToSuperviewMargins()

                return cell
            },
            actionBlock: { [weak self] in
                customValueTextField.becomeFirstResponder()
                self?.tableView.scrollToRow(at: applePayButtonIndex, at: .bottom, animated: true)
            }
        ))

        // Donate with Apple Pay button

        section.add(.init(
            customCellBlock: { [weak self] in
                guard let self = self else { return UITableViewCell() }
                let cell = self.newCell()

                let donateButton = PKPaymentButton(
                    paymentButtonType: .donate,
                    paymentButtonStyle: Theme.isDarkThemeEnabled ? .white : .black
                )
                donateButton.cornerRadius = 12
                donateButton.addTarget(self, action: #selector(self.requestApplePayDonation), for: .touchUpInside)
                cell.contentView.addSubview(donateButton)
                donateButton.autoPinEdgesToSuperviewMargins()
                donateButton.autoSetDimension(.height, toSize: 48, relation: .greaterThanOrEqual)

                return cell
            },
            actionBlock: {}
        ))

        // Other options button

        section.add(.init(
            customCellBlock: { [weak self] in
                guard let self = self else { return UITableViewCell() }
                let cell = self.newCell()

                let donateButton = OWSFlatButton()
                donateButton.setTitleColor(Theme.accentBlueColor)
                donateButton.setAttributedTitle(NSAttributedString.composed(of: [
                    NSLocalizedString(
                        "BOOST_VIEW_OTHER_WAYS",
                        comment: "Text explaining there are other ways to donate on the boost view."
                    ),
                    Special.noBreakSpace,
                    NSAttributedString.with(
                        image: #imageLiteral(resourceName: "open-20").withRenderingMode(.alwaysTemplate),
                        font: .ows_dynamicTypeBodyClamped
                    )
                ]).styled(
                    with: .font(.ows_dynamicTypeBodyClamped),
                    .color(Theme.accentBlueColor)
                ))
                donateButton.setPressedBlock { [weak self] in
                    self?.openDonateWebsite()
                }

                cell.contentView.addSubview(donateButton)
                donateButton.autoPinEdgesToSuperviewMargins()

                return cell
            },
            actionBlock: {}
        ))
    }

    @objc
    func requestApplePayDonation() {
        guard let donationAmount = donationAmount else {
            presentToast(text: NSLocalizedString(
                "BOOST_VIEW_SELECT_AN_AMOUNT",
                comment: "Error text notifying the user they must select an amount on the donate to signal view"
            ), extraVInset: view.height - tableView.frame.maxY)
            return
        }

        guard !Stripe.isAmountTooSmall(donationAmount, in: currencyCode) else {
            presentToast(text: NSLocalizedString(
                "BOOST_VIEW_SELECT_A_LARGER_AMOUNT",
                comment: "Error text notifying the user they must select a large amount on the donate to signal view"
            ), extraVInset: view.height - tableView.frame.maxY)
            return
        }

        guard !Stripe.isAmountTooLarge(donationAmount, in: currencyCode) else {
            presentToast(text: NSLocalizedString(
                "BOOST_VIEW_SELECT_A_SMALLER_AMOUNT",
                comment: "Error text notifying the user they must select a smaller amount on the donate to signal view"
            ), extraVInset: view.height - tableView.frame.maxY)
            return
        }

        let request = DonationUtilities.newPaymentRequest(for: donationAmount, currencyCode: currencyCode)

        SubscriptionManager.terminateTransactionIfPossible = false
        let paymentController = PKPaymentAuthorizationController(paymentRequest: request)
        paymentController.delegate = self
        paymentController.present { presented in
            if !presented { owsFailDebug("Failed to present payment controller") }
        }
    }

    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        SubscriptionManager.terminateTransactionIfPossible = true
        controller.dismiss()
    }

    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        guard let donationAmount = donationAmount else {
            completion(.init(status: .failure, errors: [OWSAssertionError("Missing donation amount")]))
            return
        }

        enum BoostError: Error { case timeout, assertion }

        firstly {
            Stripe.boost(amount: donationAmount, in: currencyCode, for: payment)
        }.done { intentId in
            completion(.init(status: .success, errors: nil))
            SubscriptionManager.terminateTransactionIfPossible = false

            do {
                try SubscriptionManager.createAndRedeemBoostReceipt(for: intentId,
                                                                    amount: donationAmount as Decimal,
                                                                    currencyCode: self.currencyCode)
            } catch {

            }

            ModalActivityIndicatorViewController.present(fromViewController: self, canCancel: false) { modal in
                Promise.race(
                    NotificationCenter.default.observe(
                        once: SubscriptionManager.SubscriptionJobQueueDidFinishJobNotification,
                        object: nil
                    ),
                    NotificationCenter.default.observe(
                        once: SubscriptionManager.SubscriptionJobQueueDidFailJobNotification,
                        object: nil
                    )
                ).timeout(seconds: 30) {
                    return BoostError.timeout
                }.done { notification in
                    modal.dismiss {}

                    if notification.name == SubscriptionManager.SubscriptionJobQueueDidFailJobNotification {
                        throw BoostError.assertion
                    }

                    self.state = .donatedSuccessfully

                    guard let boostBadge = self.boostBadge else {
                        return owsFailDebug("Missing boost badge!")
                    }

                    // We're presented in a sheet context, so we must dismiss the sheet and then present
                    // the thank you sheet.
                    if self.parent is BoostSheetView {
                        let presentingVC = self.parent?.presentingViewController
                        self.parent?.dismiss(animated: true) {
                            presentingVC?.present(BadgeThanksSheet(badge: boostBadge), animated: true)
                        }
                    } else {
                        self.present(BadgeThanksSheet(badge: boostBadge), animated: true)
                    }
                }.catch { error in
                    modal.dismiss {}
                    guard let error = error as? BoostError else {
                        return owsFailDebug("Unexpected error \(error)")
                    }

                    switch error {
                    case .timeout:
                        self.presentStillProcessingSheet()
                    case .assertion:
                        self.presentBadgeCantBeAddedSheet()
                    }
                }
            }
        }.catch { error in
            SubscriptionManager.terminateTransactionIfPossible = false
            owsFailDebugUnlessNetworkFailure(error)
            completion(.init(status: .failure, errors: [error]))
        }
    }

    func presentStillProcessingSheet() {
        let title = NSLocalizedString("SUSTAINER_STILL_PROCESSING_BADGE_TITLE", comment: "Action sheet title for Still Processing Badge sheet")
        let message = NSLocalizedString("SUSTAINER_VIEW_STILL_PROCESSING_BADGE_MESSAGE", comment: "Action sheet message for Still Processing Badge sheet")
        let actionSheet = ActionSheetController(title: title, message: message)
        actionSheet.addAction(OWSActionSheets.okayAction)
        self.navigationController?.topViewController?.presentActionSheet(actionSheet)
    }

    func presentBadgeCantBeAddedSheet() {
        let title = NSLocalizedString("SUSTAINER_VIEW_CANT_ADD_BADGE_TITLE", comment: "Action sheet title for Couldn't Add Badge sheet")
        let message = NSLocalizedString("SUSTAINER_VIEW_CANT_ADD_BADGE_MESSAGE", comment: "Action sheet message for Couldn't Add Badge sheet")
        let actionSheet = ActionSheetController(title: title, message: message)
        actionSheet.addAction(ActionSheetAction(
            title: NSLocalizedString("CONTACT_SUPPORT", comment: "Button text to initiate an email to signal support staff"),
            style: .default,
            handler: { [weak self] _ in
                let localizedSheetTitle = NSLocalizedString("EMAIL_SIGNAL_TITLE",
                                                            comment: "Title for the fallback support sheet if user cannot send email")
                let localizedSheetMessage = NSLocalizedString("EMAIL_SIGNAL_MESSAGE",
                                                              comment: "Description for the fallback support sheet if user cannot send email")
                guard ComposeSupportEmailOperation.canSendEmails else {
                    let fallbackSheet = ActionSheetController(title: localizedSheetTitle,
                                                              message: localizedSheetMessage)
                    let buttonTitle = NSLocalizedString("BUTTON_OKAY", comment: "Label for the 'okay' button.")
                    fallbackSheet.addAction(ActionSheetAction(title: buttonTitle, style: .default))
                    self?.presentActionSheet(fallbackSheet)
                    return
                }
                let supportVC = ContactSupportViewController()
                let navVC = OWSNavigationController(rootViewController: supportVC)
                self?.presentFormSheet(navVC, animated: true)
            }
        ))

        actionSheet.addAction(ActionSheetAction(
            title: NSLocalizedString("SUSTAINER_VIEW_SUBSCRIPTION_CONFIRMATION_NOT_NOW", comment: "Sustainer view Not Now Action sheet button"),
            style: .cancel,
            handler: nil
        ))
        self.navigationController?.topViewController?.presentActionSheet(actionSheet)
    }
}

// MARK: - CustomValueTextField

private protocol CustomValueTextFieldDelegate: AnyObject {
    func customValueTextFieldStateDidChange(_ textField: CustomValueTextField)
}

private class CustomValueTextField: UIView {
    private let placeholderLabel = UILabel()
    private let symbolLabel = UILabel()
    private let textField = UITextField()
    private let stackView = UIStackView()

    weak var delegate: CustomValueTextFieldDelegate?

    @discardableResult
    override func becomeFirstResponder() -> Bool { textField.becomeFirstResponder() }

    @discardableResult
    override func resignFirstResponder() -> Bool { textField.resignFirstResponder() }

    override var canBecomeFirstResponder: Bool { textField.canBecomeFirstResponder }
    override var canResignFirstResponder: Bool { textField.canResignFirstResponder }
    override var isFirstResponder: Bool { textField.isFirstResponder }

    init() {
        super.init(frame: .zero)
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.keyboardType = .decimalPad
        textField.textAlignment = .center
        textField.delegate = self

        symbolLabel.textAlignment = .center
        placeholderLabel.textAlignment = .center

        stackView.axis = .horizontal

        stackView.addArrangedSubview(placeholderLabel)
        stackView.addArrangedSubview(textField)

        addSubview(stackView)
        stackView.autoPinHeightToSuperview()
        stackView.autoMatch(.width, to: .width, of: self, withMultiplier: 1, relation: .lessThanOrEqual)
        stackView.autoHCenterInSuperview()
        stackView.autoSetDimension(.height, toSize: 48, relation: .greaterThanOrEqual)

        updateVisibility()
        setCurrencyCode(currencyCode)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String? {
        set {
            textField.text = newValue
            updateVisibility()
        }
        get { textField.text }
    }

    var decimalNumber: NSDecimalNumber? {
        let number = NSDecimalNumber(string: valueString(for: text), locale: Locale.current)
        guard number != NSDecimalNumber.notANumber else { return nil }
        return number
    }

    var font: UIFont? {
        set {
            textField.font = newValue
            placeholderLabel.font = newValue
            symbolLabel.font = newValue
        }
        get { textField.font }
    }

    var textColor: UIColor? {
        set {
            textField.textColor = newValue
            placeholderLabel.textColor = newValue
            symbolLabel.textColor = newValue
        }
        get { textField.textColor }
    }

    var placeholder: String? {
        set { placeholderLabel.text = newValue }
        get { placeholderLabel.text }
    }

    private lazy var symbol: DonationUtilities.Symbol = .currencyCode
    private lazy var currencyCode = Stripe.defaultCurrencyCode

    func setCurrencyCode(_ currencyCode: Currency.Code, symbol: DonationUtilities.Symbol? = nil) {
        self.symbol = symbol ?? .currencyCode
        self.currencyCode = currencyCode

        symbolLabel.removeFromSuperview()

        switch self.symbol {
        case .before(let symbol):
            symbolLabel.text = symbol
            stackView.insertArrangedSubview(symbolLabel, at: 0)
        case .after(let symbol):
            symbolLabel.text = symbol
            stackView.addArrangedSubview(symbolLabel)
        case .currencyCode:
            symbolLabel.text = currencyCode + " "
            stackView.insertArrangedSubview(symbolLabel, at: 0)
        }
    }

    func updateVisibility() {
        let shouldShowPlaceholder = text.isEmptyOrNil && !isFirstResponder
        placeholderLabel.isHiddenInStackView = !shouldShowPlaceholder
        symbolLabel.isHiddenInStackView = shouldShowPlaceholder
        textField.isHiddenInStackView = shouldShowPlaceholder
    }
}

extension CustomValueTextField: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        updateVisibility()
        delegate?.customValueTextFieldStateDidChange(self)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        updateVisibility()
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn editingRange: NSRange, replacementString: String) -> Bool {
        let existingString = textField.text ?? ""

        let newString = (existingString as NSString).replacingCharacters(in: editingRange, with: replacementString)
        if let numberString = self.valueString(for: newString) {
            textField.text = numberString
            // Make a best effort to preserve cursor position
            if let newPosition = textField.position(
                from: textField.beginningOfDocument,
                offset: editingRange.location + max(0, numberString.count - existingString.count)
            ) {
                textField.selectedTextRange = textField.textRange(from: newPosition, to: newPosition)
            }
        } else {
            textField.text = ""
        }

        updateVisibility()
        delegate?.customValueTextFieldStateDidChange(self)

        return false
    }

    /// Converts an arbitrary string into a string representing a valid value
    /// for the current currency. If no valid value is represented, returns nil
    func valueString(for string: String?) -> String? {
        guard let string = string else { return nil }

        let isZeroDecimalCurrency = Stripe.zeroDecimalCurrencyCodes.contains(currencyCode)
        guard !isZeroDecimalCurrency else { return string.digitsOnly }

        let decimalSeparator = Locale.current.decimalSeparator ?? "."
        let components = string.components(separatedBy: decimalSeparator).compactMap { $0.digitsOnly.nilIfEmpty }

        guard let integralString = components.first else {
            if string.contains(decimalSeparator) {
                return "0" + decimalSeparator
            } else {
                return nil
            }
        }

        if let decimalString = components.dropFirst().joined().nilIfEmpty {
            return integralString + decimalSeparator + decimalString
        } else if string.starts(with: decimalSeparator) {
            return "0" + decimalSeparator + integralString
        } else if string.contains(decimalSeparator) {
            return integralString + decimalSeparator
        } else {
            return integralString
        }
    }
}

extension BoostViewController: CustomValueTextFieldDelegate {
    fileprivate func customValueTextFieldStateDidChange(_ textField: CustomValueTextField) {
        state = .customValueSelected
    }
}
